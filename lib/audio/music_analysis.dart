import 'dart:math' as math;
import 'dart:typed_data';

import 'loudness.dart';

/// Beat / tempo / energy / drop / section analysis of a music track, in pure
/// Dart on a mono PCM buffer (so it runs on every platform and in tests).
///
///   final a = MusicAnalysis.analyze(mono, sampleRate);
///   a.tempo, a.beats, a.downbeats, a.drops, a.sections, a.energyAt(t)
///
/// Method: spectral-flux onset envelope (log-magnitude STFT, ~100 frames/s),
/// tempo from the autocorrelation of the envelope with a log-normal prior
/// around 120 BPM, beats by dynamic programming (Ellis 2007), downbeats as the
/// most accented of the four beat phases (4/4), energy from frame RMS, drops
/// where the energy jumps by ≥ 6 dB into a loud part, sections from a
/// band-energy novelty curve.
class MusicAnalysis {
  final double duration;

  /// Beats per minute (0 when no beat was found).
  final double tempo;

  /// 0..1: how periodic the onsets are (click track ≈ 0.9, noise ≈ 0.1).
  final double confidence;
  final List<double> beats;
  final List<double> downbeats;
  final List<double> onsets;

  /// Drops (energy jumps into a loud part), in time order, with
  /// [dropStrength] (dB jump) for each.
  final List<double> drops;
  final List<double> dropStrength;

  /// Section boundaries (seconds), excluding 0 and the end.
  final List<double> sections;

  /// Smoothed energy 0..1, [energyRate] values per second.
  final Float32List energy;
  final double energyRate;

  /// Approximate integrated loudness (LUFS).
  final double loudness;

  MusicAnalysis({
    required this.duration,
    required this.tempo,
    required this.confidence,
    required this.beats,
    required this.downbeats,
    required this.onsets,
    required this.drops,
    required this.dropStrength,
    required this.sections,
    required this.energy,
    required this.energyRate,
    required this.loudness,
  });

  /// The strongest drop, if any.
  double? get mainDrop {
    if (drops.isEmpty) return null;
    var best = 0;
    for (int i = 1; i < drops.length; i++) {
      if (dropStrength[i] > dropStrength[best]) best = i;
    }
    return drops[best];
  }

  double energyAt(double t) {
    if (energy.isEmpty) return 0;
    final i = (t * energyRate).round().clamp(0, energy.length - 1);
    return energy[i];
  }

  /// A plain beat grid (when the user types a BPM instead of analysing).
  static MusicAnalysis grid(double bpm, {double offset = 0, required double duration, int beatsPerBar = 4}) {
    final beats = <double>[];
    if (bpm > 0) {
      final p = 60 / bpm;
      for (var t = offset; t <= duration + 1e-9; t += p) {
        if (t >= 0) beats.add(t);
      }
    }
    return MusicAnalysis(
      duration: duration,
      tempo: bpm,
      confidence: 1,
      beats: beats,
      downbeats: [for (int i = 0; i < beats.length; i += beatsPerBar) beats[i]],
      onsets: beats,
      drops: const [],
      dropStrength: const [],
      sections: const [],
      energy: Float32List(0),
      energyRate: 1,
      loudness: Loudness.silence,
    );
  }

  Map<String, dynamic> toJson() => {
        'duration': _r(duration),
        'tempo': _r(tempo),
        'confidence': _r(confidence),
        'beats': beats.map(_r).toList(),
        'downbeats': downbeats.map(_r).toList(),
        'onsets': onsets.map(_r).toList(),
        'drops': drops.map(_r).toList(),
        'drop_strength': dropStrength.map(_r).toList(),
        'sections': sections.map(_r).toList(),
        'energy_rate': energyRate,
        'energy': energy.map((e) => (e * 100).round()).toList(),
        'loudness': _r(loudness),
      };

  static MusicAnalysis fromJson(Map<String, dynamic> j) {
    List<double> l(String k) => [for (final v in (j[k] as List? ?? const [])) (v as num).toDouble()];
    return MusicAnalysis(
      duration: (j['duration'] as num? ?? 0).toDouble(),
      tempo: (j['tempo'] as num? ?? 0).toDouble(),
      confidence: (j['confidence'] as num? ?? 0).toDouble(),
      beats: l('beats'),
      downbeats: l('downbeats'),
      onsets: l('onsets'),
      drops: l('drops'),
      dropStrength: l('drop_strength'),
      sections: l('sections'),
      energy: Float32List.fromList([for (final v in (j['energy'] as List? ?? const [])) (v as num) / 100]),
      energyRate: (j['energy_rate'] as num? ?? 1).toDouble(),
      loudness: (j['loudness'] as num? ?? Loudness.silence).toDouble(),
    );
  }

  /// Short text for the AI prompt / UI.
  String summary() {
    final d = mainDrop;
    return '${tempo.toStringAsFixed(1)} BPM, ${beats.length} beats, ${downbeats.length} bars'
        '${d == null ? '' : ', drop at ${d.toStringAsFixed(2)} s'}'
        '${sections.isEmpty ? '' : ', sections at ${sections.map((s) => s.toStringAsFixed(1)).join(', ')} s'}'
        ', ${loudness.toStringAsFixed(1)} LUFS';
  }

  static double _r(double v) => (v * 1000).roundToDouble() / 1000;

  // ================================================================ analysis

  static MusicAnalysis analyze(Float32List mono, int sampleRate) {
    final duration = sampleRate > 0 ? mono.length / sampleRate : 0.0;
    final loud = Loudness.lufs(mono, sampleRate);
    if (sampleRate <= 0 || mono.length < sampleRate ~/ 2) {
      return MusicAnalysis(
          duration: duration, tempo: 0, confidence: 0, beats: const [], downbeats: const [], onsets: const [], drops: const [],
          dropStrength: const [], sections: const [], energy: Float32List(0), energyRate: 1, loudness: loud);
    }

    // ------------------------------------------------ decimate to ~11-16 kHz
    final k = math.max(1, sampleRate ~/ 11025);
    final Float32List x;
    if (k > 1) {
      x = Float32List(mono.length ~/ k);
      for (int i = 0; i < x.length; i++) {
        var s = 0.0;
        for (int j = 0; j < k; j++) {
          s += mono[i * k + j];
        }
        x[i] = s / k;
      }
    } else {
      x = mono;
    }
    final sr = sampleRate / k;

    // ------------------------------------------------ STFT → flux, bands, rms
    final hop = math.max(1, (sr / 100).round());
    final fps = sr / hop;
    var win = 1;
    while (win < sr * 0.04) {
      win *= 2;
    }
    final fft = _Fft(win);
    final window = Float64List(win);
    var wsum = 0.0;
    for (int i = 0; i < win; i++) {
      window[i] = 0.5 - 0.5 * math.cos(2 * math.pi * i / win);
      wsum += window[i];
    }
    final bins = win ~/ 2 + 1;
    final lowBin = math.max(1, (150 * win / sr).floor());
    // 8 log-spaced bands from 60 Hz to Nyquist for section features.
    const nBands = 8;
    final bandEdge = Int32List(nBands + 1);
    for (int b = 0; b <= nBands; b++) {
      final hz = 60 * math.pow(sr / 2 / 60, b / nBands);
      bandEdge[b] = (hz * win / sr).round().clamp(1, bins - 1);
    }
    final nf = x.length ~/ hop + 1;
    final flux = Float64List(nf), lowFlux = Float64List(nf), rmsDb = Float64List(nf);
    final bandLog = Float64List(nf * nBands);
    final re = Float64List(win), im = Float64List(win);
    var prev = Float64List(bins), cur = Float64List(bins);
    final half = win ~/ 2;
    for (int f = 0; f < nf; f++) {
      final c = f * hop;
      var ms = 0.0, cnt = 0;
      for (int i = 0; i < win; i++) {
        final s = c - half + i;
        final v = (s >= 0 && s < x.length) ? x[s] : 0.0;
        re[i] = v * window[i];
        im[i] = 0;
      }
      for (int s = math.max(0, c - hop ~/ 2); s < math.min(x.length, c + (hop + 1) ~/ 2); s++) {
        ms += x[s] * x[s];
        cnt++;
      }
      rmsDb[f] = cnt == 0 || ms <= 0 ? -120 : 10 * math.log(ms / cnt) / math.ln10;
      fft.transform(re, im);
      var fl = 0.0, lo = 0.0;
      for (int b = 0; b < bins; b++) {
        final mag = math.sqrt(re[b] * re[b] + im[b] * im[b]) * 2 / wsum;
        final lg = math.log(1 + 100 * mag);
        cur[b] = lg;
        if (f > 0) {
          final d = lg - prev[b];
          if (d > 0) {
            fl += d;
            if (b <= lowBin) lo += d;
          }
        }
      }
      for (int b = 0; b < nBands; b++) {
        var e = 0.0;
        for (int q = bandEdge[b]; q < math.max(bandEdge[b] + 1, bandEdge[b + 1]); q++) {
          e += re[q] * re[q] + im[q] * im[q];
        }
        bandLog[f * nBands + b] = math.log(1e-9 + e / (wsum * wsum));
      }
      flux[f] = fl;
      lowFlux[f] = lo;
      final t = prev;
      prev = cur;
      cur = t;
    }
    // The flux peak arrives slightly before a sharp onset reaches the frame centre.
    final latency = 0.17 * win / sr;

    // ------------------------------------------------ onset envelope (normalised)
    final avg = _movingAverage(flux, math.max(1, fps.round()));
    final o = Float64List(nf);
    var sq = 0.0;
    for (int i = 0; i < nf; i++) {
      o[i] = math.max(0.0, flux[i] - avg[i]);
      sq += o[i] * o[i];
    }
    final mean = o.fold<double>(0, (a, b) => a + b) / nf;
    final sd = math.sqrt(math.max(0.0, sq / nf - mean * mean));
    if (sd > 1e-9) {
      for (int i = 0; i < nf; i++) {
        o[i] /= sd;
      }
    }

    // ------------------------------------------------ tempo
    final lagMin = math.max(1, (fps * 60 / 220).floor());
    final lagMax = math.min(nf - 2, (fps * 60 / 50).ceil());
    var tempo = 0.0, confidence = 0.0;
    var beats = <double>[];
    if (lagMax > lagMin + 2) {
      double ac(int lag) {
        var s = 0.0;
        for (int i = 0; i + lag < nf; i++) {
          s += o[i] * o[i + lag];
        }
        return s / (nf - lag);
      }

      final r0 = ac(0);
      final score = Float64List(lagMax - lagMin + 1);
      final raw = Float64List(lagMax - lagMin + 1);
      for (int l = lagMin; l <= lagMax; l++) {
        final bpm = 60 * fps / l;
        final w = math.exp(-0.5 * math.pow(math.log(bpm / 120) / math.ln2 / 1.0, 2));
        raw[l - lagMin] = ac(l);
        score[l - lagMin] = raw[l - lagMin] * w;
      }
      var bi = 0;
      for (int i = 1; i < score.length; i++) {
        if (score[i] > score[bi]) bi = i;
      }
      var lag = (bi + lagMin).toDouble();
      if (bi > 0 && bi < score.length - 1) {
        final a = score[bi - 1], b = score[bi], c = score[bi + 1];
        final den = a - 2 * b + c;
        if (den.abs() > 1e-12) lag += (0.5 * (a - c) / den).clamp(-0.5, 0.5).toDouble();
      }
      confidence = r0 > 1e-12 ? (raw[bi] / r0).clamp(0.0, 1.0).toDouble() : 0.0;
      if (r0 > 1e-12) {
        final frames = _trackBeats(o, lag);
        // Drop weak beats at the edges (silence before / after the music).
        final strength = [for (final b in frames) _localMax(flux, b, 2)];
        final sorted = [...strength]..sort();
        final med = sorted.isEmpty ? 0.0 : sorted[sorted.length ~/ 2];
        var a = 0, z = frames.length;
        while (a < z && strength[a] < 0.3 * med) {
          a++;
        }
        while (z > a && strength[z - 1] < 0.3 * med) {
          z--;
        }
        for (int i = a; i < z; i++) {
          final f = frames[i];
          // Refine to the flux peak with parabolic interpolation.
          var j = f;
          for (int q = math.max(1, f - 2); q <= math.min(nf - 2, f + 2); q++) {
            if (flux[q] > flux[j]) j = q;
          }
          var off = 0.0;
          if (j > 0 && j < nf - 1) {
            final p0 = flux[j - 1], p1 = flux[j], p2 = flux[j + 1];
            final den = p0 - 2 * p1 + p2;
            if (den.abs() > 1e-12) off = (0.5 * (p0 - p2) / den).clamp(-0.5, 0.5).toDouble();
          }
          beats.add(math.max(0.0, (j + off) / fps + latency));
        }
        tempo = beats.length >= 2 ? 60 / _regressionPeriod(beats, lag / fps) : 60 * fps / lag;
      }
    }

    // ------------------------------------------------ downbeats (4/4)
    final downbeats = <double>[];
    if (beats.length >= 4) {
      final acc = List<double>.filled(4, 0);
      final cnt = List<int>.filled(4, 0);
      for (int i = 0; i < beats.length; i++) {
        final f = ((beats[i] - latency) * fps).round().clamp(0, nf - 1);
        acc[i % 4] += _localMax(lowFlux, f, 2) + 0.5 * _localMax(flux, f, 2) + 0.02 * (rmsDb[f] + 120);
        cnt[i % 4]++;
      }
      var best = 0;
      for (int p = 1; p < 4; p++) {
        if (acc[p] / math.max(1, cnt[p]) > acc[best] / math.max(1, cnt[best])) best = p;
      }
      for (int i = best; i < beats.length; i += 4) {
        downbeats.add(beats[i]);
      }
    } else {
      downbeats.addAll(beats);
    }

    // ------------------------------------------------ onsets
    final onsets = <double>[];
    final oAvg = _movingAverage(o, math.max(1, (fps * 0.1).round()));
    final minGap = math.max(1, (fps * 0.05).round());
    var lastOn = -minGap;
    for (int i = 1; i < nf - 1; i++) {
      if (o[i] < 1.0 || o[i] < oAvg[i] * 1.5) continue;
      if (_localMax(o, i, minGap) > o[i]) continue;
      if (i - lastOn < minGap) continue;
      onsets.add(i / fps + latency);
      lastOn = i;
    }

    // ------------------------------------------------ energy curve
    var maxDb = -120.0;
    for (final v in rmsDb) {
      maxDb = math.max(maxDb, v);
    }
    final floor = math.max(-100.0, maxDb - 60);
    final dbc = Float64List(nf);
    for (int i = 0; i < nf; i++) {
      dbc[i] = math.max(floor, rmsDb[i]);
    }
    final es = _movingAverage(dbc, math.max(1, (fps * 0.3).round()));
    final energy = Float32List(nf);
    for (int i = 0; i < nf; i++) {
      energy[i] = maxDb - floor < 1e-6 ? 0.0 : ((es[i] - floor) / (maxDb - floor)).clamp(0.0, 1.0).toDouble();
    }

    // ------------------------------------------------ drops
    final drops = <double>[], dropStrength = <double>[];
    {
      final w = math.max(2, (2 * fps).round());
      final side = math.max(1, fps.round());
      final pre = Float64List(nf + 1);
      for (int i = 0; i < nf; i++) {
        pre[i + 1] = pre[i] + es[i];
      }
      double meanOf(int a, int b) => b > a ? (pre[b] - pre[a]) / (b - a) : 0;
      final sortedEs = [...es]..sort();
      final loudLevel = sortedEs[(sortedEs.length * 0.6).floor().clamp(0, sortedEs.length - 1)];
      final jump = Float64List(nf);
      for (int t = side; t <= nf - side; t++) {
        final before = meanOf(math.max(0, t - w), t);
        final after = meanOf(t, math.min(nf, t + w));
        jump[t] = (after >= loudLevel - 3) ? after - before : 0.0;
      }
      final cand = <int>[];
      final nms = math.max(1, (4 * fps).round());
      for (int t = side; t <= nf - side; t++) {
        if (jump[t] < 6) continue;
        if (_localMax(jump, t, nms) > jump[t]) continue;
        if (cand.isNotEmpty && t - cand.last < nms) continue;
        cand.add(t);
      }
      final fine = _movingAverage(dbc, math.max(1, (fps * 0.05).round()));
      final d3 = math.max(1, (fps * 0.03).round());
      for (final t in cand) {
        // The steepest rise near the jump is the actual hit.
        var bestI = t, bestRise = -1e9;
        for (int i = math.max(d3, t - w ~/ 2); i < math.min(nf - d3, t + w ~/ 2); i++) {
          final rise = fine[i + d3] - fine[i - d3];
          if (rise > bestRise) {
            bestRise = rise;
            bestI = i;
          }
        }
        // …then the onset peak right there, then a beat if one is that close.
        final r = math.max(1, (fps * 0.12).round());
        var onF = bestI;
        for (int i = math.max(0, bestI - r); i <= math.min(nf - 1, bestI + r); i++) {
          if (flux[i] > flux[onF]) onF = i;
        }
        var time = onF / fps + latency;
        for (final b in beats) {
          if ((b - time).abs() < 0.08) {
            time = b;
            break;
          }
        }
        drops.add(time);
        dropStrength.add(jump[t]);
      }
    }

    // ------------------------------------------------ sections
    final sections = <double>[];
    {
      final bf = math.max(1, (fps * 0.5).round());
      final nb = nf ~/ bf;
      final feat = List.generate(nb, (_) => Float64List(nBands + 1));
      for (int b = 0; b < nb; b++) {
        for (int f = b * bf; f < (b + 1) * bf; f++) {
          for (int q = 0; q < nBands; q++) {
            feat[b][q] += bandLog[f * nBands + q] / bf;
          }
          feat[b][nBands] += dbc[f] / bf * math.ln10 / 10; // dB → same units as ln energy
        }
      }
      const kWin = 8; // 4 s each side
      final nov = Float64List(nb);
      for (int b = kWin; b <= nb - kWin; b++) {
        var s = 0.0;
        for (int q = 0; q <= nBands; q++) {
          var a = 0.0, c = 0.0;
          for (int j = 0; j < kWin; j++) {
            a += feat[b - 1 - j][q];
            c += feat[b + j][q];
          }
          final d = (c - a) / kWin;
          s += d * d;
        }
        nov[b] = math.sqrt(s);
      }
      final vals = nov.where((v) => v > 0).toList();
      if (vals.isNotEmpty) {
        final m = vals.reduce((a, b) => a + b) / vals.length;
        final sdv = math.sqrt(vals.map((v) => (v - m) * (v - m)).reduce((a, b) => a + b) / vals.length);
        final thr = math.max(1.5, m + 0.5 * sdv);
        var last = -1000;
        for (int b = kWin; b <= nb - kWin; b++) {
          if (nov[b] < thr || _localMax(nov, b, 8) > nov[b] || b - last < 16) continue;
          last = b;
          final t = b * bf / fps;
          double? snap;
          for (final d in downbeats) {
            if ((d - t).abs() < 1.0 && (snap == null || (d - t).abs() < (snap - t).abs())) snap = d;
          }
          sections.add(snap ?? t);
        }
      }
      for (final d in drops) {
        if (sections.every((s) => (s - d).abs() > 2)) sections.add(d);
      }
      sections.sort();
    }

    return MusicAnalysis(
      duration: duration,
      tempo: tempo,
      confidence: confidence,
      beats: beats,
      downbeats: downbeats,
      onsets: onsets,
      drops: drops,
      dropStrength: dropStrength,
      sections: sections,
      energy: energy,
      energyRate: fps,
      loudness: loud,
    );
  }

  /// Dynamic-programming beat tracker: frames of the best beat sequence
  /// with period [period] frames.
  static List<int> _trackBeats(Float64List o, double period) {
    final n = o.length;
    final c = Float64List(n);
    final back = Int32List(n)..fillRange(0, n, -1);
    final lo = math.max(1, (period / 2).round()), hi = math.max(lo + 1, (2 * period).round());
    final pen = Float64List(hi + 1);
    for (int d = lo; d <= hi; d++) {
      final lg = math.log(d / period);
      pen[d] = 100 * lg * lg;
    }
    for (int t = 0; t < n; t++) {
      var best = 0.0;
      var bi = -1;
      for (int d = lo; d <= hi && t - d >= 0; d++) {
        final v = c[t - d] - pen[d];
        if (v > best) {
          best = v;
          bi = t - d;
        }
      }
      c[t] = o[t] + best;
      back[t] = bi;
    }
    // Start from the best score in the last period, walk back.
    final p = math.max(1, period.round());
    var t = n - 1;
    for (int i = math.max(0, n - p); i < n; i++) {
      if (c[i] > c[t]) t = i;
    }
    final out = <int>[];
    while (t >= 0) {
      out.add(t);
      t = back[t];
    }
    return out.reversed.toList();
  }

  /// Least-squares beat period (seconds) over consecutive beats; falls back
  /// to [guess] when beats are missing in between.
  static double _regressionPeriod(List<double> beats, double guess) {
    // Index each beat by its rounded number of periods from the first.
    final idx = <double>[];
    var k = 0.0;
    idx.add(0);
    for (int i = 1; i < beats.length; i++) {
      k += math.max(1, ((beats[i] - beats[i - 1]) / guess).round());
      idx.add(k);
    }
    final n = beats.length;
    final mx = idx.reduce((a, b) => a + b) / n, my = beats.reduce((a, b) => a + b) / n;
    var sxy = 0.0, sxx = 0.0;
    for (int i = 0; i < n; i++) {
      sxy += (idx[i] - mx) * (beats[i] - my);
      sxx += (idx[i] - mx) * (idx[i] - mx);
    }
    final p = sxx > 0 ? sxy / sxx : guess;
    return p > 0 ? p : guess;
  }

  static double _localMax(List<double> x, int at, int r) {
    var m = -double.infinity;
    for (int i = math.max(0, at - r); i <= math.min(x.length - 1, at + r); i++) {
      if (x[i] > m) m = x[i];
    }
    return m;
  }

  /// Centred moving average over [w] samples (edges use what is there).
  static Float64List _movingAverage(List<double> x, int w) {
    final n = x.length;
    final pre = Float64List(n + 1);
    for (int i = 0; i < n; i++) {
      pre[i + 1] = pre[i] + x[i];
    }
    final out = Float64List(n);
    final h = w ~/ 2;
    for (int i = 0; i < n; i++) {
      final a = math.max(0, i - h), b = math.min(n, i + w - h);
      out[i] = (pre[b] - pre[a]) / math.max(1, b - a);
    }
    return out;
  }
}

/// Iterative radix-2 complex FFT (in place).
class _Fft {
  final int n;
  final Float64List _cos, _sin;
  final Int32List _rev;

  _Fft(this.n)
      : _cos = Float64List(n ~/ 2),
        _sin = Float64List(n ~/ 2),
        _rev = Int32List(n) {
    for (int i = 0; i < n ~/ 2; i++) {
      _cos[i] = math.cos(2 * math.pi * i / n);
      _sin[i] = -math.sin(2 * math.pi * i / n);
    }
    var bits = 0;
    while ((1 << bits) < n) {
      bits++;
    }
    for (int i = 0; i < n; i++) {
      var r = 0;
      for (int b = 0; b < bits; b++) {
        if (i & (1 << b) != 0) r |= 1 << (bits - 1 - b);
      }
      _rev[i] = r;
    }
  }

  void transform(Float64List re, Float64List im) {
    for (int i = 0; i < n; i++) {
      final j = _rev[i];
      if (j > i) {
        final tr = re[i];
        re[i] = re[j];
        re[j] = tr;
        final ti = im[i];
        im[i] = im[j];
        im[j] = ti;
      }
    }
    for (int size = 2; size <= n; size <<= 1) {
      final halfSize = size >> 1;
      final step = n ~/ size;
      for (int start = 0; start < n; start += size) {
        for (int k = 0; k < halfSize; k++) {
          final w = k * step;
          final a = start + k, b = a + halfSize;
          final tr = re[b] * _cos[w] - im[b] * _sin[w];
          final ti = re[b] * _sin[w] + im[b] * _cos[w];
          re[b] = re[a] - tr;
          im[b] = im[a] - ti;
          re[a] += tr;
          im[a] += ti;
        }
      }
    }
  }
}
