import 'dart:math' as math;
import 'dart:typed_data';

import '../core/engine/text_clusters.dart'; // V2-F

/// Sound effects synthesised on the device (no stock files needed).
///
/// [kinds] is the small set the Director places automatically (whoosh for
/// transitions, hit for big numbers / reveals, riser before a hook, tick for
/// timelines, pop for cards, impact for intros). [all] is the full
/// documentary sound-design catalogue, including loopable ambience [beds].
///
/// Every sound is deterministic for a given seed, peak-normalised, and has a
/// [peak] time — the moment that should sit on the cut / reveal.
class Sfx {
  static const kinds = ['whoosh', 'hit', 'riser', 'tick', 'pop', 'impact'];

  /// Loopable ambience beds (the end flows seamlessly into the start).
  static const beds = ['crowd_bed', 'wind_bed', 'room_tone', 'night_bed', 'rain_bed', 'fire_bed', 'clock_tick'];

  static const all = [
    ...kinds,
    'swoosh_short', 'swoosh_long', 'swoosh_reverse', 'whoosh_silence', 'reverse_cymbal',
    'braam', 'sub_drop', 'glitch', 'shutter', 'typewriter', 'paper', 'pin_drop', 'heartbeat',
    'ui_click', 'ding',
    ...beds,
  ];

  static const rate = 44100;

  static bool isBed(String kind) => beds.contains(kind);

  static double length(String kind) => switch (kind) {
        'whoosh' => 0.7,
        'hit' => 1.4,
        'riser' => 2.0,
        'tick' => 0.12,
        'pop' => 0.25,
        'impact' => 2.4,
        'swoosh_short' => 0.35,
        'swoosh_long' => 1.6,
        'swoosh_reverse' => 1.0,
        'whoosh_silence' => 1.8,
        'reverse_cymbal' => 2.5,
        'braam' => 3.2,
        'sub_drop' => 2.0,
        'glitch' => 0.6,
        'shutter' => 0.35,
        'typewriter' => 1.4,
        'paper' => 0.8,
        'pin_drop' => 0.9,
        'heartbeat' => 1.6,
        'ui_click' => 0.08,
        'ding' => 1.8,
        'clock_tick' => 4.0,
        'crowd_bed' || 'wind_bed' || 'room_tone' || 'night_bed' || 'rain_bed' || 'fire_bed' => 8.0,
        _ => 0.5,
      };

  /// Where the "impact" of the sound sits, so it can be placed on a cut.
  static double peak(String kind) => switch (kind) {
        'whoosh' => 0.38,
        'riser' => 2.0,
        'swoosh_short' => 0.18,
        'swoosh_long' => 0.9,
        'swoosh_reverse' => 0.95,
        'whoosh_silence' => 0.6, // the cut into silence
        'reverse_cymbal' => 2.45,
        'braam' => 0.1,
        'paper' => 0.12,
        'pin_drop' => 0.18, // the pin lands
        'heartbeat' => 0.05,
        _ => 0.0,
      };

  /// Short label, category and description for the sound browser and the AI.
  static (String, String, String) info(String kind) => switch (kind) {
        'whoosh' => ('Whoosh', 'Transitions', 'air sweep for a cut or slide'),
        'swoosh_short' => ('Swoosh (short)', 'Transitions', 'quick bright swish for text and pop-ins'),
        'swoosh_long' => ('Swoosh (long)', 'Transitions', 'slow wide sweep for big camera moves'),
        'swoosh_reverse' => ('Reverse swoosh', 'Transitions', 'sucks in and stops on the cut'),
        'whoosh_silence' => ('Whoosh into silence', 'Transitions', 'builds then cuts to dead silence before a reveal'),
        'reverse_cymbal' => ('Reverse cymbal', 'Transitions', 'shimmering swell that lands on the cut'),
        'riser' => ('Riser', 'Transitions', 'tension build before a hook'),
        'hit' => ('Hit', 'Impacts', 'punchy boom for numbers and reveals'),
        'impact' => ('Impact', 'Impacts', 'big intro slam decaying to silence'),
        'braam' => ('Braam', 'Impacts', 'deep cinematic horn for dramatic reveals'),
        'sub_drop' => ('Sub drop', 'Impacts', 'falling sub-bass under a drop or title'),
        'tick' => ('Tick', 'UI & text', 'timeline / counter tick'),
        'pop' => ('Pop', 'UI & text', 'cards and labels popping in'),
        'ui_click' => ('UI click', 'UI & text', 'tiny interface click'),
        'ding' => ('Ding', 'UI & text', 'bell for a fact or notification'),
        'typewriter' => ('Typewriter', 'UI & text', 'key clicks, one per letter'),
        'glitch' => ('Glitch', 'UI & text', 'digital stutter for glitch transitions'),
        'shutter' => ('Camera shutter', 'Foley', 'photo snap for photo cards'),
        'paper' => ('Paper rustle', 'Foley', 'documents, articles, posters'),
        'pin_drop' => ('Map pin drop', 'Foley', 'pin falls and lands on the map'),
        'heartbeat' => ('Heartbeat', 'Foley', 'tension, two lub-dubs'),
        'crowd_bed' => ('Crowd murmur', 'Beds', 'loopable crowd / market / protest bed'),
        'wind_bed' => ('Wind', 'Beds', 'loopable wind for deserts, mountains, empty places'),
        'room_tone' => ('Room tone', 'Beds', 'loopable quiet room / office ambience'),
        'night_bed' => ('Night crickets', 'Beds', 'loopable night ambience'),
        'rain_bed' => ('Rain', 'Beds', 'loopable rain'),
        'fire_bed' => ('Fire crackle', 'Beds', 'loopable fire / war / campfire'),
        'clock_tick' => ('Clock ticking', 'Beds', 'loopable tick-tock for deadlines and suspense'),
        _ => (kind, 'Other', ''),
      };

  static const categories = ['Transitions', 'Impacts', 'UI & text', 'Foley', 'Beds'];

  /// 16-bit stereo 44.1 kHz WAV bytes.
  static Uint8List wav(String kind, {int seed = 7}) {
    final (l, r) = render(kind, seed: seed);
    return encode(l, r);
  }

  /// Typewriter key clicks: one click per offset in [times] (seconds).
  static Uint8List typing(List<double> times, {int seed = 7}) {
    final (l, r) = renderTyping(times, seed: seed);
    return encode(l, r);
  }

  /// Offsets (seconds after the layer start) at which the `typewriter` text
  /// animator reveals each visible letter of [text] over [animDuration].
  static List<double> typingTimes(String text, double animDuration) {
    final letters = TextClusters.split(text); // V2-F: one click per whole letter (Devanagari clusters)
    final n = letters.length;
    if (n == 0) return const [];
    return [
      for (int k = 0; k < n; k++)
        if (letters[k].trim().isNotEmpty) (k + 0.5) / n * animDuration,
    ];
  }

  static (Float32List, Float32List) renderTyping(List<double> times, {int seed = 7}) {
    final end = times.isEmpty ? 0.0 : times.reduce(math.max);
    final n = ((end + 0.15) * rate).round();
    final l = Float32List(n), r = Float32List(n);
    final rnd = math.Random(seed);
    for (int i = 0; i < times.length; i++) {
      _keyClick(l, r, rnd, times[i], i == 0 ? 1.0 : 0.7 + rnd.nextDouble() * 0.3);
    }
    _normalize(l, r, 0.85);
    return (l, r);
  }

  /// Stereo float samples (−1..1) of [kind].
  static (Float32List, Float32List) render(String kind, {int seed = 7}) {
    final len = length(kind);
    final bed = isBed(kind) && kind != 'clock_tick';
    final xfade = bed ? (0.5 * rate).round() : 0;
    final n = (len * rate).round();
    final l = Float32List(n + xfade), r = Float32List(n + xfade);
    final rnd = math.Random(seed);
    switch (kind) {
      // ------------------------------------------------ original set (unchanged)
      case 'whoosh':
        _noiseSweep(l, r, rnd, fromHz: 300, toHz: 3800, attack: 0.55, pan: true);
        break;
      case 'riser':
        _noiseSweep(l, r, rnd, fromHz: 200, toHz: 6000, attack: 0.97, pan: false);
        _addTone(l, r, 110, 440, 0.18, exp: false);
        break;
      case 'hit':
        _addTone(l, r, 90, 38, 0.9, exp: true); // sub boom
        _burst(l, r, rnd, 0.08, 0.6); // transient
        _tail(l, r, rnd, 0.25);
        break;
      case 'tick':
        _addTone(l, r, 2400, 1800, 0.5, exp: true);
        break;
      case 'pop':
        _addTone(l, r, 700, 180, 0.6, exp: true);
        _burst(l, r, rnd, 0.015, 0.3);
        break;
      case 'impact':
        // Big intro hit that decays to silence (title slam: hit → silence → drop).
        _addTone(l, r, 70, 30, 1.0, exp: true);
        _addTone(l, r, 180, 60, 0.35, exp: true);
        _burst(l, r, rnd, 0.12, 0.8);
        _tail(l, r, rnd, 0.3);
        break;

      // ------------------------------------------------ transitions
      case 'swoosh_short':
        _noiseSweep(l, r, rnd, fromHz: 900, toHz: 5200, attack: 0.5, pan: true);
        break;
      case 'swoosh_long':
        _noiseSweep(l, r, rnd, fromHz: 180, toHz: 2600, attack: 0.5625, pan: true);
        _tone(l, r, at: 0, dur: 1.6, f0: 55, f1: 90, gain: 0.25, env: (t) => _bell(t, 0.9, 1.6));
        break;
      case 'swoosh_reverse':
        _noise(l, r, rnd, at: 0, dur: 1.0, bandHz: 400, bandHz1: 4200, q: 0.4,
            env: (t) => t < 0.95 ? math.pow(t / 0.95, 3).toDouble() : math.max(0.0, 1 - (t - 0.95) / 0.04));
        break;
      case 'whoosh_silence':
        _noise(l, r, rnd, at: 0, dur: 0.62, bandHz: 250, bandHz1: 3500, q: 0.4, pan: -0.2,
            env: (t) => t < 0.6 ? math.pow(t / 0.6, 2.5).toDouble() : math.max(0.0, 1 - (t - 0.6) / 0.012));
        _tone(l, r, at: 0, dur: 0.612, f0: 60, f1: 130, gain: 0.3,
            env: (t) => t < 0.6 ? math.pow(t / 0.6, 2).toDouble() : math.max(0.0, 1 - (t - 0.6) / 0.012));
        break;
      case 'reverse_cymbal':
        double swell(double t) => t < 2.45 ? math.exp((t - 2.45) / 0.45) : math.max(0.0, 1 - (t - 2.45) / 0.04);
        _noise(l, r, rnd, at: 0, dur: 2.5, highHz: 4000, gain: 1.0, env: swell);
        for (final (hz, g) in [(3127.0, 0.12), (4561.0, 0.09), (5870.0, 0.07), (7333.0, 0.05)]) {
          _tone(l, r, at: 0, dur: 2.5, f0: hz, gain: g, env: swell);
        }
        break;

      // ------------------------------------------------ impacts
      case 'braam':
        _braam(l, r, rnd);
        break;
      case 'sub_drop':
        _tone(l, r, at: 0, dur: 2.0, f0: 95, f1: 28, glide: 1.2, gain: 1.0, env: (t) => _ad(t, 0.004, 0.7));
        _noise(l, r, rnd, at: 0, dur: 0.006, gain: 0.5, highHz: 800);
        break;

      // ------------------------------------------------ UI & text
      case 'ui_click':
        _tone(l, r, at: 0, dur: 0.01, f0: 3500, gain: 0.8, env: (t) => _ad(t, 0.0003, 0.002));
        _tone(l, r, at: 0, dur: 0.015, f0: 900, gain: 0.4, env: (t) => _ad(t, 0.0005, 0.004));
        _noise(l, r, rnd, at: 0, dur: 0.0015, gain: 0.6);
        break;
      case 'ding':
        const f0 = 1318.5;
        for (final (k, g, d) in [(1.0, 1.0, 0.6), (2.0, 0.35, 0.35), (2.76, 0.5, 0.25), (5.4, 0.2, 0.12)]) {
          _tone(l, r, at: 0, dur: 1.8, f0: f0 * k, gain: g, env: (t) => _ad(t, 0.002, d));
        }
        break;
      case 'typewriter':
        var t = 0.0;
        var i = 0;
        while (t < 1.25) {
          _keyClick(l, r, rnd, t, i == 0 ? 1.0 : 0.7 + rnd.nextDouble() * 0.3);
          t += 0.085 + rnd.nextDouble() * 0.04;
          i++;
        }
        break;
      case 'glitch':
        _glitch(l, r, rnd);
        break;

      // ------------------------------------------------ foley
      case 'shutter':
        _noise(l, r, rnd, at: 0, dur: 0.006, bandHz: 3500, q: 0.3, gain: 1.0);
        _tone(l, r, at: 0, dur: 0.012, f0: 1800, f1: 1200, gain: 0.6, env: (t) => _ad(t, 0.0005, 0.004));
        _noise(l, r, rnd, at: 0.11, dur: 0.005, bandHz: 3000, q: 0.3, gain: 0.6);
        _tone(l, r, at: 0.11, dur: 0.02, f0: 300, gain: 0.4, env: (t) => _ad(t, 0.001, 0.006));
        break;
      case 'paper':
        double shape(double t) => t < 0.12 ? t / 0.12 : math.exp(-(t - 0.12) / 0.22);
        for (int g = 0; g < 90; g++) {
          final at = rnd.nextDouble() * 0.7;
          final d = 0.003 + rnd.nextDouble() * 0.012;
          _noise(l, r, rnd, at: at, dur: d, bandHz: 1500 + rnd.nextDouble() * 4500, q: 0.5,
              gain: shape(at) * (0.25 + rnd.nextDouble() * 0.4), pan: rnd.nextDouble() * 1.2 - 0.6, env: (t) => _bell(t, d / 2, d));
        }
        _noise(l, r, rnd, at: 0.115, dur: 0.02, bandHz: 2500, q: 0.25, gain: 1.6, env: (t) => _bell(t, 0.004, 0.02));
        break;
      case 'pin_drop':
        _tone(l, r, at: 0, dur: 0.16, f0: 2000, f1: 700, gain: 0.15, env: (t) => _bell(t, 0.02, 0.16));
        _tone(l, r, at: 0.18, dur: 0.25, f0: 180, f1: 90, gain: 1.0, env: (t) => _ad(t, 0.001, 0.05));
        _noise(l, r, rnd, at: 0.18, dur: 0.004, bandHz: 2500, q: 0.3, gain: 0.8);
        _tone(l, r, at: 0.33, dur: 0.12, f0: 200, f1: 110, gain: 0.35, env: (t) => _ad(t, 0.001, 0.03));
        break;
      case 'heartbeat':
        for (final (at, g) in [(0.05, 1.0), (0.30, 0.7), (0.85, 1.0), (1.10, 0.7)]) {
          _tone(l, r, at: at - 0.008, dur: 0.18, f0: 62, f1: 42, gain: g, env: (t) => _ad(t, 0.008, 0.045));
          _noise(l, r, rnd, at: at - 0.008, dur: 0.05, lowHz: 180, gain: g * 0.8, env: (t) => _ad(t, 0.006, 0.015));
        }
        break;

      // ------------------------------------------------ beds
      case 'crowd_bed':
        _crowd(l, r, rnd);
        break;
      case 'wind_bed':
        _wind(l, r, rnd, gain: 1.0);
        break;
      case 'room_tone':
        _noise(l, r, rnd, at: 0, dur: l.length / rate, lowHz: 900, gain: 0.5, env: (_) => 1);
        _noise(l, r, rnd, at: 0, dur: l.length / rate, lowHz: 120, gain: 0.8, env: (_) => 1);
        for (final (hz, g) in [(50.0, 0.05), (100.0, 0.03), (150.0, 0.015)]) {
          _tone(l, r, at: 0, dur: l.length / rate, f0: hz, gain: g, env: (_) => 1);
        }
        break;
      case 'night_bed':
        _wind(l, r, rnd, gain: 0.12);
        for (final (pan, hz, gap) in [(-0.6, 4400.0, 0.7), (0.5, 4900.0, 0.95)]) {
          var t = rnd.nextDouble() * 0.4;
          while (t < l.length / rate - 0.12) {
            for (int p = 0; p < 3; p++) {
              _tone(l, r, at: t + p * 0.03, dur: 0.016, f0: hz, gain: 0.35, pan: pan, env: (u) => _bell(u, 0.008, 0.016));
            }
            t += gap * (0.8 + rnd.nextDouble() * 0.4);
          }
        }
        break;
      case 'rain_bed':
        _noise(l, r, rnd, at: 0, dur: l.length / rate, lowHz: 5000, highHz: 400, gain: 0.35, env: (_) => 1);
        final drops = (l.length / rate * 220).round();
        for (int k = 0; k < drops; k++) {
          final d = 0.001 + rnd.nextDouble() * 0.002;
          _noise(l, r, rnd, at: rnd.nextDouble() * (l.length / rate - 0.005), dur: d, bandHz: 2000 + rnd.nextDouble() * 5000, q: 0.4,
              gain: 0.1 + rnd.nextDouble() * 0.5, pan: rnd.nextDouble() * 2 - 1, env: (t) => _ad(t, 0.0002, d / 3));
        }
        break;
      case 'fire_bed':
        _noise(l, r, rnd, at: 0, dur: l.length / rate, lowHz: 250, gain: 1.2, env: (t) => 0.7 + 0.3 * math.sin(t * 1.7) * math.sin(t * 0.63));
        final pops = (l.length / rate * 18).round();
        for (int k = 0; k < pops; k++) {
          final at = rnd.nextDouble() * (l.length / rate - 0.01);
          final burst = rnd.nextDouble() < 0.3 ? 3 : 1;
          for (int b = 0; b < burst; b++) {
            final d = 0.0005 + rnd.nextDouble() * 0.0025;
            _noise(l, r, rnd, at: at + b * (0.01 + rnd.nextDouble() * 0.03), dur: d, bandHz: 1000 + rnd.nextDouble() * 3000, q: 0.3,
                gain: 0.2 + rnd.nextDouble() * 0.8, pan: rnd.nextDouble() * 1.4 - 0.7, env: (t) => _ad(t, 0.0001, d / 2));
          }
        }
        break;
      case 'clock_tick':
        for (int k = 0; k < 4; k++) {
          final tock = k.isOdd;
          final g = tock ? 0.85 : 1.0;
          final at = k.toDouble() + 0.002;
          _tone(l, r, at: at, dur: 0.02, f0: tock ? 2400 : 3000, gain: g * 0.7, env: (t) => _ad(t, 0.0003, 0.004));
          _tone(l, r, at: at, dur: 0.03, f0: tock ? 900 : 1200, gain: g * 0.5, env: (t) => _ad(t, 0.0005, 0.008));
          _noise(l, r, rnd, at: at, dur: 0.002, bandHz: 4000, q: 0.4, gain: g * 0.6);
        }
        break;
    }
    var outL = l, outR = r;
    if (xfade > 0) {
      (outL, outR) = _loop(l, r, n, xfade);
    }
    _normalize(outL, outR, isBed(kind) ? 0.6 : 0.85);
    return (outL, outR);
  }

  // -------------------------------------------------------------- envelopes

  /// Attack then exponential decay (time constant [tau]).
  static double _ad(double t, double attack, double tau) => t < attack ? t / attack : math.exp(-(t - attack) / tau);

  /// Smooth rise to 1 at [top], back to 0 at [end].
  static double _bell(double t, double top, double end) {
    if (t <= 0 || t >= end) return 0;
    final x = t < top ? t / top : 1 - (t - top) / math.max(1e-6, end - top);
    return math.sin(x.clamp(0.0, 1.0) * math.pi / 2);
  }

  // -------------------------------------------------------------- primitives

  static (double, double) _panGains(double pan) {
    final a = (pan.clamp(-1.0, 1.0) + 1) * math.pi / 4;
    return (math.cos(a) * math.sqrt2, math.sin(a) * math.sqrt2);
  }

  /// A tone from [at] for [dur] seconds; frequency glides exponentially from
  /// [f0] to [f1] over [glide] seconds (default the whole tone).
  static void _tone(Float32List l, Float32List r,
      {required double at,
      required double dur,
      required double f0,
      double? f1,
      double? glide,
      double gain = 1,
      double pan = 0,
      String wave = 'sine',
      double Function(double t)? env}) {
    final s0 = math.max(0, (at * rate).round());
    final s1 = math.min(l.length, ((at + dur) * rate).round());
    final (gl, gr) = _panGains(pan);
    final g1 = f1 ?? f0;
    final gd = glide ?? dur;
    var phase = 0.0;
    for (int i = s0; i < s1; i++) {
      final t = (i - s0) / rate;
      final hz = f0 * math.pow(g1 / f0, math.min(1.0, t / math.max(1e-6, gd)));
      phase += hz / rate;
      phase -= phase.floorToDouble();
      final double w = switch (wave) {
        'saw' => phase * 2 - 1,
        'square' => phase < 0.5 ? 1.0 : -1.0,
        _ => math.sin(phase * 2 * math.pi),
      };
      final v = w * gain * (env == null ? 1.0 : env(t));
      l[i] += v * gl;
      r[i] += v * gr;
    }
  }

  /// Filtered noise from [at] for [dur]: optional one-pole low-pass [lowHz],
  /// one-pole high-pass [highHz], band-pass [bandHz] (sweeping to [bandHz1]).
  static void _noise(Float32List l, Float32List r, math.Random rnd,
      {required double at,
      required double dur,
      double gain = 1,
      double? lowHz,
      double? highHz,
      double? bandHz,
      double? bandHz1,
      double q = 0.5,
      double pan = 0,
      double Function(double t)? env}) {
    final s0 = math.max(0, (at * rate).round());
    final s1 = math.min(l.length, ((at + dur) * rate).round());
    final (gl, gr) = _panGains(pan);
    final aLow = lowHz == null ? 1.0 : 1 - math.exp(-2 * math.pi * lowHz / rate);
    final aHigh = highHz == null ? 0.0 : math.exp(-2 * math.pi * highHz / rate);
    var lpL = 0.0, lpR = 0.0, hpL = 0.0, hpR = 0.0, pxL = 0.0, pxR = 0.0;
    var bLowL = 0.0, bBandL = 0.0, bLowR = 0.0, bBandR = 0.0;
    final n = math.max(1, s1 - s0);
    for (int i = s0; i < s1; i++) {
      final t = (i - s0) / rate;
      var xL = rnd.nextDouble() * 2 - 1, xR = rnd.nextDouble() * 2 - 1;
      if (bandHz != null) {
        final hz = bandHz * math.pow((bandHz1 ?? bandHz) / bandHz, (i - s0) / n);
        final f = 2 * math.sin(math.pi * math.min(7000.0, hz) / rate);
        bLowL += f * bBandL;
        bBandL += f * (xL - bLowL - q * bBandL);
        bLowR += f * bBandR;
        bBandR += f * (xR - bLowR - q * bBandR);
        xL = bBandL;
        xR = bBandR;
      }
      if (lowHz != null) {
        lpL += aLow * (xL - lpL);
        lpR += aLow * (xR - lpR);
        xL = lpL;
        xR = lpR;
      }
      if (highHz != null) {
        hpL = aHigh * (hpL + xL - pxL);
        hpR = aHigh * (hpR + xR - pxR);
        pxL = xL;
        pxR = xR;
        xL = hpL;
        xR = hpR;
      }
      final e = gain * (env == null ? _ad(t, 0.0005, math.max(0.0005, dur / 3)) : env(t));
      l[i] += xL * e * gl;
      r[i] += xR * e * gr;
    }
  }

  static void _keyClick(Float32List l, Float32List r, math.Random rnd, double at, double g) {
    final pan = rnd.nextDouble() * 0.6 - 0.3;
    _noise(l, r, rnd, at: at, dur: 0.004, bandHz: 3000, q: 0.3, gain: g * 1.4, pan: pan);
    _tone(l, r, at: at, dur: 0.012, f0: 2000 + rnd.nextDouble() * 500, gain: g * 0.45, pan: pan, env: (t) => _ad(t, 0.0003, 0.003));
    _tone(l, r, at: at, dur: 0.03, f0: 160, gain: g * 0.5, pan: pan, env: (t) => _ad(t, 0.001, 0.01));
  }

  static void _braam(Float32List l, Float32List r, math.Random rnd) {
    final n = l.length;
    final rel = (0.35 * rate).round();
    var p1 = 0.0, p2 = 0.0, p3 = 0.0, p4 = 0.0, sub = 0.0;
    var a1 = 0.0, a2 = 0.0, b1 = 0.0, b2 = 0.0;
    for (int i = 0; i < n; i++) {
      final t = i / rate;
      p1 = (p1 + 55.0 / rate) % 1;
      p2 = (p2 + 55.45 / rate) % 1;
      p3 = (p3 + 82.6 / rate) % 1;
      p4 = (p4 + 110.3 / rate) % 1;
      sub += 2 * math.pi * 41.2 / rate;
      final saws = (p1 * 2 - 1) + (p2 * 2 - 1) + 0.6 * (p3 * 2 - 1) + 0.5 * (p4 * 2 - 1);
      final cutoff = 260 + 1100 * math.exp(-t / 0.5);
      final a = 1 - math.exp(-2 * math.pi * cutoff / rate);
      final noise = (rnd.nextDouble() * 2 - 1) * 0.15;
      a1 += a * (saws + noise - a1);
      a2 += a * (a1 - a2);
      b1 += a * (saws * 0.98 - noise - b1);
      b2 += a * (b1 - b2);
      var env = t < 0.06 ? t / 0.06 : math.exp(-(t - 0.06) / 1.6);
      if (i > n - rel) env *= (n - i) / rel;
      final s = math.sin(sub) * 0.7;
      l[i] += (a2 + s) * env;
      r[i] += (b2 + s) * env;
    }
    _reverb(l, r, 0.22);
  }

  static void _glitch(Float32List l, Float32List r, math.Random rnd) {
    var t = 0.0;
    var first = true;
    while (t < 0.55) {
      final d = 0.02 + rnd.nextDouble() * 0.05;
      final kind = first ? 0 : rnd.nextInt(10);
      final g = first ? 1.0 : 0.4 + rnd.nextDouble() * 0.5;
      final hold = 2 + rnd.nextInt(11);
      final s0 = (t * rate).round(), s1 = math.min(l.length, ((t + d) * rate).round());
      final hz = 200 + rnd.nextDouble() * 2800;
      var ph = 0.0, held = 0.0;
      for (int i = s0; i < s1; i++) {
        if ((i - s0) % hold == 0) {
          ph = (ph + hz * hold / rate) % 1;
          held = kind < 5 ? (ph < 0.5 ? 1.0 : -1.0) : (kind < 9 ? rnd.nextDouble() * 2 - 1 : 0.0);
        }
        final edge = math.min(1.0, math.min(i - s0, s1 - i) / 40);
        l[i] += held * g * edge;
        r[i] += held * g * edge * (kind.isEven ? 1 : 0.6);
      }
      t += d;
      first = false;
    }
  }

  static void _crowd(Float32List l, Float32List r, math.Random rnd) {
    final total = l.length / rate;
    _noise(l, r, rnd, at: 0, dur: total, bandHz: 500, q: 0.8, gain: 0.25, env: (_) => 1);
    for (int v = 0; v < 14; v++) {
      final pan = rnd.nextDouble() * 1.6 - 0.8;
      final level = 0.4 + rnd.nextDouble() * 0.6;
      var t = rnd.nextDouble() * 0.5;
      while (t < total - 0.3) {
        final d = 0.08 + rnd.nextDouble() * 0.17;
        _noise(l, r, rnd, at: t, dur: d, bandHz: 350 + rnd.nextDouble() * 750, q: 0.25, gain: level, pan: pan, env: (u) => _bell(u, d / 2, d));
        t += d + (rnd.nextDouble() < 0.2 ? 0.2 + rnd.nextDouble() * 0.5 : 0.02 + rnd.nextDouble() * 0.06);
      }
    }
  }

  static void _wind(Float32List l, Float32List r, math.Random rnd, {required double gain}) {
    final n = l.length;
    var lowL = 0.0, bandL = 0.0, lowR = 0.0, bandR = 0.0;
    final phase = rnd.nextDouble() * math.pi * 2;
    for (int i = 0; i < n; i++) {
      final t = i / rate;
      final gust = 0.55 + 0.45 * math.sin(2 * math.pi * 0.21 * t + phase) * math.sin(2 * math.pi * 0.07 * t);
      final hzL = 250 + 600 * gust;
      final hzR = 250 + 600 * (0.55 + 0.45 * math.sin(2 * math.pi * 0.19 * t + phase + 1.3) * math.sin(2 * math.pi * 0.08 * t));
      final fL = 2 * math.sin(math.pi * hzL / rate), fR = 2 * math.sin(math.pi * hzR / rate);
      final xL = rnd.nextDouble() * 2 - 1, xR = rnd.nextDouble() * 2 - 1;
      lowL += fL * bandL;
      bandL += fL * (xL - lowL - 0.3 * bandL);
      lowR += fR * bandR;
      bandR += fR * (xR - lowR - 0.3 * bandR);
      l[i] += bandL * gain * gust;
      r[i] += bandR * gain * gust;
    }
  }

  /// Small Schroeder reverb (4 combs + 2 all-passes) mixed in by [mix].
  static void _reverb(Float32List l, Float32List r, double mix) {
    final n = l.length;
    Float32List run(Float32List x, int spread) {
      final out = Float32List(n);
      for (final d0 in [1116, 1188, 1277, 1356]) {
        final d = d0 + spread;
        final buf = Float32List(d);
        var k = 0;
        var lp = 0.0;
        for (int i = 0; i < n; i++) {
          final y = buf[k];
          lp = y * 0.8 + lp * 0.2;
          buf[k] = x[i] + lp * 0.82;
          out[i] += y * 0.25 * 0.18; // ×(1 − feedback): unity steady-state gain
          k = (k + 1) % d;
        }
      }
      for (final d0 in [556, 441]) {
        final d = d0 + spread;
        final buf = Float32List(d);
        var k = 0;
        for (int i = 0; i < n; i++) {
          final b = buf[k];
          final y = -out[i] + b;
          buf[k] = out[i] + b * 0.5;
          out[i] = y;
          k = (k + 1) % d;
        }
      }
      return out;
    }

    final wl = run(l, 0), wr = run(r, 23);
    for (int i = 0; i < n; i++) {
      l[i] = l[i] * (1 - mix) + wl[i] * mix;
      r[i] = r[i] * (1 - mix) + wr[i] * mix;
    }
  }

  /// Makes a seamless loop of [n] samples: the extra [x] samples rendered
  /// past the end are cross-faded into the start.
  static (Float32List, Float32List) _loop(Float32List l, Float32List r, int n, int x) {
    final ol = Float32List(n), or = Float32List(n);
    for (int i = 0; i < n; i++) {
      ol[i] = l[i];
      or[i] = r[i];
    }
    for (int i = 0; i < x && i < n; i++) {
      final k = i / x;
      final fi = math.sin(k * math.pi / 2), fo = math.cos(k * math.pi / 2);
      ol[i] = l[i] * fi + l[n + i] * fo;
      or[i] = r[i] * fi + r[n + i] * fo;
    }
    return (ol, or);
  }

  // ------------------------------------------- original helpers (unchanged)

  static void _noiseSweep(Float32List l, Float32List r, math.Random rnd,
      {required double fromHz, required double toHz, required double attack, required bool pan}) {
    final n = l.length;
    var lpL = 0.0, lpR = 0.0, bpL = 0.0, bpR = 0.0;
    for (int i = 0; i < n; i++) {
      final t = i / n;
      final env = t < attack ? math.pow(t / attack, 2.2).toDouble() : math.pow(1 - (t - attack) / (1 - attack), 1.6).toDouble();
      final hz = fromHz * math.pow(toHz / fromHz, t);
      final f = 2 * math.sin(math.pi * hz / rate);
      final q = 0.35;
      final xL = rnd.nextDouble() * 2 - 1, xR = rnd.nextDouble() * 2 - 1;
      // State-variable band-pass filter.
      lpL += f * bpL;
      bpL += f * (xL - lpL - q * bpL);
      lpR += f * bpR;
      bpR += f * (xR - lpR - q * bpR);
      final p = pan ? t : 0.5;
      l[i] += bpL * env * (1.2 - p * 0.6);
      r[i] += bpR * env * (0.6 + p * 0.6);
    }
  }

  static void _addTone(Float32List l, Float32List r, double fromHz, double toHz, double gain, {required bool exp}) {
    final n = l.length;
    var phase = 0.0;
    for (int i = 0; i < n; i++) {
      final t = i / n;
      final hz = fromHz + (toHz - fromHz) * math.sqrt(t);
      phase += 2 * math.pi * hz / rate;
      final env = exp ? math.exp(-t * 6) : math.pow(t, 2).toDouble();
      final v = math.sin(phase) * env * gain;
      l[i] += v;
      r[i] += v;
    }
  }

  static void _burst(Float32List l, Float32List r, math.Random rnd, double seconds, double gain) {
    final m = math.min(l.length, (seconds * rate).round());
    for (int i = 0; i < m; i++) {
      final env = 1 - i / m;
      l[i] += (rnd.nextDouble() * 2 - 1) * env * gain;
      r[i] += (rnd.nextDouble() * 2 - 1) * env * gain;
    }
  }

  static void _tail(Float32List l, Float32List r, math.Random rnd, double gain) {
    var a = 0.0, b = 0.0;
    for (int i = 0; i < l.length; i++) {
      final t = i / l.length;
      a = a * 0.97 + (rnd.nextDouble() * 2 - 1) * 0.03;
      b = b * 0.97 + (rnd.nextDouble() * 2 - 1) * 0.03;
      final env = math.exp(-t * 4);
      l[i] += a * env * gain * 6;
      r[i] += b * env * gain * 6;
    }
  }

  static void _normalize(Float32List l, Float32List r, double target) {
    var peak = 1e-6;
    for (int i = 0; i < l.length; i++) {
      peak = math.max(peak, math.max(l[i].abs(), r[i].abs()));
    }
    final g = target / peak;
    for (int i = 0; i < l.length; i++) {
      l[i] *= g;
      r[i] *= g;
    }
  }

  /// 16-bit stereo PCM WAV of [l]/[r] at [rate].
  static Uint8List encode(Float32List l, Float32List r) {
    final n = l.length;
    final bytes = ByteData(44 + n * 4);
    void str(int at, String s) {
      for (int i = 0; i < s.length; i++) {
        bytes.setUint8(at + i, s.codeUnitAt(i));
      }
    }

    str(0, 'RIFF');
    bytes.setUint32(4, 36 + n * 4, Endian.little);
    str(8, 'WAVE');
    str(12, 'fmt ');
    bytes.setUint32(16, 16, Endian.little);
    bytes.setUint16(20, 1, Endian.little);
    bytes.setUint16(22, 2, Endian.little);
    bytes.setUint32(24, rate, Endian.little);
    bytes.setUint32(28, rate * 4, Endian.little);
    bytes.setUint16(32, 4, Endian.little);
    bytes.setUint16(34, 16, Endian.little);
    str(36, 'data');
    bytes.setUint32(40, n * 4, Endian.little);
    for (int i = 0; i < n; i++) {
      bytes.setInt16(44 + i * 4, (l[i].clamp(-1.0, 1.0) * 32767).round(), Endian.little);
      bytes.setInt16(46 + i * 4, (r[i].clamp(-1.0, 1.0) * 32767).round(), Endian.little);
    }
    return bytes.buffer.asUint8List();
  }
}
