import 'dart:convert';
import 'dart:math' as math;

/// Pure helpers that build FFmpeg / FFprobe command lines for the Windows
/// media layer. Kept free of dart:io so they are unit-tested on any OS.

/// What ffprobe tells us about a media file.
class ProbeInfo {
  final double duration;
  final int width, height; // coded size (before rotation)
  final int rotation; // degrees, 0/90/180/270
  final double fps;
  final bool hasVideo, hasAudio;
  final int audioChannels;

  const ProbeInfo({
    this.duration = 0,
    this.width = 0,
    this.height = 0,
    this.rotation = 0,
    this.fps = 30,
    this.hasVideo = false,
    this.hasAudio = false,
    this.audioChannels = 2,
  });

  bool get _swap => rotation % 180 == 90;

  /// Size as displayed (rotation applied), like the phone's decoder.
  int get displayWidth => _swap ? height : width;
  int get displayHeight => _swap ? width : height;

  @override
  String toString() => 'ProbeInfo(${displayWidth}x$displayHeight, ${duration}s, $fps fps, v=$hasVideo a=$hasAudio)';
}

double _num(dynamic v, [double d = 0]) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v) ?? d;
  return d;
}

/// "30000/1001" → 29.97; "0/0" → 0.
double parseRate(dynamic s) {
  if (s is num) return s.toDouble();
  if (s is! String || s.isEmpty) return 0;
  final i = s.indexOf('/');
  if (i < 0) return double.tryParse(s) ?? 0;
  final a = double.tryParse(s.substring(0, i)) ?? 0, b = double.tryParse(s.substring(i + 1)) ?? 0;
  return b == 0 ? 0 : a / b;
}

/// Parses `ffprobe -print_format json -show_streams -show_format`.
ProbeInfo parseProbe(String json) {
  final j = jsonDecode(json) as Map<String, dynamic>;
  final streams = (j['streams'] as List? ?? const []).cast<Map>();
  Map? video, audio;
  for (final s in streams) {
    final type = s['codec_type'];
    final attached = (s['disposition'] as Map?)?['attached_pic'] == 1;
    if (type == 'video' && !attached && video == null) video = s;
    if (type == 'audio' && audio == null) audio = s;
  }
  var duration = _num((j['format'] as Map?)?['duration']);
  if (duration <= 0) duration = math.max(_num(video?['duration']), _num(audio?['duration']));
  var rot = 0;
  if (video != null) {
    for (final sd in (video['side_data_list'] as List? ?? const [])) {
      if (sd is Map && sd['rotation'] != null) rot = _num(sd['rotation']).round();
    }
    final tag = (video['tags'] as Map?)?['rotate'];
    if (rot == 0 && tag != null) rot = _num(tag).round();
  }
  rot = ((rot % 360) + 360) % 360;
  var fps = parseRate(video?['avg_frame_rate']);
  if (fps <= 0 || fps > 240) fps = parseRate(video?['r_frame_rate']);
  if (fps <= 0 || fps > 240) fps = 30;
  return ProbeInfo(
    duration: duration,
    width: (video?['width'] as num?)?.toInt() ?? 0,
    height: (video?['height'] as num?)?.toInt() ?? 0,
    rotation: rot,
    fps: fps,
    hasVideo: video != null,
    hasAudio: audio != null,
    audioChannels: (audio?['channels'] as num?)?.toInt() ?? 2,
  );
}

/// Scales (w, h) down to fit [maxSize] on the long side (never up).
(int, int) fitSize(int w, int h, int maxSize) {
  if (w <= 0 || h <= 0) return (math.max(2, math.min(maxSize, 1280)), math.max(2, math.min(maxSize, 720)));
  final scale = math.min(1.0, maxSize / math.max(w, h));
  return (math.max(2, (w * scale).round()), math.max(2, (h * scale).round()));
}

/// Number formatting for FFmpeg args/expressions: short, no exponent.
String ffNum(double v) {
  if (v.isNaN || v.isInfinite) return '0';
  if (v == v.roundToDouble() && v.abs() < 1e12) return v.round().toString();
  var s = v.toStringAsFixed(4);
  s = s.replaceFirst(RegExp(r'0+$'), '');
  if (s.endsWith('.')) s = s.substring(0, s.length - 1);
  return s == '-0' ? '0' : s;
}

const _quiet = ['-hide_banner', '-loglevel', 'error', '-nostdin'];

List<String> _seek(double seconds) => seconds > 0.0005 ? ['-ss', ffNum(seconds)] : const [];

List<String> probeArgs(String path) =>
    ['-v', 'error', '-print_format', 'json', '-show_streams', '-show_format', path];

/// One raw RGBA frame of [path] at [seconds], scaled to tw×th, on stdout.
List<String> frameArgs(String path, double seconds, int tw, int th) => [
      ..._quiet,
      ..._seek(seconds),
      '-i', path,
      '-an', '-sn', '-dn',
      '-frames:v', '1',
      '-vf', 'scale=$tw:$th:flags=bicubic',
      '-pix_fmt', 'rgba',
      '-f', 'rawvideo',
      '-',
    ];

/// Sequential reader: constant-rate RGBA frames from [seconds] onwards.
/// Frame k on stdout shows source time `seconds + k / fps`.
/// win-30: decode video on the GPU when one is available (NVDEC / D3D11VA /
/// Quick Sync); FFmpeg falls back to the CPU by itself and copies frames to
/// system memory for the scale filter.
bool hwDecode = true;

List<String> readerArgs(String path, double seconds, int tw, int th, double fps) => [
      ..._quiet,
      if (hwDecode) ...['-hwaccel', 'auto'],
      ..._seek(seconds),
      '-i', path,
      '-an', '-sn', '-dn',
      '-vf', 'scale=$tw:$th:flags=bicubic,fps=${ffNum(fps)}',
      '-fps_mode', 'passthrough',
      '-pix_fmt', 'rgba',
      '-f', 'rawvideo',
      '-',
    ];

/// One JPEG frame on stdout.
List<String> thumbArgs(String path, double seconds, int tw, int th) => [
      ..._quiet,
      ..._seek(seconds),
      '-i', path,
      '-an', '-sn', '-dn',
      '-frames:v', '1',
      '-vf', 'scale=$tw:$th:flags=bicubic',
      '-q:v', '4',
      '-c:v', 'mjpeg',
      '-f', 'image2pipe',
      '-',
    ];

/// 16 kHz mono 16-bit WAV for speech-to-text. [duration] 0 = to the end.
List<String> wav16kArgs(String path, String out, {double sourceIn = 0, double duration = 0}) => [
      '-y', ..._quiet,
      ..._seek(sourceIn),
      if (duration > 0) ...['-t', ffNum(duration)],
      '-i', path,
      '-vn', '-sn', '-dn',
      '-ac', '1',
      '-ar', '16000',
      '-c:a', 'pcm_s16le',
      out,
    ];

/// Copies (or, with [reencode], converts to AAC) the first audio track.
List<String> extractAudioArgs(String path, String out, {bool reencode = false}) => [
      '-y', ..._quiet,
      '-i', path,
      '-vn', '-sn', '-dn',
      '-map', '0:a:0',
      if (reencode) ...['-c:a', 'aac', '-b:a', '192k'] else ...['-c:a', 'copy'],
      out,
    ];

/// H.264 encoders in order of preference (GPU first, CPU last).
const kEncoders = ['h264_nvenc', 'h264_qsv', 'h264_amf', 'libx264'];

String encoderLabel(String enc) => switch (enc) {
      'h264_nvenc' => 'NVIDIA (NVENC)',
      'h264_qsv' => 'Intel Quick Sync',
      'h264_amf' => 'AMD (AMF)',
      'libx264' => 'CPU (x264)',
      _ => enc,
    };

String _pixFmt(String enc) => enc == 'h264_qsv' ? 'nv12' : 'yuv420p';

/// A tiny test encode that tells whether [enc] works on this PC.
List<String> encoderProbeArgs(String enc) => [
      ..._quiet,
      '-f', 'lavfi',
      '-i', 'color=c=black:s=640x360:r=30:d=0.2',
      '-vf', 'format=${_pixFmt(enc)}',
      '-c:v', enc,
      '-f', 'null',
      '-',
    ];

List<String> _encoderOptions(String enc, int bitrate) {
  final b = '${(bitrate / 1000).round()}k';
  final max = '${(bitrate * 1.5 / 1000).round()}k';
  final buf = '${(bitrate * 2 / 1000).round()}k';
  return switch (enc) {
    'h264_nvenc' => ['-preset', 'p5', '-tune', 'hq', '-rc', 'vbr', '-b:v', b, '-maxrate', max, '-bufsize', buf, '-profile:v', 'high'],
    'h264_qsv' => ['-preset', 'medium', '-b:v', b, '-maxrate', max, '-bufsize', buf, '-profile:v', 'high'],
    'h264_amf' => ['-quality', 'quality', '-rc', 'vbr_peak', '-b:v', b, '-maxrate', max, '-bufsize', buf, '-profile:v', 'high'],
    _ => ['-preset', 'medium', '-crf', '18', '-maxrate', max, '-bufsize', buf, '-profile:v', 'high'],
  };
}

/// Reads raw RGBA frames on stdin and writes an H.264 MP4 (video only).
List<String> encoderArgs(String enc, String out, int w, int h, double fps, int bitrate) => [
      '-y', '-hide_banner', '-loglevel', 'error',
      '-f', 'rawvideo',
      '-pix_fmt', 'rgba',
      '-s', '${w}x$h',
      '-framerate', ffNum(fps),
      '-i', '-',
      '-an',
      '-vf', 'scale=out_color_matrix=bt709:out_range=tv,format=${_pixFmt(enc)}',
      '-c:v', enc,
      ..._encoderOptions(enc, bitrate),
      '-g', '${math.max(1, (fps * 2).round())}',
      '-color_primaries', 'bt709',
      '-color_trc', 'bt709',
      '-colorspace', 'bt709',
      '-movflags', '+faststart',
      out,
    ];

// ------------------------------------------------------------- audio mix

double _distToSegment(List<double> p, List<double> a, List<double> b) {
  final dt = b[0] - a[0];
  if (dt.abs() < 1e-12) return (p[1] - a[1]).abs();
  final k = (p[0] - a[0]) / dt;
  return (p[1] - (a[1] + (b[1] - a[1]) * k)).abs();
}

/// Ramer–Douglas–Peucker on [[t, gain], ...]: drops points that lie within
/// [tolerance] (gain units) of the line through their neighbours.
List<List<double>> simplifyEnvelope(List<List<double>> pts, {double tolerance = 0.004}) {
  final sorted = [
    for (final p in pts)
      if (p.length >= 2 && p[0].isFinite && p[1].isFinite) [p[0], p[1]]
  ]..sort((a, b) => a[0].compareTo(b[0]));
  if (sorted.length <= 2) return sorted;
  final keep = List<bool>.filled(sorted.length, false);
  keep[0] = keep[sorted.length - 1] = true;
  final stack = <(int, int)>[(0, sorted.length - 1)];
  while (stack.isNotEmpty) {
    final (a, b) = stack.removeLast();
    var best = -1.0;
    var bi = -1;
    for (var i = a + 1; i < b; i++) {
      final d = _distToSegment(sorted[i], sorted[a], sorted[b]);
      if (d > best) {
        best = d;
        bi = i;
      }
    }
    if (bi >= 0 && best > tolerance) {
      keep[bi] = true;
      stack
        ..add((a, bi))
        ..add((bi, b));
    }
  }
  return [for (var i = 0; i < sorted.length; i++) if (keep[i]) sorted[i]];
}

/// Piecewise-linear gain [[t, gain], ...] (composition seconds) as an FFmpeg
/// expression of `t`, where t = 0 at composition time [offset]. Uses a flat
/// sum of segments (no deep nesting). Values outside the points hold.
String envelopeExpr(List<List<double>> envelope, {double offset = 0, int maxPoints = 80}) {
  var pts = simplifyEnvelope(envelope);
  var tol = 0.004;
  while (pts.length > maxPoints && tol < 1) {
    tol *= 2;
    pts = simplifyEnvelope(envelope, tolerance: tol);
  }
  if (pts.isEmpty) return '1';
  final p = [for (final e in pts) [e[0] - offset, math.max(0.0, e[1])]];
  if (p.length == 1) return ffNum(p[0][1]);
  final terms = <String>['lt(t,${ffNum(p[0][0])})*${ffNum(p[0][1])}'];
  for (var i = 0; i < p.length - 1; i++) {
    final t0 = p[i][0], g0 = p[i][1], t1 = p[i + 1][0], g1 = p[i + 1][1];
    if (t1 - t0 < 1e-6) continue;
    final slope = (g1 - g0) / (t1 - t0);
    final seg = slope.abs() < 1e-9 ? ffNum(g0) : '(${ffNum(g0)}+${ffNum(slope)}*(t-${ffNum(t0)}))';
    terms.add('gte(t,${ffNum(t0)})*lt(t,${ffNum(t1)})*$seg');
  }
  terms.add('gte(t,${ffNum(p.last[0])})*${ffNum(p.last[1])}');
  return terms.join('+').replaceAll('--', '+').replaceAll('+-', '-');
}

/// One audio source for the final mix (same fields the Android mixer reads).
class MixClip {
  final String path;
  final double start, sourceIn, duration, speed, volume;
  final List<List<double>>? envelope;
  final bool mono;
  const MixClip({
    required this.path,
    this.start = 0,
    this.sourceIn = 0,
    required this.duration,
    this.speed = 1,
    this.volume = 1,
    this.envelope,
    this.mono = false,
  });

  static double _d(dynamic v, double d) => v is num ? v.toDouble() : d;

  factory MixClip.fromMap(Map<String, dynamic> m, {bool mono = false}) {
    List<List<double>>? env;
    final raw = m['envelope'];
    if (raw is List) {
      env = [
        for (final p in raw)
          if (p is List && p.length >= 2 && p[0] is num && p[1] is num) [(p[0] as num).toDouble(), (p[1] as num).toDouble()]
      ];
      if (env.isEmpty) env = null;
    }
    return MixClip(
      path: '${m['path']}',
      start: _d(m['start'], 0),
      sourceIn: _d(m['sourceIn'], 0),
      duration: _d(m['duration'], 0),
      speed: _d(m['speed'], 1).clamp(0.05, 16.0).toDouble(),
      volume: _d(m['volume'], 1),
      envelope: env,
      mono: mono,
    );
  }

  /// Clips that would be silent are skipped (like the phone mixer).
  bool get audible => duration > 0 && (volume > 0 || envelope != null);
}

/// FFmpeg filter graph that mixes [clips] (inputs 1..n; input 0 is the
/// video) into `[aout]`, [duration] seconds long, 44.1 kHz stereo.
String mixFilterGraph(List<MixClip> clips, double duration) {
  final parts = <String>[];
  final labels = <String>[];
  for (var i = 0; i < clips.length; i++) {
    final c = clips[i];
    final f = <String>[
      if (c.mono) 'pan=stereo|c0=c0|c1=c0',
      'aresample=44100',
      'aformat=sample_fmts=fltp:sample_rates=44100:channel_layouts=stereo',
      // Speed changes pitch too, exactly like the phone's resampling mixer.
      if ((c.speed - 1).abs() > 1e-4) ...['asetrate=${(44100 * c.speed).round()}', 'aresample=44100'],
      'asetpts=PTS-STARTPTS',
      c.envelope != null
          ? "volume=volume='${envelopeExpr(c.envelope!, offset: c.start)}':eval=frame"
          : 'volume=${ffNum(c.volume)}',
      if (c.start > 0.0005) 'adelay=delays=${(c.start * 1000).round()}:all=1',
    ];
    parts.add('[${i + 1}:a]${f.join(',')}[a$i]');
    labels.add('[a$i]');
  }
  final mix = labels.length == 1
      ? '${labels.first}anull[mx]'
      : '${labels.join()}amix=inputs=${labels.length}:duration=longest:dropout_transition=0:normalize=0[mx]';
  parts.add(mix);
  parts.add('[mx]apad=whole_dur=${ffNum(duration)},atrim=0:${ffNum(duration)}[aout]');
  return parts.join(';\n');
}

/// Command that muxes [videoPath] with the mixed [clips]. The filter graph
/// is read from [filterScriptPath] (avoids the Windows command-line limit).
List<String> muxArgs(String videoPath, List<MixClip> clips, double duration, String out, String filterScriptPath) {
  if (clips.isEmpty) {
    return ['-y', ..._quiet, '-i', videoPath, '-map', '0:v:0', '-c', 'copy', '-movflags', '+faststart', out];
  }
  return [
    '-y', ..._quiet,
    '-i', videoPath,
    for (final c in clips) ...[
      ..._seek(c.sourceIn),
      '-t', ffNum(c.duration * c.speed),
      '-i', c.path,
    ],
    '-/filter_complex', filterScriptPath,
    '-map', '0:v:0',
    '-map', '[aout]',
    '-c:v', 'copy',
    '-c:a', 'aac',
    '-b:a', '192k',
    '-ar', '44100',
    '-t', ffNum(duration),
    '-movflags', '+faststart',
    out,
  ];
}
