import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:motionai/platform/byte_queue.dart';
import 'package:motionai/platform/ffmpeg_args.dart';
import 'package:motionai/platform/image_ops.dart';
import 'package:motionai/platform/whisper_cli.dart';
import 'package:motionai/platform/win_tts.dart';
import 'package:motionai/services/updater.dart';

/// Tiny evaluator for the FFmpeg expressions [envelopeExpr] produces
/// (numbers, t, + - * /, parentheses, lt(), gte()).
double evalExpr(String s, double t) {
  var i = 0;
  late double Function() sum;
  double atom() {
    if (s[i] == '(') {
      i++;
      final v = sum();
      i++; // ')'
      return v;
    }
    if (s[i] == '-') {
      i++;
      return -atom();
    }
    if (s.startsWith('lt(', i) || s.startsWith('gte(', i)) {
      final isLt = s.startsWith('lt(', i);
      i += isLt ? 3 : 4;
      final a = sum();
      i++; // ','
      final b = sum();
      i++; // ')'
      return (isLt ? a < b : a >= b) ? 1 : 0;
    }
    if (s[i] == 't') {
      i++;
      return t;
    }
    final m = RegExp(r'\d+(\.\d+)?').matchAsPrefix(s, i)!;
    i = m.end;
    return double.parse(m[0]!);
  }

  double prod() {
    var v = atom();
    while (i < s.length && (s[i] == '*' || s[i] == '/')) {
      final op = s[i++];
      final r = atom();
      v = op == '*' ? v * r : v / r;
    }
    return v;
  }

  sum = () {
    var v = prod();
    while (i < s.length && (s[i] == '+' || s[i] == '-')) {
      final op = s[i++];
      final r = prod();
      v = op == '+' ? v + r : v - r;
    }
    return v;
  };
  return sum();
}

double lerpEnv(List<List<double>> pts, double t) {
  if (t <= pts.first[0]) return pts.first[1];
  if (t >= pts.last[0]) return pts.last[1];
  for (var i = 0; i < pts.length - 1; i++) {
    if (t >= pts[i][0] && t < pts[i + 1][0]) {
      final k = (t - pts[i][0]) / (pts[i + 1][0] - pts[i][0]);
      return pts[i][1] + (pts[i + 1][1] - pts[i][1]) * k;
    }
  }
  return pts.last[1];
}

void main() {
  group('ffprobe parsing', () {
    test('rotated phone video', () {
      final p = parseProbe('''{
        "streams": [
          {"codec_type": "video", "width": 1920, "height": 1080, "avg_frame_rate": "30000/1001",
           "side_data_list": [{"side_data_type": "Display Matrix", "rotation": -90}]},
          {"codec_type": "audio", "channels": 1}
        ],
        "format": {"duration": "12.5"}
      }''');
      expect(p.hasVideo, isTrue);
      expect(p.hasAudio, isTrue);
      expect(p.audioChannels, 1);
      expect(p.rotation, 270);
      expect(p.displayWidth, 1080);
      expect(p.displayHeight, 1920);
      expect(p.duration, 12.5);
      expect(p.fps, closeTo(29.97, 0.01));
    });

    test('mp3 with cover art counts as audio only', () {
      final p = parseProbe('''{"streams": [
          {"codec_type": "audio", "channels": 2},
          {"codec_type": "video", "width": 500, "height": 500, "disposition": {"attached_pic": 1}}
        ], "format": {"duration": "180.2"}}''');
      expect(p.hasVideo, isFalse);
      expect(p.hasAudio, isTrue);
    });

    test('rates and sizes', () {
      expect(parseRate('25/1'), 25);
      expect(parseRate('0/0'), 0);
      expect(fitSize(3840, 2160, 1920), (1920, 1080));
      expect(fitSize(640, 360, 1920), (640, 360));
      expect(ffNum(30), '30');
      expect(ffNum(29.97), '29.97');
      expect(ffNum(0.1 + 0.2), '0.3');
    });
  });

  group('ffmpeg args', () {
    test('reader streams raw RGBA at a constant rate', () {
      final a = readerArgs(r'C:\v\clip.mp4', 2.5, 1280, 720, 30);
      expect(a.sublist(a.indexOf('-ss'), a.indexOf('-ss') + 2), ['-ss', '2.5']);
      expect(a.indexOf('-ss'), lessThan(a.indexOf('-i')));
      expect(a, containsAllInOrder(['-vf', 'scale=1280:720:flags=bicubic,fps=30', '-pix_fmt', 'rgba', '-f', 'rawvideo', '-']));
      expect(readerArgs('x.mp4', 0, 2, 2, 30), isNot(contains('-ss')));
    });

    test('encoder per backend', () {
      final nv = encoderArgs('h264_nvenc', 'o.mp4', 1920, 1080, 30, 12000000);
      expect(nv, containsAllInOrder(['-f', 'rawvideo', '-pix_fmt', 'rgba', '-s', '1920x1080', '-framerate', '30', '-i', '-']));
      expect(nv, containsAllInOrder(['-c:v', 'h264_nvenc', '-preset', 'p5']));
      expect(nv, containsAllInOrder(['-b:v', '12000k', '-maxrate', '18000k']));
      expect(nv.last, 'o.mp4');
      final qsv = encoderArgs('h264_qsv', 'o.mp4', 1920, 1080, 60, 1000000);
      expect(qsv.join(' '), contains('format=nv12'));
      final x264 = encoderArgs('libx264', 'o.mp4', 3840, 2160, 24, 1000000);
      expect(x264, containsAllInOrder(['-crf', '18']));
      expect(x264, isNot(contains('-b:v')));
      expect(kEncoders.last, 'libx264');
      expect(encoderProbeArgs('h264_amf'), containsAllInOrder(['-c:v', 'h264_amf', '-f', 'null']));
    });

    test('speech wav and audio extraction', () {
      expect(wav16kArgs('in.mp4', 'o.wav', sourceIn: 3, duration: 10),
          containsAllInOrder(['-ss', '3', '-t', '10', '-i', 'in.mp4', '-ac', '1', '-ar', '16000', '-c:a', 'pcm_s16le', 'o.wav']));
      expect(extractAudioArgs('a.mp4', 'a.m4a'), containsAllInOrder(['-c:a', 'copy']));
      expect(extractAudioArgs('a.mp4', 'a.m4a', reencode: true), containsAllInOrder(['-c:a', 'aac']));
      expect(thumbArgs('a.mp4', 1, 512, 288), containsAllInOrder(['-c:v', 'mjpeg', '-f', 'image2pipe']));
    });
  });

  group('audio envelope', () {
    test('expression matches piecewise-linear gain', () {
      final env = [
        [1.0, 0.0],
        [2.0, 1.0],
        [4.0, 1.0],
        [5.0, 0.2],
      ];
      final e = envelopeExpr(env, offset: 1);
      expect(e.contains(','), isTrue);
      for (var ct = 0.0; ct <= 6; ct += 0.25) {
        expect(evalExpr(e, ct - 1), closeTo(lerpEnv(env, ct), 1e-3), reason: 'at comp time $ct: $e');
      }
    });

    test('dense sampled ramps are simplified', () {
      final env = [for (var t = 0.0; t <= 10.0001; t += 0.1) [t, t < 5 ? t / 5 : 1.0]];
      final simple = simplifyEnvelope(env);
      expect(simple.length, lessThanOrEqualTo(4));
      final e = envelopeExpr(env);
      for (var t = 0.0; t <= 10; t += 0.37) {
        expect(evalExpr(e, t), closeTo(lerpEnv(env, t), 0.01));
      }
    });

    test('constant and single point', () {
      expect(envelopeExpr([
        [0.0, 0.5]
      ]), '0.5');
      expect(evalExpr(envelopeExpr([
        [0.0, 0.5],
        [3.0, 0.5]
      ]), 1.2), closeTo(0.5, 1e-9));
    });

    test('mix graph and mux command', () {
      final clips = [
        MixClip.fromMap({'path': 'music.mp3', 'start': 0.0, 'sourceIn': 0.0, 'duration': 8.0, 'speed': 1.0, 'volume': 0.6}),
        MixClip.fromMap({
          'path': 'voice.m4a',
          'start': 2.5,
          'sourceIn': 1.0,
          'duration': 4.0,
          'speed': 2.0,
          'volume': 1.0,
          'envelope': [
            [2.5, 1.0],
            [6.5, 0.0]
          ],
        }, mono: true),
      ];
      final g = mixFilterGraph(clips, 10);
      expect(g, contains('[1:a]'));
      expect(g, contains('[2:a]pan=stereo|c0=c0|c1=c0'));
      expect(g, contains('volume=0.6'));
      expect(g, contains('asetrate=88200'));
      expect(g, contains("volume=volume='"));
      expect(g, contains(':eval=frame'));
      expect(g, contains('adelay=delays=2500:all=1'));
      expect(g, contains('amix=inputs=2'));
      expect(g, contains('normalize=0'));
      expect(g, contains('apad=whole_dur=10'));
      expect(g.trim().endsWith('[aout]'), isTrue);

      final a = muxArgs('v.mp4', clips, 10, 'out.mp4', 'f.txt');
      expect(a, containsAllInOrder(['-i', 'v.mp4', '-t', '8', '-i', 'music.mp3', '-ss', '1', '-t', '8', '-i', 'voice.m4a']));
      expect(a, containsAllInOrder(['-/filter_complex', 'f.txt', '-map', '0:v:0', '-map', '[aout]', '-c:v', 'copy', '-c:a', 'aac']));
      expect(a.last, 'out.mp4');
      expect(muxArgs('v.mp4', const [], 10, 'o.mp4', 'f.txt'), containsAllInOrder(['-c', 'copy']));
    });

    test('silent clips are skipped', () {
      expect(MixClip.fromMap({'path': 'a', 'duration': 3.0, 'volume': 0.0}).audible, isFalse);
      expect(
          MixClip.fromMap({
            'path': 'a',
            'duration': 3.0,
            'volume': 0.0,
            'envelope': [
              [0.0, 0.0],
              [1.0, 1.0]
            ]
          }).audible,
          isTrue);
    });
  });

  group('byte queue', () {
    test('reads exact frames across chunk borders', () async {
      final ctl = StreamController<List<int>>();
      final q = ByteQueue(ctl.stream, highWater: 8);
      final f1 = q.read(6);
      ctl.add([1, 2, 3, 4]);
      ctl.add([5, 6, 7]);
      expect(await f1, [1, 2, 3, 4, 5, 6]);
      ctl.add([8, 9, 10, 11, 12]);
      expect(await q.read(6), [7, 8, 9, 10, 11, 12]);
      final f3 = q.read(4);
      ctl.add([13]);
      await ctl.close();
      expect(await f3, isNull);
    });

    test('readAll', () async {
      final q = ByteQueue(Stream.fromIterable([
        [1, 2],
        [3]
      ]));
      expect(await q.readAll(), [1, 2, 3]);
    });
  });

  group('updater', () {
    Map<String, dynamic> rel(String tag, {List<String> assets = const ['MotionAI-Setup.exe'], bool draft = false}) => {
          'tag_name': tag,
          'draft': draft,
          'prerelease': false,
          'body': 'notes $tag',
          'assets': [for (final a in assets) {'name': a, 'browser_download_url': 'https://x/$tag/$a'}],
        };

    test('picks the newest win-N with an installer', () {
      final list = [
        rel('build-90', assets: ['MotionAI.apk']),
        rel('win-7'),
        rel('win-12', assets: ['MotionAI-Setup.exe', 'MotionAI-Windows-portable.zip']),
        rel('win-15', draft: true),
        rel('win-14', assets: ['other.zip']),
        rel('win-9'),
      ];
      final u = Updater.pickWindowsRelease(list, 5)!;
      expect(u.build, 12);
      expect(u.url, 'https://x/win-12/MotionAI-Setup.exe');
      expect(u.olderUrl, 'https://x/win-12/MotionAI-Windows-portable.zip');
      expect(Updater.pickWindowsRelease(list, 12), isNull);
      expect(Updater.pickWindowsRelease([rel('build-99')], 0), isNull);
    });
  });

  group('speech + voice helpers', () {
    test('whisper.cpp JSON words', () {
      const json = '''{"result": {"language": "hi"}, "transcription": [
        {"timestamps": {"from": "00:00:00,000", "to": "00:00:00,400"}, "offsets": {"from": 0, "to": 400}, "text": " नमस्ते"},
        {"offsets": {"from": 400, "to": 700}, "text": " दोस्तों"},
        {"offsets": {"from": 700, "to": 720}, "text": ","},
        {"offsets": {"from": 900, "to": 1500}, "text": " [BLANK_AUDIO]"},
        {"timestamps": {"from": "00:00:01,500", "to": "00:00:02,100"}, "text": " aaj hum"}
      ]}''';
      final w = WhisperCli.parseJson(json);
      expect(w.map((e) => e.$1).toList(), ['नमस्ते', 'दोस्तों,', 'aaj', 'hum']);
      expect(w[0].$2, 0);
      expect(w[1].$3, closeTo(0.72, 1e-9));
      expect(w[2].$2, closeTo(1.5, 1e-9));
      expect(w[3].$3, closeTo(2.1, 1e-9));
      expect(WhisperCli.parseProgress('whisper_print_progress_callback: progress =  45%'), 45);
      expect(WhisperCli.args(model: 'm.bin', wav: 'a.wav', outBase: 'a', language: 'hi'),
          containsAllInOrder(['-m', 'm.bin', '-f', 'a.wav', '-l', 'hi', '-ml', '1', '-sow', '-oj', '-of', 'a']));
    });

    test('wav duration', () {
      final b = BytesBuilder();
      void u32(int v) => b.add((ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List());
      void u16(int v) => b.add((ByteData(2)..setUint16(0, v, Endian.little)).buffer.asUint8List());
      b.add('RIFF'.codeUnits);
      u32(36 + 32000);
      b.add('WAVE'.codeUnits);
      b.add('fmt '.codeUnits);
      u32(16);
      u16(1);
      u16(1);
      u32(16000);
      u32(32000);
      u16(2);
      u16(16);
      b.add('data'.codeUnits);
      u32(32000);
      b.add(Uint8List(32000));
      expect(WinTts.wavDuration(b.toBytes()), closeTo(1.0, 1e-9));
    });
  });

  test('inpaint fills a hole from its surroundings', () {
    const w = 40, h = 40;
    final r = Float32List(w * h), g = Float32List(w * h), b = Float32List(w * h);
    final hole = Uint8List(w * h);
    for (var i = 0; i < w * h; i++) {
      r[i] = 200;
      g[i] = 100;
      b[i] = 50;
    }
    for (var y = 15; y < 25; y++) {
      for (var x = 15; x < 25; x++) {
        hole[y * w + x] = 1;
        r[y * w + x] = 0;
      }
    }
    ImageOps.inpaintPlanes(r, g, b, hole, w, h);
    expect(r[20 * w + 20], closeTo(200, 1));
    expect(g[20 * w + 20], closeTo(100, 1));
  });
}
