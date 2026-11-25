import 'dart:math' as math;
import 'dart:typed_data';

/// Loudness estimates on raw PCM.
///
/// [lufs] is an approximation of EBU R128 integrated loudness: a gentle
/// high-pass (stand-in for K-weighting), 400 ms blocks, absolute gate at
/// −70 and relative gate 10 dB below the ungated level. For speech and
/// music it lands within a couple of dB of a real meter, which is plenty
/// for setting mix levels.
class Loudness {
  static const silence = -100.0;

  /// Gated loudness in approx. LUFS (−100 for silence).
  static double lufs(Float32List x, int sampleRate) {
    if (x.isEmpty || sampleRate <= 0) return silence;
    final hp = _highpass(x, sampleRate, 60);
    final block = math.max(1, (0.4 * sampleRate).round());
    final step = math.max(1, (0.1 * sampleRate).round()); // 75 % overlap
    final ms = <double>[];
    if (hp.length < block) {
      ms.add(_meanSquare(hp, 0, hp.length));
    } else {
      for (int s = 0; s + block <= hp.length; s += step) {
        ms.add(_meanSquare(hp, s, s + block));
      }
    }
    double level(Iterable<double> v) {
      if (v.isEmpty) return silence;
      final m = v.reduce((a, b) => a + b) / v.length;
      return m <= 1e-10 ? silence : 10 * math.log(m) / math.ln10;
    }

    double db(double m) => m <= 1e-10 ? silence : 10 * math.log(m) / math.ln10;
    final abs = ms.where((m) => db(m) > -70).toList();
    if (abs.isEmpty) return silence;
    final rel = level(abs) - 10;
    final gated = abs.where((m) => db(m) > rel).toList();
    return level(gated.isEmpty ? abs : gated);
  }

  /// Plain RMS level in dBFS.
  static double rmsDb(Float32List x) {
    if (x.isEmpty) return silence;
    final m = _meanSquare(x, 0, x.length);
    return m <= 1e-10 ? silence : 10 * math.log(m) / math.ln10;
  }

  /// Highest absolute sample in dBFS.
  static double peakDb(Float32List x) {
    var p = 0.0;
    for (final v in x) {
      p = math.max(p, v.abs());
    }
    return p <= 1e-5 ? silence : 20 * math.log(p) / math.ln10;
  }

  /// Gain in dB that brings [measured] to [target].
  static double gainTo(double measured, double target) => measured <= silence + 1 ? 0 : target - measured;

  /// dB → linear factor.
  static double dbToGain(double db) => math.pow(10, db / 20).toDouble();

  /// linear factor → dB.
  static double gainToDb(double g) => g <= 1e-6 ? silence : 20 * math.log(g) / math.ln10;

  static double _meanSquare(Float32List x, int a, int b) {
    var s = 0.0;
    for (int i = a; i < b; i++) {
      s += x[i] * x[i];
    }
    return b > a ? s / (b - a) : 0;
  }

  static Float32List _highpass(Float32List x, int rate, double hz) {
    final a = math.exp(-2 * math.pi * hz / rate);
    final out = Float32List(x.length);
    var y = 0.0, px = 0.0;
    for (int i = 0; i < x.length; i++) {
      y = a * (y + x[i] - px);
      px = x[i];
      out[i] = y;
    }
    return out;
  }
}
