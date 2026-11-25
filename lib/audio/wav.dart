import 'dart:math' as math;
import 'dart:typed_data';

/// Decoded PCM audio: one Float32List (−1..1) per channel.
class PcmAudio {
  final int sampleRate;
  final List<Float32List> channels;
  PcmAudio(this.sampleRate, this.channels);

  int get length => channels.isEmpty ? 0 : channels.first.length;
  double get duration => sampleRate <= 0 ? 0 : length / sampleRate;

  /// Average of all channels.
  Float32List mono() {
    if (channels.length == 1) return channels.first;
    final out = Float32List(length);
    final k = 1 / channels.length;
    for (final c in channels) {
      for (int i = 0; i < out.length; i++) {
        out[i] += c[i] * k;
      }
    }
    return out;
  }
}

/// Pure-Dart WAV (RIFF/WAVE) reader and writer.
///
/// Reads PCM 8/16/24/32-bit integer and 32/64-bit float, including
/// WAVE_FORMAT_EXTENSIBLE; skips unknown chunks (LIST, fact, …). Enough to
/// read MediaBridge.wav16k output (16 kHz mono 16-bit) and every WAV the
/// SFX synth writes.
class Wav {
  static PcmAudio decode(Uint8List bytes) {
    if (bytes.length < 12) throw const FormatException('Not a WAV file (too short)');
    final d = ByteData.sublistView(bytes);
    String tag(int at) => String.fromCharCodes(bytes.sublist(at, at + 4));
    final riff = tag(0);
    if ((riff != 'RIFF' && riff != 'RF64') || tag(8) != 'WAVE') throw const FormatException('Not a WAV file');
    int? format, channels, rate, bits;
    int dataAt = -1, dataLen = 0;
    var p = 12;
    while (p + 8 <= bytes.length) {
      final id = tag(p);
      var size = d.getUint32(p + 4, Endian.little);
      final body = p + 8;
      if (id == 'fmt ') {
        format = d.getUint16(body, Endian.little);
        channels = d.getUint16(body + 2, Endian.little);
        rate = d.getUint32(body + 4, Endian.little);
        bits = d.getUint16(body + 14, Endian.little);
        if (format == 0xFFFE && size >= 40) format = d.getUint16(body + 24, Endian.little); // sub-format GUID
      } else if (id == 'data') {
        dataAt = body;
        // Streaming writers may leave the size 0 or 0xFFFFFFFF: take the rest.
        if (size == 0 || size == 0xFFFFFFFF || body + size > bytes.length) size = bytes.length - body;
        dataLen = size;
        break;
      }
      p = body + size + (size.isOdd ? 1 : 0);
    }
    if (format == null || channels == null || rate == null || bits == null) throw const FormatException('WAV has no fmt chunk');
    if (dataAt < 0) throw const FormatException('WAV has no data chunk');
    if (channels < 1 || rate < 1) throw const FormatException('WAV has a bad fmt chunk');
    final isFloat = format == 3;
    if (format != 1 && !isFloat) throw FormatException('Unsupported WAV encoding $format (only PCM and float)');
    final bps = bits ~/ 8;
    if (bps < 1 || (isFloat && bps != 4 && bps != 8) || (!isFloat && bps > 4)) throw FormatException('Unsupported WAV sample size $bits');
    final frame = bps * channels;
    final n = dataLen ~/ frame;
    final out = [for (int c = 0; c < channels; c++) Float32List(n)];
    for (int i = 0; i < n; i++) {
      for (int c = 0; c < channels; c++) {
        final at = dataAt + i * frame + c * bps;
        double v;
        if (isFloat) {
          v = bps == 4 ? d.getFloat32(at, Endian.little) : d.getFloat64(at, Endian.little);
        } else {
          switch (bps) {
            case 1:
              v = (d.getUint8(at) - 128) / 128.0;
              break;
            case 2:
              v = d.getInt16(at, Endian.little) / 32768.0;
              break;
            case 3:
              var x = d.getUint8(at) | (d.getUint8(at + 1) << 8) | (d.getUint8(at + 2) << 16);
              if (x & 0x800000 != 0) x -= 0x1000000;
              v = x / 8388608.0;
              break;
            default:
              v = d.getInt32(at, Endian.little) / 2147483648.0;
          }
        }
        out[c][i] = v;
      }
    }
    return PcmAudio(rate, out);
  }

  /// Integer PCM WAV ([bits] 16, 24 or 32) of [channels] at [sampleRate].
  static Uint8List encode(List<Float32List> channels, int sampleRate, {int bits = 16}) {
    if (channels.isEmpty) throw ArgumentError('No channels');
    if (bits != 16 && bits != 24 && bits != 32) throw ArgumentError('bits must be 16, 24 or 32');
    final ch = channels.length;
    final n = channels.map((c) => c.length).reduce(math.min);
    final bps = bits ~/ 8;
    final dataLen = n * ch * bps;
    final d = ByteData(44 + dataLen);
    void str(int at, String s) {
      for (int i = 0; i < s.length; i++) {
        d.setUint8(at + i, s.codeUnitAt(i));
      }
    }

    str(0, 'RIFF');
    d.setUint32(4, 36 + dataLen, Endian.little);
    str(8, 'WAVE');
    str(12, 'fmt ');
    d.setUint32(16, 16, Endian.little);
    d.setUint16(20, 1, Endian.little);
    d.setUint16(22, ch, Endian.little);
    d.setUint32(24, sampleRate, Endian.little);
    d.setUint32(28, sampleRate * ch * bps, Endian.little);
    d.setUint16(32, ch * bps, Endian.little);
    d.setUint16(34, bits, Endian.little);
    str(36, 'data');
    d.setUint32(40, dataLen, Endian.little);
    var at = 44;
    for (int i = 0; i < n; i++) {
      for (int c = 0; c < ch; c++) {
        final v = channels[c][i].clamp(-1.0, 1.0).toDouble();
        switch (bps) {
          case 2:
            d.setInt16(at, (v * 32767).round(), Endian.little);
            break;
          case 3:
            final x = (v * 8388607).round() & 0xFFFFFF;
            d.setUint8(at, x & 0xFF);
            d.setUint8(at + 1, (x >> 8) & 0xFF);
            d.setUint8(at + 2, (x >> 16) & 0xFF);
            break;
          default:
            d.setInt32(at, (v * 2147483647).round(), Endian.little);
        }
        at += bps;
      }
    }
    return d.buffer.asUint8List();
  }

  /// Linear-interpolation resampling (good enough for analysis).
  static Float32List resample(Float32List x, int from, int to) {
    if (from == to || x.isEmpty) return x;
    final n = (x.length * to / from).floor();
    final out = Float32List(n);
    final step = from / to;
    for (int i = 0; i < n; i++) {
      final p = i * step;
      final k = p.floor();
      final f = p - k;
      final a = x[math.min(k, x.length - 1)], b = x[math.min(k + 1, x.length - 1)];
      out[i] = a + (b - a) * f;
    }
    return out;
  }
}
