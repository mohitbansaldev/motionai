import 'dart:math' as math;
import 'dart:typed_data';

/// Small sound effects synthesised on the phone (no stock files needed):
/// whoosh for transitions, hit for big numbers / reveals, riser before a hook,
/// tick for timelines, pop for cards, impact for intros (decays to silence).
class Sfx {
  static const kinds = ['whoosh', 'hit', 'riser', 'tick', 'pop', 'impact'];
  static const rate = 44100;

  static double length(String kind) => switch (kind) {
        'whoosh' => 0.7,
        'hit' => 1.4,
        'riser' => 2.0,
        'tick' => 0.12,
        'pop' => 0.25,
        'impact' => 2.4,
        _ => 0.5,
      };

  /// Where the "impact" of the sound sits, so it can be placed on a cut.
  static double peak(String kind) => switch (kind) {
        'whoosh' => 0.38,
        'riser' => 2.0,
        _ => 0.0,
      };

  /// 16-bit stereo WAV bytes.
  static Uint8List wav(String kind, {int seed = 7}) {
    final n = (length(kind) * rate).round();
    final l = Float32List(n), r = Float32List(n);
    final rnd = math.Random(seed);
    switch (kind) {
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
    }
    _normalize(l, r, 0.85);
    return _encode(l, r);
  }

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

  static Uint8List _encode(Float32List l, Float32List r) {
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
