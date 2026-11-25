// RIFF/WAVE header reader (Agent E, Windows AI layer).
import 'dart:typed_data';

class WavInfo {
  final int format; // 1 = PCM, 3 = float, 0xFFFE = extensible
  final int channels;
  final int sampleRate;
  final int byteRate;
  final int bitsPerSample;
  final int dataOffset;
  final int dataBytes;

  const WavInfo({
    required this.format,
    required this.channels,
    required this.sampleRate,
    required this.byteRate,
    required this.bitsPerSample,
    required this.dataOffset,
    required this.dataBytes,
  });

  double get seconds => byteRate > 0 ? dataBytes / byteRate : 0;

  static String _id(Uint8List b, int at) => String.fromCharCodes(b, at, at + 4);

  /// Parses the chunks of a WAV file. Handles extra chunks (LIST, fact…)
  /// and streaming headers whose sizes are 0 or 0xFFFFFFFF. Null when the
  /// bytes are not a readable WAV.
  static WavInfo? parse(Uint8List b) {
    if (b.length < 12 || _id(b, 0) != 'RIFF' || _id(b, 8) != 'WAVE') return null;
    final bd = ByteData.sublistView(b);
    var pos = 12;
    int? format, channels, rate, byteRate, bits;
    while (pos + 8 <= b.length) {
      final id = _id(b, pos);
      final size = bd.getUint32(pos + 4, Endian.little);
      final body = pos + 8;
      if (id == 'fmt ' && body + 16 <= b.length) {
        format = bd.getUint16(body, Endian.little);
        channels = bd.getUint16(body + 2, Endian.little);
        rate = bd.getUint32(body + 4, Endian.little);
        byteRate = bd.getUint32(body + 8, Endian.little);
        bits = bd.getUint16(body + 14, Endian.little);
      } else if (id == 'data') {
        if (format == null) return null;
        final avail = b.length - body;
        final n = (size == 0 || size == 0xFFFFFFFF || size > avail) ? avail : size;
        var br = byteRate!;
        if (br <= 0) br = rate! * channels! * (bits! ~/ 8);
        return WavInfo(
          format: format,
          channels: channels!,
          sampleRate: rate!,
          byteRate: br,
          bitsPerSample: bits!,
          dataOffset: body,
          dataBytes: n,
        );
      }
      if (size == 0xFFFFFFFF) return null;
      pos = body + size + (size & 1);
    }
    return null;
  }

  /// Seconds of audio in [b] (0 when unreadable).
  static double duration(Uint8List b) => parse(b)?.seconds ?? 0;

  /// A PCM16 WAV file (used by tests and silence padding).
  static Uint8List pcm16(Int16List samples, {int sampleRate = 16000, int channels = 1}) {
    final dataBytes = samples.length * 2;
    final out = ByteData(44 + dataBytes);
    void id(int at, String s) {
      for (var i = 0; i < 4; i++) {
        out.setUint8(at + i, s.codeUnitAt(i));
      }
    }

    id(0, 'RIFF');
    out.setUint32(4, 36 + dataBytes, Endian.little);
    id(8, 'WAVE');
    id(12, 'fmt ');
    out.setUint32(16, 16, Endian.little);
    out.setUint16(20, 1, Endian.little);
    out.setUint16(22, channels, Endian.little);
    out.setUint32(24, sampleRate, Endian.little);
    out.setUint32(28, sampleRate * channels * 2, Endian.little);
    out.setUint16(32, channels * 2, Endian.little);
    out.setUint16(34, 16, Endian.little);
    id(36, 'data');
    out.setUint32(40, dataBytes, Endian.little);
    for (var i = 0; i < samples.length; i++) {
      out.setInt16(44 + i * 2, samples[i], Endian.little);
    }
    return out.buffer.asUint8List();
  }
}
