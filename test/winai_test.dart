// Tests for the Windows AI layer (lib/platform/windows_ai, Agent E).
// Pure parts run everywhere; the "windows integration" group runs the real
// engines on the Windows CI runner when WINAI_IT=1 (see build-windows.yml).
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:motionai/platform/windows_ai/image_io.dart';
import 'package:motionai/platform/windows_ai/inpaint.dart';
import 'package:motionai/platform/windows_ai/model_store.dart';
import 'package:motionai/platform/windows_ai/segment.dart';
import 'package:motionai/platform/windows_ai/tts.dart';
import 'package:motionai/platform/windows_ai/wav.dart';
import 'package:motionai/platform/windows_ai/whisper.dart';

// A realistic `whisper-cli -ml 1 -sow -ojf` result (Hindi + Hinglish).
const _whisperJson = r'''
{
	"systeminfo": "AVX = 1 | AVX2 = 1 | AVX512 = 0 | FMA = 1 | NEON = 0 | ARM_FMA = 0 | F16C = 1 | FP16_VA = 0 | WASM_SIMD = 0 | SSE3 = 1 | SSSE3 = 1 | VSX = 0 | COREML = 0 | OPENVINO = 0",
	"model": {
		"type": "base",
		"multilingual": true,
		"vocab": 51865,
		"audio": {"ctx": 1500, "state": 512, "head": 8, "layer": 6},
		"text": {"ctx": 448, "state": 512, "head": 8, "layer": 6},
		"mels": 80,
		"ftype": 1
	},
	"params": {"model": "ggml-base.bin", "language": "hi", "translate": false},
	"result": {"language": "hi"},
	"transcription": [
		{
			"timestamps": {"from": "00:00:00,000", "to": "00:00:00,620"},
			"offsets": {"from": 0, "to": 620},
			"text": " नमस्ते",
			"tokens": [
				{"text": "[_BEG_]", "timestamps": {"from": "00:00:00,000", "to": "00:00:00,000"}, "offsets": {"from": 0, "to": 0}, "id": 50364, "p": 0.981, "t_dtw": -1},
				{"text": " नम", "timestamps": {"from": "00:00:00,000", "to": "00:00:00,300"}, "offsets": {"from": 0, "to": 300}, "id": 8667, "p": 0.72, "t_dtw": -1},
				{"text": "स्ते", "timestamps": {"from": "00:00:00,300", "to": "00:00:00,620"}, "offsets": {"from": 300, "to": 620}, "id": 18402, "p": 0.91, "t_dtw": -1}
			]
		},
		{
			"timestamps": {"from": "00:00:00,620", "to": "00:00:01,200"},
			"offsets": {"from": 620, "to": 1200},
			"text": " दोस्तों,",
			"tokens": [
				{"text": " दो", "timestamps": {"from": "00:00:00,620", "to": "00:00:00,900"}, "offsets": {"from": 620, "to": 900}, "id": 3405, "p": 0.88, "t_dtw": -1},
				{"text": "स्तों", "timestamps": {"from": "00:00:00,900", "to": "00:00:01,150"}, "offsets": {"from": 900, "to": 1150}, "id": 14592, "p": 0.83, "t_dtw": -1},
				{"text": ",", "timestamps": {"from": "00:00:01,150", "to": "00:00:01,200"}, "offsets": {"from": 1150, "to": 1200}, "id": 11, "p": 0.6, "t_dtw": -1},
				{"text": "[_TT_60]", "timestamps": {"from": "00:00:01,200", "to": "00:00:01,200"}, "offsets": {"from": 1200, "to": 1200}, "id": 50424, "p": 0.3, "t_dtw": -1}
			]
		},
		{
			"timestamps": {"from": "00:00:01,200", "to": "00:00:01,500"},
			"offsets": {"from": 1200, "to": 1500},
			"text": " [BLANK_AUDIO]",
			"tokens": []
		},
		{
			"timestamps": {"from": "00:00:01,500", "to": "00:00:01,800"},
			"offsets": {"from": 1500, "to": 1800},
			"text": " आज",
			"tokens": [
				{"text": " आज", "timestamps": {"from": "00:00:01,500", "to": "00:00:01,820"}, "offsets": {"from": 1500, "to": 1820}, "id": 7286, "p": 0.95, "t_dtw": -1}
			]
		},
		{
			"timestamps": {"from": "00:00:02,000", "to": "00:00:03,000"},
			"offsets": {"from": 2000, "to": 3000},
			"text": " Hello world",
			"tokens": [
				{"text": " Hello", "timestamps": {"from": "00:00:02,000", "to": "00:00:02,400"}, "offsets": {"from": 2000, "to": 2400}, "id": 2425, "p": 0.97, "t_dtw": -1},
				{"text": " world", "timestamps": {"from": "00:00:02,400", "to": "00:00:03,000"}, "offsets": {"from": 2400, "to": 3000}, "id": 1002, "p": 0.97, "t_dtw": -1}
			]
		},
		{
			"timestamps": {"from": "00:00:03,000", "to": "00:00:03,100"},
			"offsets": {"from": 3000, "to": 3100},
			"text": ".",
			"tokens": [
				{"text": ".", "timestamps": {"from": "00:00:03,000", "to": "00:00:03,100"}, "offsets": {"from": 3000, "to": 3100}, "id": 13, "p": 0.9, "t_dtw": -1}
			]
		},
		{
			"timestamps": {"from": "00:00:03,100", "to": "00:00:04,000"},
			"offsets": {"from": 3100, "to": 4000},
			"text": " kaise hua"
		},
		{
			"timestamps": {"from": "00:00:04,000", "to": "00:00:05,000"},
			"offsets": {"from": 4000, "to": 5000},
			"text": " (music)"
		}
	]
}
''';

img.Image _gradient(int w, int h) {
  final im = img.Image(width: w, height: h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      im.setPixelRgb(x, y, (x * 255) ~/ (w - 1), (y * 255) ~/ (h - 1), 80);
    }
  }
  return im;
}

Rgba _solid(int w, int h, int r, int g, int b) {
  final d = Uint8List(w * h * 4);
  for (var i = 0; i < w * h; i++) {
    d[i * 4] = r;
    d[i * 4 + 1] = g;
    d[i * 4 + 2] = b;
    d[i * 4 + 3] = 255;
  }
  return Rgba(w, h, d);
}

void main() {
  group('whisper', () {
    test('parses word timings from output-json-full', () {
      final w = Whisper.parseJson(_whisperJson);
      expect(w.map((e) => e.$1).toList(), ['नमस्ते', 'दोस्तों,', 'आज', 'Hello', 'world.', 'kaise', 'hua']);
      expect(w[0].$2, 0);
      expect(w[0].$3, closeTo(0.62, 1e-9));
      expect(w[1].$2, closeTo(0.62, 1e-9));
      expect(w[1].$3, closeTo(1.2, 1e-9));
      // Token time past the segment end is clamped into the segment.
      expect(w[2].$2, closeTo(1.5, 1e-9));
      expect(w[2].$3, closeTo(1.8, 1e-9));
      // Two words in one segment are timed by their tokens.
      expect(w[3].$2, closeTo(2.0, 1e-9));
      expect(w[3].$3, closeTo(2.4, 1e-9));
      expect(w[4].$2, closeTo(2.4, 1e-9));
      expect(w[4].$3, closeTo(3.1, 1e-9)); // "." glued on
      // No tokens: segment time shared by word length (5 + 3 letters).
      expect(w[5].$2, closeTo(3.1, 1e-9));
      expect(w[5].$3, closeTo(3.1 + 0.9 * 5 / 8, 1e-9));
      expect(w[6].$3, closeTo(4.0, 1e-9));
      for (var i = 1; i < w.length; i++) {
        expect(w[i].$2, greaterThanOrEqualTo(w[i - 1].$2));
        expect(w[i].$3, greaterThanOrEqualTo(w[i].$2));
      }
    });

    test('plain -oj output, timestamps only and junk input', () {
      final j = jsonEncode({
        'transcription': [
          {
            'timestamps': {'from': '00:01:02,345', 'to': '00:01:03,000'},
            'text': ' ok then',
          },
        ],
      });
      final w = Whisper.parseJson(j);
      expect(w.length, 2);
      expect(w[0].$2, closeTo(62.345, 1e-9));
      expect(w[1].$3, closeTo(63.0, 1e-9));
      expect(Whisper.parseJson('{}'), isEmpty);
      expect(Whisper.parseJson('{"transcription": [{"text": " a\tb", "offsets": {"from": 0, "to": 100}}]}').length, 2);
      // Unescaped control character inside a string (older builds).
      expect(Whisper.parseJson('{"transcription": [{"text": " x\u0001y", "offsets": {"from": 0, "to": 100}}]}'), isNotEmpty);
    });

    test('argument builder and response file', () {
      final a = Whisper.args(model: 'ggml-base.bin', wav: 'job.wav', outBase: 'job', language: 'hi-IN', prompt: 'नमस्ते\nदोस्तों', threads: 6);
      expect(a.sublist(0, 4), ['-m', 'ggml-base.bin', '-f', 'job.wav']);
      expect(a[a.indexOf('-l') + 1], 'hi');
      expect(a[a.indexOf('-t') + 1], '6');
      expect(a[a.indexOf('-ml') + 1], '1');
      expect(a, containsAll(['-sow', '-ojf', '-pp']));
      expect(a[a.indexOf('-of') + 1], 'job');
      expect(a.last, 'नमस्ते दोस्तों');
      expect(a[a.length - 2], '--prompt');
      final b = Whisper.args(model: 'm', wav: 'w', outBase: 'o', prompt: '  ');
      expect(b, isNot(contains('--prompt')));
      expect(b[b.indexOf('-l') + 1], 'auto');
      expect(Whisper.language('EN_us'), 'en');
      expect(Whisper.language('auto'), 'auto');
      final rsp = Whisper.responseFile(a);
      expect(rsp.split('\n').where((l) => l.isNotEmpty).toList(), a);
      expect(rsp, isNot(contains('\r')));
      expect(utf8.decode(utf8.encode(rsp)), rsp);
    });

    test('progress lines and models', () {
      expect(Whisper.progress('whisper_print_progress_callback: progress =  45%'), 45);
      expect(Whisper.progress('whisper_full: progress = 100%'), 100);
      expect(Whisper.progress('main: processing'), isNull);
      expect(Whisper.model(null).fileName, 'ggml-base.bin');
      expect(Whisper.model('tiny').fileName, 'ggml-tiny.bin');
      expect(Whisper.model('large').fileName, 'ggml-base.bin');
      for (final m in Whisper.models.values) {
        expect(m.urls.single, startsWith('https://huggingface.co/ggerganov/whisper.cpp/resolve/main/'));
        expect(m.hash.length, 40);
      }
    });
  });

  group('wav', () {
    test('reads PCM header and duration', () {
      final wav = WavInfo.pcm16(Int16List(16000 * 3), sampleRate: 16000);
      final info = WavInfo.parse(wav)!;
      expect(info.sampleRate, 16000);
      expect(info.channels, 1);
      expect(info.bitsPerSample, 16);
      expect(info.dataOffset, 44);
      expect(info.seconds, closeTo(3.0, 1e-9));
    });

    test('skips extra chunks and handles streaming sizes', () {
      final base = WavInfo.pcm16(Int16List(11025), sampleRate: 22050);
      final list = [...ascii.encode('LIST'), 5, 0, 0, 0, 1, 2, 3, 4, 5, 0]; // odd size + pad byte
      final b = Uint8List.fromList([...base.sublist(0, 36), ...list, ...base.sublist(36)]);
      expect(WavInfo.duration(b), closeTo(0.5, 1e-9));
      final s = Uint8List.fromList(base);
      ByteData.sublistView(s).setUint32(40, 0xFFFFFFFF, Endian.little);
      expect(WavInfo.duration(s), closeTo(0.5, 1e-9));
      expect(WavInfo.parse(Uint8List.fromList(ascii.encode('not a wave file'))), isNull);
      expect(WavInfo.duration(Uint8List(0)), 0);
    });
  });

  group('inpaint', () {
    test('fills a hole in a flat image with the surrounding colour', () {
      final src = _solid(64, 48, 200, 120, 40);
      final hole = Uint8List(64 * 48);
      for (var y = 15; y < 33; y++) {
        for (var x = 20; x < 44; x++) {
          final i = y * 64 + x;
          hole[i] = 1;
          src.data[i * 4] = 0; // garbage under the hole
          src.data[i * 4 + 1] = 255;
          src.data[i * 4 + 2] = 255;
        }
      }
      final out = Inpaint.fill(src, hole);
      for (var i = 0; i < 64 * 48; i++) {
        expect((out.data[i * 4] - 200).abs(), lessThanOrEqualTo(1));
        expect((out.data[i * 4 + 1] - 120).abs(), lessThanOrEqualTo(1));
        expect((out.data[i * 4 + 2] - 40).abs(), lessThanOrEqualTo(1));
        expect(out.data[i * 4 + 3], 255);
      }
    });

    test('blends a gradient across the hole and keeps known pixels', () {
      final src = ImageIo.toRgba(_gradient(80, 60));
      final orig = Uint8List.fromList(src.data);
      final hole = Uint8List(80 * 60);
      for (var y = 20; y < 40; y++) {
        for (var x = 30; x < 50; x++) {
          hole[y * 80 + x] = 1;
          src.data[(y * 80 + x) * 4] = 255;
        }
      }
      final out = Inpaint.fill(src, hole);
      for (var i = 0; i < hole.length; i++) {
        if (hole[i] == 0) {
          expect(out.data.sublist(i * 4, i * 4 + 3), orig.sublist(i * 4, i * 4 + 3));
        } else {
          // Diffusion stays close to the smooth ramp underneath.
          expect((out.data[i * 4] - orig[i * 4]).abs(), lessThan(40));
          expect((out.data[i * 4 + 1] - orig[i * 4 + 1]).abs(), lessThan(40));
        }
      }
      // Left edge of the hole is darker in red than the right edge.
      expect(out.data[(30 * 80 + 31) * 4], lessThan(out.data[(30 * 80 + 48) * 4]));
    });

    test('mask threshold and file round trip (mask resized to image)', () {
      final mask = _solid(2, 1, 0, 0, 0);
      mask.data[4 + 1] = 255;
      expect(Inpaint.holeFromMask(mask), [0, 1]);

      final dir = Directory.systemTemp.createTempSync('winai_inpaint');
      addTearDown(() => dir.deleteSync(recursive: true));
      final image = img.Image(width: 40, height: 30);
      img.fill(image, color: img.ColorRgb8(10, 200, 30));
      img.fillRect(image, x1: 15, y1: 10, x2: 25, y2: 20, color: img.ColorRgb8(255, 0, 255));
      final m = img.Image(width: 20, height: 15); // half size, scaled up
      img.fill(m, color: img.ColorRgb8(0, 0, 0));
      img.fillRect(m, x1: 6, y1: 4, x2: 14, y2: 11, color: img.ColorRgb8(255, 255, 255));
      File('${dir.path}/a.png').writeAsBytesSync(img.encodePng(image));
      File('${dir.path}/m.png').writeAsBytesSync(img.encodePng(m));
      final (w, h) = Inpaint.file('${dir.path}/a.png', '${dir.path}/m.png', '${dir.path}/out.png');
      expect((w, h), (40, 30));
      final out = img.decodePng(File('${dir.path}/out.png').readAsBytesSync())!;
      final c = out.getPixel(20, 15);
      expect(c.g, greaterThan(150));
      expect(c.r, lessThan(60));
    });
  });

  group('normalise', () {
    test('writes JPEG/PNG and limits the size', () {
      final dir = Directory.systemTemp.createTempSync('winai_norm');
      addTearDown(() => dir.deleteSync(recursive: true));
      final png = '${dir.path}/in.png';
      File(png).writeAsBytesSync(img.encodePng(_gradient(50, 30)));
      expect(ImageIo.normalizeFile(png, '${dir.path}/o.jpg'), (50, 30));
      expect(img.decodeJpg(File('${dir.path}/o.jpg').readAsBytesSync())!.width, 50);
      expect(ImageIo.normalizeFile(png, '${dir.path}/o.png'), (50, 30));
      expect(img.decodePng(File('${dir.path}/o.png').readAsBytesSync())!.height, 30);

      final (_, w, h) = ImageIo.normalizeBytes(img.encodeBmp(img.Image(width: 5000, height: 20)), 'x.jpg');
      expect(w, 4096);
      expect(h, 16);
      expect(() => ImageIo.normalizeBytes(Uint8List.fromList(ascii.encode('hello world, this is not an image')), 'x.jpg'), throwsFormatException);
    });

    test('applies EXIF orientation', () {
      final plain = img.encodeJpg(_gradient(60, 20));
      // APP1 "Exif" segment with Orientation = 6 (rotate 90° clockwise).
      const app1 = [
        0xFF, 0xE1, 0x00, 0x22, // marker, length 34
        0x45, 0x78, 0x69, 0x66, 0x00, 0x00, // "Exif\0\0"
        0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00, // TIFF, little-endian, IFD at 8
        0x01, 0x00, // one entry
        0x12, 0x01, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00, 0x06, 0x00, 0x00, 0x00, // 0x0112 SHORT 1 = 6
        0x00, 0x00, 0x00, 0x00, // no next IFD
      ];
      final jpg = Uint8List.fromList([...plain.sublist(0, 2), ...app1, ...plain.sublist(2)]);
      expect(img.decodeJpg(jpg)!.exif.imageIfd.orientation, 6);
      final (bytes, w, h) = ImageIo.normalizeBytes(jpg, 'out.jpg');
      expect((w, h), (20, 60));
      expect(img.decodeJpg(bytes)!.width, 20);
    });

    test('transparent pixels are flattened on white for JPEG', () {
      final p = Rgba(1, 1, Uint8List.fromList([0, 0, 0, 0]));
      expect(ImageIo.flatten(p).data, [255, 255, 255, 255]);
    });
  });

  group('segmentation maths', () {
    test('input tensor is NCHW, max-scaled, ImageNet-normalised', () {
      const s = 4;
      // 8×8 image: left half red, right half blue → 4×4 tensor (area average).
      final src = _solid(8, 8, 0, 0, 255);
      for (var y = 0; y < 8; y++) {
        for (var x = 0; x < 4; x++) {
          src.data[(y * 8 + x) * 4] = 255;
          src.data[(y * 8 + x) * 4 + 2] = 0;
        }
      }
      final t = Segment.inputTensor(src, s: s);
      expect(t.length, 3 * s * s);
      double at(int c, int y, int x) => t[c * s * s + y * s + x];
      expect(at(0, 1, 0), closeTo((1 - 0.485) / 0.229, 1e-5)); // red, left
      expect(at(2, 1, 0), closeTo((0 - 0.406) / 0.225, 1e-5));
      expect(at(0, 2, 3), closeTo((0 - 0.485) / 0.229, 1e-5)); // blue, right
      expect(at(2, 2, 3), closeTo((1 - 0.406) / 0.225, 1e-5));
      expect(at(1, 3, 3), closeTo((0 - 0.456) / 0.224, 1e-5));
      // Dim image: scaled by its own maximum (as rembg does).
      final dim = Segment.inputTensor(_solid(4, 4, 100, 50, 0), s: 2);
      expect(dim[0], closeTo((1 - 0.485) / 0.229, 1e-5));
      expect(dim[4], closeTo((0.5 - 0.456) / 0.224, 1e-5));
    });

    test('area resize and bilinear upsample', () {
      final src = _solid(4, 2, 0, 0, 0);
      src.data[0] = 200; // (0,0) red
      final p = Segment.resizePlanar(src, 2, 1);
      expect(p[0], closeTo(50, 1e-6)); // mean of a 2×2 block
      expect(p[1], 0);
      final up = Segment.upsample(Float32List.fromList([0, 1]), 2, 1, 4, 1);
      expect(up, [0, 0.25, 0.75, 1]);
      final grow = Segment.resizePlanar(_solid(2, 2, 10, 20, 30), 3, 3);
      expect(grow[4], closeTo(10, 1e-6));
    });

    test('prediction → alpha mask', () {
      final pred = Segment.normalizePrediction(Float32List.fromList([2, 4, 6, 10, 99]), 2);
      expect(pred, [0, 0.25, 0.5, 1]); // first channel only, min-max
      expect(Segment.normalizePrediction(Float32List(4), 2), [0, 0, 0, 0]);
      expect(Segment.alphaOf(0), 0);
      expect(Segment.alphaOf(0.12), 0);
      expect(Segment.alphaOf(0.88), 255);
      expect(Segment.alphaOf(0.5), inInclusiveRange(120, 135));

      // Square subject in the middle of a 16×16 map; photo 64×48.
      const s = 16;
      final m = Float32List(s * s);
      for (var y = 5; y < 11; y++) {
        for (var x = 5; x < 11; x++) {
          m[y * s + x] = 1;
        }
      }
      final photo = _solid(64, 48, 128, 128, 128);
      for (final refine in [false, true]) {
        final a = Segment.alphaMask(m, s, photo, refine: refine);
        expect(a.length, 64 * 48);
        expect(a[24 * 64 + 32], 255, reason: 'centre, refine=$refine');
        expect(a[0], 0, reason: 'corner, refine=$refine');
        expect(a[47 * 64 + 63], 0);
        final cov = Segment.coverage(a);
        expect(cov, greaterThan(0.08));
        expect(cov, lessThan(0.25));
      }
    });

    test('guided filter follows edges of the guide', () {
      // Guide: sharp vertical edge at x=10; p: blurry ramp across it.
      const w = 20, h = 8;
      final g = Float32List(w * h), p = Float32List(w * h);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          g[y * w + x] = x < 10 ? 0 : 1;
          p[y * w + x] = (x / (w - 1));
        }
      }
      final (a, b) = Segment.guidedCoefficients(g, p, w, h, 3, 1e-4);
      double q(int x) => a[4 * w + x] * g[4 * w + x] + b[4 * w + x];
      expect(q(10) - q(9), greaterThan(p[4 * w + 10] - p[4 * w + 9])); // sharper step
      final box = Segment.boxMean(Float32List.fromList([1, 2, 3, 4]), 4, 1, 1);
      expect(box, [1.5, 2, 3, 3.5]);
    });

    test('foreground alpha and background plate', () {
      final src = ImageIo.toRgba(_gradient(96, 72));
      final alpha = Uint8List(96 * 72);
      for (var y = 20; y < 50; y++) {
        for (var x = 30; x < 60; x++) {
          alpha[y * 96 + x] = 255;
        }
      }
      final fg = Segment.foreground(src, alpha);
      expect(fg.data[(30 * 96 + 40) * 4 + 3], 255);
      expect(fg.data[3], 0);
      expect(fg.data.sublist((30 * 96 + 40) * 4, (30 * 96 + 40) * 4 + 3), src.data.sublist((30 * 96 + 40) * 4, (30 * 96 + 40) * 4 + 3));
      final bg = Segment.backgroundPlate(src, alpha);
      // Far from the subject: untouched.
      expect(bg.data.sublist(0, 4), src.data.sublist(0, 4));
      expect(bg.data.sublist((70 * 96 + 95) * 4, (70 * 96 + 95) * 4 + 3), src.data.sublist((70 * 96 + 95) * 4, (70 * 96 + 95) * 4 + 3));
      // Inside: the blurred photo (a gradient stays close to itself).
      final i = (35 * 96 + 45) * 4;
      expect(bg.data[i + 3], 255);
      expect((bg.data[i] - src.data[i]).abs(), lessThan(30));
      expect(Segment.coverage(alpha), closeTo(900 / (96 * 72), 1e-9));
      expect(Segment.model.bytes, 4574861);
      expect(Segment.model.hash.length, 64);
    });
  });

  group('windows voices', () {
    const voices = [
      WinVoice(engine: 'sapi', name: 'Microsoft David Desktop', lang: 'en-US', gender: 'Male'),
      WinVoice(engine: 'sapi', name: 'Microsoft Zira Desktop', lang: 'en-US', gender: 'Female'),
      WinVoice(engine: 'winrt', name: 'Microsoft Heera', id: 'x-heera', lang: 'en-IN', gender: 'Female'),
      WinVoice(engine: 'winrt', name: 'Microsoft Hemant', id: 'x-hemant', lang: 'hi-IN', gender: 'Male'),
      WinVoice(engine: 'winrt', name: 'Microsoft Kalpana', id: 'x-kalpana', lang: 'hi-IN', gender: 'Female'),
    ];

    test('picks the matching language and Hindi voices', () {
      final hi = WinTtsEngine.pickVoice(voices, 'hi-IN', ['नमस्ते'])!;
      expect(hi.voice.lang, 'hi-IN');
      expect(['Microsoft Kalpana', 'Microsoft Hemant'], contains(hi.voice.name));
      expect(hi.note, isNull);
      final en = WinTtsEngine.pickVoice(voices, 'en-US', ['hello'])!;
      expect(en.voice.engine, 'sapi');
      final gb = WinTtsEngine.pickVoice(voices, 'en-GB', ['hello'])!;
      expect(gb.voice.lang, startsWith('en-'));
      expect(gb.note, contains('en-GB'));
      expect(WinTtsEngine.pickVoice(voices, 'en_IN', ['hi'])!.voice.name, 'Microsoft Heera');
    });

    test('falls back to an Indian-English voice only for Roman script', () {
      final noHindi = voices.where((v) => v.lang != 'hi-IN').toList();
      expect(WinTtsEngine.pickVoice(noHindi, 'hi-IN', ['नमस्ते दोस्तों']), isNull);
      final roman = WinTtsEngine.pickVoice(noHindi, 'hi-IN', ['aaj hum baat karenge', 'kaise hua?'])!;
      expect(roman.voice.name, 'Microsoft Heera');
      expect(roman.note, contains('Kalpana'));
      expect(WinTtsEngine.noVoiceMessage('hi-IN'), contains('Hindi'));
      expect(WinTtsEngine.pickVoice(const [], 'en-US', ['x']), isNull);
    });

    test('rate, pitch SSML, voice list parsing and job', () {
      expect(WinTtsEngine.sapiRate(1), 0);
      expect(WinTtsEngine.sapiRate(1.05), 0);
      expect(WinTtsEngine.sapiRate(3), 10);
      expect(WinTtsEngine.sapiRate(1 / 3), -10);
      expect(WinTtsEngine.sapiRate(10), 10);
      expect(WinTtsEngine.sapiRate(0), 0);
      expect(WinTtsEngine.sapiRate(1.5), 4);
      expect(WinTtsEngine.ssml('a', 'en-US', 1.0), isNull);
      final x = WinTtsEngine.ssml('Tom & "Jerry" <3', 'hi-IN', 1.2)!;
      expect(x, contains('pitch="+20%"'));
      expect(x, contains('Tom &amp; &quot;Jerry&quot; &lt;3'));
      expect(x, contains('xml:lang="hi-IN"'));
      expect(WinTtsEngine.ssml('a', 'en-US', 0.9), contains('pitch="-10%"'));

      final one = WinTtsEngine.parseVoices({'ok': true, 'voices': {'engine': 'sapi', 'name': 'A', 'lang': 'en-US'}});
      expect(one.single.name, 'A');
      final many = WinTtsEngine.parseVoices(jsonDecode(jsonEncode({'voices': [for (final v in voices) v.toJson()]})));
      expect(many.length, voices.length);
      expect(many[3].id, 'x-hemant');

      final job = WinTtsEngine.speakJob(VoiceChoice(voices[4]), ['एक', 'दो'], ['a.wav', 'b.wav'], 'r.json', rate: 1.05, pitch: 1.1);
      expect(job['engine'], 'winrt');
      expect(job['voiceId'], 'x-kalpana');
      expect((job['ssml'] as List).length, 2);
      expect(job['sapiRate'], 0);
      expect(WinTtsEngine.psScript, contains('SetOutputToWaveFile'));
      expect(WinTtsEngine.latinOnly(['Hello, kaise ho? 123']), isTrue);
      expect(WinTtsEngine.latinOnly(['Hello नमस्ते']), isFalse);
    });
  });

  group('model store', () {
    test('downloads once, checks the hash and reports progress', () async {
      final data = Uint8List.fromList(List.generate(300000, (i) => (i * 31) & 0xFF));
      var hits = 0;
      final oldClient = ModelStore.httpClient;
      ModelStore.httpClient = () => MockClient.streaming((req, body) async {
            hits++;
            if (req.url.path == '/bad') return http.StreamedResponse(const Stream.empty(), 404);
            final chunks = [for (var i = 0; i < data.length; i += 65536) data.sublist(i, math.min(data.length, i + 65536))];
            return http.StreamedResponse(Stream.fromIterable(chunks), 200, contentLength: data.length);
          });
      final dir = Directory.systemTemp.createTempSync('winai_models');
      final old = ModelStore.modelsDir;
      ModelStore.modelsDir = () async => dir;
      addTearDown(() {
        ModelStore.modelsDir = old;
        ModelStore.httpClient = oldClient;
        dir.deleteSync(recursive: true);
      });
      const base = 'https://models.example';
      final spec = ModelSpec(
        fileName: 'm.bin',
        urls: ['$base/bad', '$base/m.bin'],
        bytes: data.length,
        hashKind: HashKind.sha256,
        hash: sha256.convert(data).toString(),
        label: 'test model',
      );
      final progress = <double>[];
      final path = await ModelStore.ensure(spec, onProgress: progress.add);
      expect(File(path).readAsBytesSync(), data);
      expect(progress.last, 1);
      expect(hits, 2);
      await ModelStore.ensure(spec);
      expect(hits, 2, reason: 'second call uses the cached file');

      final wrong = ModelSpec(
          fileName: 'w.bin', urls: ['$base/w.bin'], bytes: data.length, hashKind: HashKind.sha1, hash: '0' * 40, label: 'broken model');
      await expectLater(ModelStore.ensure(wrong), throwsA(isA<HttpException>()));
      expect(File('${dir.path}/w.bin').existsSync(), isFalse);
      expect(await ModelStore.hashFile(path, HashKind.sha1), sha1.convert(data).toString());
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  // Real engines; the Windows CI build sets these after bundling binaries.
  final env = Platform.environment;
  final it = Platform.isWindows && env['WINAI_IT'] == '1';
  group('windows integration', () {
    test('ONNX Runtime + u2netp cut-out', () {
      final dir = Directory.systemTemp.createTempSync('winai_it_cut');
      final photo = img.Image(width: 400, height: 300);
      img.fill(photo, color: img.ColorRgb8(235, 235, 235));
      img.fillCircle(photo, x: 200, y: 150, radius: 80, color: img.ColorRgb8(200, 30, 30));
      File('${dir.path}/p.jpg').writeAsBytesSync(img.encodeJpg(photo));
      final (w, h) = Segment.cutoutFile(env['WINAI_ORT']!, env['WINAI_U2NETP']!, '${dir.path}/p.jpg', '${dir.path}/fg.png', '${dir.path}/bg.jpg', 2);
      expect((w, h), (400, 300));
      final fg = img.decodePng(File('${dir.path}/fg.png').readAsBytesSync())!;
      // ignore: avoid_print
      print('cut-out alpha centre=${fg.getPixel(200, 150).a} corner=${fg.getPixel(5, 5).a}');
      expect(fg.getPixel(200, 150).a, greaterThan(200));
      expect(fg.getPixel(5, 5).a, lessThan(50));
      expect(File('${dir.path}/bg.jpg').existsSync(), isTrue);
    });

    test('Windows voice → whisper.cpp words', () async {
      final dir = Directory.systemTemp.createTempSync('winai_it_tts');
      final vs = await WinTtsEngine.voices();
      // ignore: avoid_print
      print('voices: $vs');
      final clips = await WinTtsEngine.speak(['Hello world, this is a test of the speech engine.'], dir.path, lang: 'en-US', rate: 0.9);
      expect(clips.single.$2, greaterThan(1.0));
      final words = await Whisper.transcribe(
        cli: env['WINAI_WHISPER']!,
        modelPath: env['WINAI_WHISPER_MODEL']!,
        wavPath: clips.single.$1,
        language: 'en',
        prompt: 'नमस्ते. Hello.',
      );
      // ignore: avoid_print
      print('words: $words');
      expect(words.map((w) => w.$1.toLowerCase()).join(' '), contains('test'));
      expect(words.first.$2, lessThan(words.last.$3));
    }, timeout: const Timeout(Duration(minutes: 5)));
  }, skip: it ? false : 'needs WINAI_IT=1 on Windows');

}
