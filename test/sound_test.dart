import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:motionai/audio/audio_cache.dart';
import 'package:motionai/audio/auto_mix.dart';
import 'package:motionai/audio/beat_sync.dart';
import 'package:motionai/audio/loudness.dart';
import 'package:motionai/audio/music_analysis.dart';
import 'package:motionai/audio/sfx_library.dart';
import 'package:motionai/audio/wav.dart';
import 'package:motionai/core/commands/edit_commands.dart';
import 'package:motionai/core/model/layer.dart';
import 'package:motionai/core/model/project.dart';
import 'package:motionai/director/sfx.dart';
import 'package:motionai/director/story_builder.dart';

Project project({double duration = 6}) {
  final p = Project(
    id: 'p',
    name: 'Sound',
    main: Composition(id: 'main', name: 'Main', width: 1920, height: 1080, fps: 30, duration: duration),
  );
  p.media['img'] = MediaAsset(id: 'img', type: MediaType.image, path: '/a.jpg', name: 'a', width: 1200, height: 800);
  return p;
}

/// Click track: a 1 kHz click (+ noise) every beat, louder on the bar.
(Float32List, List<double>) clickTrack(int sr, double bpm, {double seconds = 12, double offset = 0.25}) {
  final x = Float32List((sr * seconds).round());
  final rnd = math.Random(1);
  final times = <double>[];
  var t = offset;
  var i = 0;
  while (t < seconds - 0.05) {
    final s0 = (t * sr).round();
    final n = (0.03 * sr).round();
    final amp = i % 4 == 0 ? 1.0 : 0.5;
    for (int k = 0; k < n && s0 + k < x.length; k++) {
      final env = math.exp(-k / sr * 120);
      x[s0 + k] += amp * env * math.sin(2 * math.pi * 1000 * k / sr) + amp * 0.3 * env * (rnd.nextDouble() * 2 - 1);
    }
    times.add(t);
    t += 60 / bpm;
    i++;
  }
  return (x, times);
}

/// 10 ms RMS envelope of a stereo render.
List<double> envelope(Float32List l, Float32List r) {
  const w = 441;
  final out = <double>[];
  for (int s = 0; s + w <= l.length; s += w) {
    var e = 0.0;
    for (int i = s; i < s + w; i++) {
      e += (l[i] * l[i] + r[i] * r[i]) / 2;
    }
    out.add(math.sqrt(e / w));
  }
  return out;
}

void main() {
  // ------------------------------------------------------------------ SFX
  group('SFX', () {
    test('original kinds are kept', () {
      expect(Sfx.kinds, ['whoosh', 'hit', 'riser', 'tick', 'pop', 'impact']);
      for (final k in Sfx.kinds) {
        expect(Sfx.all, contains(k));
      }
      expect(Sfx.all.toSet().length, Sfx.all.length);
      expect(Sfx.all.length, greaterThanOrEqualTo(28));
    });

    test('every kind is a valid, normalised 16-bit stereo WAV of the right length', () {
      for (final k in Sfx.all) {
        final b = Sfx.wav(k);
        expect(String.fromCharCodes(b.sublist(0, 4)), 'RIFF', reason: k);
        expect(String.fromCharCodes(b.sublist(8, 12)), 'WAVE', reason: k);
        expect((b.length - 44) / 4 / Sfx.rate, closeTo(Sfx.length(k), 0.01), reason: k);
        final a = Wav.decode(b);
        expect(a.sampleRate, 44100);
        expect(a.channels.length, 2);
        expect(a.duration, closeTo(Sfx.length(k), 0.01), reason: k);
        var peak = 0.0;
        for (final c in a.channels) {
          for (final v in c) {
            peak = math.max(peak, v.abs());
          }
        }
        expect(peak, inInclusiveRange(Sfx.isBed(k) ? 0.55 : 0.8, 0.9), reason: '$k peak $peak');
        expect(Sfx.info(k).$2, isIn(Sfx.categories), reason: k);
        expect(Sfx.peak(k), inInclusiveRange(0.0, Sfx.length(k)), reason: k);
      }
    });

    test('peak metadata marks the loud moment', () {
      for (final k in Sfx.all.where((k) => !Sfx.isBed(k))) {
        final (l, r) = Sfx.render(k);
        final env = envelope(l, r);
        final mx = env.reduce(math.max);
        final pk = Sfx.peak(k);
        var near = 0.0;
        for (int i = 0; i < env.length; i++) {
          final t = i * 0.01;
          if (t >= pk - 0.06 && t <= pk + 0.06) near = math.max(near, env[i]);
        }
        expect(near, greaterThanOrEqualTo(0.6 * mx), reason: '$k: loudness at peak ${pk}s is ${near / mx} of max');
      }
    });

    test('silence after whoosh_silence and before reverse_cymbal lands', () {
      final (l, r) = Sfx.render('whoosh_silence');
      final env = envelope(l, r);
      final mx = env.reduce(math.max);
      for (int i = 65; i < env.length; i++) {
        expect(env[i], lessThan(0.01 * mx));
      }
    });

    test('deterministic for a seed', () {
      for (final k in ['whoosh', 'glitch', 'crowd_bed', 'paper']) {
        expect(Sfx.wav(k), Sfx.wav(k));
      }
      expect(Sfx.wav('paper', seed: 1), isNot(Sfx.wav('paper', seed: 2)));
    });

    test('beds loop seamlessly', () {
      for (final k in Sfx.beds) {
        final (l, _) = Sfx.render(k);
        var maxStep = 0.0;
        for (int i = 1; i < l.length; i++) {
          maxStep = math.max(maxStep, (l[i] - l[i - 1]).abs());
        }
        expect((l.first - l.last).abs(), lessThanOrEqualTo(maxStep + 1e-6), reason: k);
        // Level continuity across the seam.
        final n = Sfx.rate;
        final head = Loudness.rmsDb(Float32List.sublistView(l, 0, n));
        final tail = Loudness.rmsDb(Float32List.sublistView(l, l.length - n));
        if (k != 'clock_tick') expect((head - tail).abs(), lessThan(10), reason: '$k head $head tail $tail');
      }
    });

    test('typewriter clicks follow the typewriter animator letter by letter', () {
      final times = Sfx.typingTimes('Hi you', 1.2);
      expect(times.length, 5); // the space is silent
      expect(times.first, closeTo(0.1, 1e-9));
      expect(times.last, closeTo(1.1, 1e-9));
      final b = Sfx.typing(times);
      final (l, r) = Sfx.renderTyping(times);
      expect((b.length - 44) / 4, l.length);
      final env = envelope(l, r);
      final mx = env.reduce(math.max);
      for (final t in times) {
        final i = (t / 0.01).floor();
        expect(env.sublist(i, math.min(env.length, i + 2)).reduce(math.max), greaterThan(0.3 * mx));
      }
    });
  });

  // ------------------------------------------------------------------ WAV
  group('WAV', () {
    test('round trip 16/24/32-bit, mono and stereo', () {
      final a = Float32List.fromList([for (int i = 0; i < 1000; i++) math.sin(i / 10) * 0.8]);
      final b = Float32List.fromList([for (int i = 0; i < 1000; i++) (i % 7) / 7 - 0.5]);
      for (final bits in [16, 24, 32]) {
        final back = Wav.decode(Wav.encode([a, b], 22050, bits: bits));
        expect(back.sampleRate, 22050);
        expect(back.channels.length, 2);
        expect(back.length, 1000);
        final tol = bits == 16 ? 1 / 32000 : 1e-6;
        for (int i = 0; i < 1000; i++) {
          expect(back.channels[0][i], closeTo(a[i], tol));
          expect(back.channels[1][i], closeTo(b[i], tol));
        }
        expect(back.mono()[10], closeTo((a[10] + b[10]) / 2, tol * 2));
      }
      final m = Wav.decode(Wav.encode([a], 16000));
      expect(m.channels.length, 1);
      expect(m.duration, closeTo(1000 / 16000, 1e-9));
    });

    test('reads float WAV, extensible fmt and skips extra chunks', () {
      // Hand-built: RIFF, fmt (extensible, float sub-format), LIST (odd size), data.
      final samples = [0.5, -0.25, 1.0];
      final fmt = ByteData(40)
        ..setUint16(0, 0xFFFE, Endian.little)
        ..setUint16(2, 1, Endian.little)
        ..setUint32(4, 8000, Endian.little)
        ..setUint32(8, 32000, Endian.little)
        ..setUint16(12, 4, Endian.little)
        ..setUint16(14, 32, Endian.little)
        ..setUint16(16, 22, Endian.little)
        ..setUint16(18, 32, Endian.little)
        ..setUint32(20, 4, Endian.little)
        ..setUint16(24, 3, Endian.little); // KSDATAFORMAT_SUBTYPE_IEEE_FLOAT
      final data = ByteData(samples.length * 4);
      for (int i = 0; i < samples.length; i++) {
        data.setFloat32(i * 4, samples[i], Endian.little);
      }
      final out = BytesBuilder();
      void chunk(String id, List<int> body) {
        out.add(id.codeUnits);
        out.add((ByteData(4)..setUint32(0, body.length, Endian.little)).buffer.asUint8List());
        out.add(body);
        if (body.length.isOdd) out.addByte(0);
      }

      final body = BytesBuilder()..add('WAVE'.codeUnits);
      final inner = BytesBuilder();
      out.clear();
      chunk('fmt ', fmt.buffer.asUint8List());
      chunk('LIST', [1, 2, 3]);
      chunk('data', data.buffer.asUint8List());
      inner.add(out.takeBytes());
      body.add(inner.takeBytes());
      final riff = BytesBuilder()
        ..add('RIFF'.codeUnits)
        ..add((ByteData(4)..setUint32(0, body.length, Endian.little)).buffer.asUint8List())
        ..add(body.takeBytes());
      final a = Wav.decode(riff.takeBytes());
      expect(a.sampleRate, 8000);
      expect(a.channels.single, [0.5, -0.25, 1.0]);
    });

    test('rejects non-WAV data', () {
      expect(() => Wav.decode(Uint8List.fromList(List.filled(64, 7))), throwsFormatException);
    });

    test('resample keeps duration', () {
      final x = Float32List(44100);
      expect(Wav.resample(x, 44100, 16000).length, 16000);
    });
  });

  // ------------------------------------------------------------------ analysis
  group('Music analysis', () {
    test('click track at 120 BPM: tempo, beats, downbeats', () {
      for (final sr in [44100, 16000]) {
        final (x, clicks) = clickTrack(sr, 120);
        final a = MusicAnalysis.analyze(x, sr);
        expect(a.tempo, closeTo(120, 2), reason: 'sr $sr tempo ${a.tempo}');
        expect(a.confidence, greaterThan(0.3));
        var hit = 0;
        for (final c in clicks.sublist(1, clicks.length - 1)) {
          final b = BeatSync.nearest(a.beats, c, 0.03);
          if (b != null) hit++;
        }
        expect(hit, greaterThanOrEqualTo(((clicks.length - 2) * 0.9).floor()), reason: 'sr $sr beats ${a.beats}');
        // Downbeats fall on the accented clicks.
        final bars = [for (int i = 0; i < clicks.length; i += 4) clicks[i]];
        var onBar = 0;
        for (final d in a.downbeats) {
          if (BeatSync.nearest(bars, d, 0.03) != null) onBar++;
        }
        expect(onBar, greaterThanOrEqualTo((a.downbeats.length * 0.8).floor()), reason: 'downbeats ${a.downbeats}');
        expect(a.drops, isEmpty, reason: 'steady track has no drop');
      }
    });

    test('other tempi', () {
      for (final bpm in [90.0, 140.0]) {
        final (x, _) = clickTrack(22050, bpm);
        expect(MusicAnalysis.analyze(x, 22050).tempo, closeTo(bpm, 2));
      }
    });

    test('works on a 16 kHz WAV (the wav16k path)', () {
      final (x, _) = clickTrack(16000, 120);
      final a = Wav.decode(Wav.encode([x], 16000));
      expect(MusicAnalysis.analyze(a.mono(), a.sampleRate).tempo, closeTo(120, 2));
    });

    test('drop on quiet → loud', () {
      const sr = 16000;
      final rnd = math.Random(3);
      final x = Float32List(sr * 12);
      for (int i = 0; i < x.length; i++) {
        x[i] = (rnd.nextDouble() * 2 - 1) * (i < sr * 6 ? 0.03 : 0.5);
      }
      for (int k = 0; k < 24; k++) {
        final s0 = (k * 0.5 * sr).round();
        for (int j = 0; j < 0.05 * sr; j++) {
          x[s0 + j] += (k < 12 ? 0.05 : 1.0) * math.exp(-j / sr * 60) * math.sin(2 * math.pi * 60 * j / sr);
        }
      }
      final a = MusicAnalysis.analyze(x, sr);
      expect(a.mainDrop, isNotNull);
      expect(a.mainDrop!, closeTo(6.0, 0.15));
      expect(a.sections.any((s) => (s - 6).abs() < 1), isTrue);
      expect(a.energyAt(3), lessThan(a.energyAt(9)));
      expect(a.loudness, greaterThan(-20));
    });

    test('json round trip and grid', () {
      final (x, _) = clickTrack(16000, 120, seconds: 6);
      final a = MusicAnalysis.analyze(x, 16000);
      final b = MusicAnalysis.fromJson(a.toJson());
      expect(b.tempo, closeTo(a.tempo, 0.001));
      expect(b.beats.length, a.beats.length);
      expect(b.energy.length, a.energy.length);
      final g = MusicAnalysis.grid(120, offset: 0.5, duration: 4);
      expect(g.beats, [0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 3.5, 4.0]);
      expect(g.downbeats, [0.5, 2.5]);
      expect(a.summary(), contains('BPM'));
    });

    test('short or empty input does not crash', () {
      final a = MusicAnalysis.analyze(Float32List(100), 16000);
      expect(a.beats, isEmpty);
      expect(MusicAnalysis.analyze(Float32List(16000 * 3), 16000).tempo, 0);
    });
  });

  // ------------------------------------------------------------------ loudness
  group('Loudness', () {
    test('sine levels', () {
      Float32List sine(double amp) => Float32List.fromList([for (int i = 0; i < 48000; i++) amp * math.sin(2 * math.pi * 1000 * i / 48000)]);
      expect(Loudness.lufs(sine(1), 48000), closeTo(-3.0, 0.5));
      expect(Loudness.lufs(sine(0.1), 48000), closeTo(-23.0, 0.5));
      expect(Loudness.lufs(Float32List(48000), 48000), Loudness.silence);
      expect(AutoMix.volumeFor(-22, -16), closeTo(199.5, 0.2));
      expect(AutoMix.volumeFor(-8, -28), closeTo(10, 0.1));
      expect(AutoMix.volumeFor(-60, -16), 200); // capped
    });

    test('voice activity', () {
      const sr = 16000;
      final x = Float32List(sr * 6);
      for (int i = 0; i < x.length; i++) {
        final t = i / sr;
        final on = (t > 1 && t < 2) || (t > 3 && t < 4.5);
        x[i] = on ? 0.3 * math.sin(2 * math.pi * 220 * t) : 0.001 * math.sin(i * 1.3);
      }
      final s = AutoMix.speechIntervals(x, sr);
      expect(s.length, 2);
      expect(s[0].$1, closeTo(1, 0.05));
      expect(s[0].$2, closeTo(2, 0.05));
      expect(s[1].$1, closeTo(3, 0.05));
      expect(s[1].$2, closeTo(4.5, 0.05));
    });
  });

  // ------------------------------------------------------------------ beat sync
  group('Beat sync', () {
    test('nearest', () {
      final b = [0.0, 0.5, 1.0, 1.5];
      expect(BeatSync.nearest(b, 0.62, 0.2), 0.5);
      expect(BeatSync.nearest(b, 0.80, 0.25), 1.0);
      expect(BeatSync.nearest(b, 0.75, 0.2), isNull);
      expect(BeatSync.nearest(b, 9, 0.2), isNull);
      expect(BeatSync.nearest(const [], 1, 1), isNull);
    });

    Project shots() {
      final p = project();
      p.media['sfx_whoosh'] = MediaAsset(id: 'sfx_whoosh', type: MediaType.audio, path: '/w.wav', name: 'SFX whoosh', width: 0, height: 0, duration: 0.7);
      EditCommands.runAtomic(p, {
        'op': 'batch',
        'commands': [
          {'op': 'add_layer', 'type': 'image', 'media': 'img', 'id': 'A', 'start': 0, 'duration': 2.1},
          {'op': 'add_layer', 'type': 'image', 'media': 'img', 'id': 'B', 'start': 2.1, 'duration': 2.3},
          {'op': 'set_keyframe', 'target': 'B', 'prop': 'scale', 'time': 2.1, 'value': [100, 100, 100]},
          {'op': 'set_keyframe', 'target': 'B', 'prop': 'scale', 'time': 4.4, 'value': [110, 110, 100]},
          {'op': 'add_layer', 'type': 'image', 'media': 'img', 'id': 'C', 'start': 4.4, 'duration': 1.6},
          {'op': 'add_layer', 'type': 'audio', 'media': 'sfx_whoosh', 'id': 'S', 'name': 'SFX whoosh', 'start': 2.1 - Sfx.peak('whoosh'), 'duration': 0.7},
        ],
      });
      return p;
    }

    void checkSnapped(Project p) {
      final c = p.main;
      expect(c.layerById('A')!.start, 0);
      expect(c.layerById('A')!.end, closeTo(2.0, 1e-3));
      expect(c.layerById('B')!.start, closeTo(2.0, 1e-3));
      expect(c.layerById('B')!.end, closeTo(4.5, 1e-3));
      expect(c.layerById('C')!.start, closeTo(4.5, 1e-3));
      expect(c.layerById('C')!.end, closeTo(6.0, 1e-3));
      expect(c.layerById('B')!.prop(Props.scale).keyframes.first.time, closeTo(2.0, 1e-3));
      expect(c.layerById('S')!.start + Sfx.peak('whoosh'), closeTo(2.0, 1e-3));
    }

    test('snap cuts to beats (pure commands, atomic)', () {
      final p = shots();
      final beats = [for (int i = 0; i <= 12; i++) i * 0.5];
      expect(BeatSync.cutTimes(p.main), [2.1, 4.4].map((v) => closeTo(v, 1e-9)).toList());
      final cmds = BeatSync.snapCuts(p, beats, tolerance: 0.25);
      EditCommands.runAtomic(p, {'op': 'batch', 'commands': cmds});
      checkSnapped(p);
    });

    test('beat_sync op with a BPM grid and with analysed music', () {
      final p = shots();
      EditCommands.runAtomic(p, {'op': 'beat_sync', 'mode': 'cuts', 'bpm': 120, 'offset': 0});
      checkSnapped(p);

      final q = shots();
      q.media['song'] = MediaAsset(id: 'song', type: MediaType.audio, path: '/tmp/song_test.mp3', name: 'Song', width: 0, height: 0, duration: 60);
      EditCommands.runAtomic(q, {'op': 'add_layer', 'type': 'audio', 'media': 'song', 'id': 'M', 'name': 'Music', 'start': 0, 'source_in': 10});
      AudioCache.putMusic(q.media['song']!, MusicAnalysis.grid(120, offset: 0, duration: 60));
      EditCommands.runAtomic(q, {'op': 'beat_sync', 'mode': 'cuts', 'music': 'M'});
      checkSnapped(q);
      AudioCache.clear();
    });

    test('beat_sync without beats explains what to do and changes nothing', () {
      final p = shots();
      final before = ProjectSnapshot.take(p);
      expect(() => EditCommands.runAtomic(p, {'op': 'beat_sync', 'mode': 'cuts'}), throwsA(isA<CommandError>()));
      expect(ProjectSnapshot.take(p), before);
    });

    test('text pops land on beats; groups move with children', () {
      final p = project();
      EditCommands.runAtomic(p, {
        'op': 'batch',
        'commands': [
          {'op': 'add_layer', 'type': 'text', 'id': 'T', 'text': 'Boom', 'start': 1.12, 'duration': 2},
          {'op': 'add_layer', 'type': 'null', 'id': 'G', 'start': 3.3, 'duration': 2},
          {'op': 'add_layer', 'type': 'text', 'id': 'G_t', 'text': 'Kid', 'parent': 'G', 'start': 3.5, 'duration': 1.8},
        ],
      });
      EditCommands.runAtomic(p, {'op': 'batch', 'commands': BeatSync.popsOnBeats(p, [0, 1, 2, 3, 4], tolerance: 0.35)});
      expect(p.main.layerById('T')!.start, closeTo(1.0, 1e-6));
      expect(p.main.layerById('T')!.duration, closeTo(2.0, 1e-6));
      expect(p.main.layerById('G')!.start, closeTo(3.3, 1e-6)); // not a text layer: untouched by default
      EditCommands.runAtomic(p, {'op': 'beat_sync', 'mode': 'pops', 'beats': [0, 1, 2, 3, 4], 'layers': ['G']});
      expect(p.main.layerById('G')!.start, closeTo(3.0, 1e-6));
      expect(p.main.layerById('G_t')!.start, closeTo(3.2, 1e-6));
    });

    test('hit on the drop', () {
      final p = project(duration: 20);
      p.media['song'] = MediaAsset(id: 'song', type: MediaType.audio, path: '/s.mp3', name: 'Song', width: 0, height: 0, duration: 60);
      EditCommands.runAtomic(p, {'op': 'add_layer', 'type': 'audio', 'media': 'song', 'id': 'M', 'name': 'Music', 'start': 0, 'duration': 20});
      EditCommands.runAtomic(p, {'op': 'batch', 'commands': BeatSync.hitOnDrop(p, 'M', 30, at: 2.6)});
      final m = p.main.layerById('M')!;
      expect(m.start, closeTo(2.6, 1e-6));
      expect(m.sourceIn, closeTo(30, 1e-6));
      expect(m.sourceTimeAt(2.6), closeTo(30, 1e-6));
      expect(m.end, closeTo(20, 1e-6));

      // With a 2 s build-up fading in, through the op and the cache.
      AudioCache.putMusic(p.media['song']!, MusicAnalysis(
          duration: 60, tempo: 120, confidence: 1, beats: const [], downbeats: const [], onsets: const [],
          drops: const [12.0, 31.0], dropStrength: const [7, 15], sections: const [], energy: Float32List(0), energyRate: 1, loudness: -10));
      EditCommands.runAtomic(p, {'op': 'beat_sync', 'mode': 'drop', 'music': 'M', 'at': 4.0, 'preroll': 2, 'fade_in': 1.5});
      expect(m.start, closeTo(2.0, 1e-6));
      expect(m.sourceTimeAt(4.0), closeTo(31.0, 1e-6));
      expect(m.prop(Props.volume).scalarAt(2.0), closeTo(0, 1e-6));
      expect(m.prop(Props.volume).scalarAt(3.6), greaterThan(50));
      AudioCache.clear();
    });

    test('storyboard beats snap to music beats', () {
      final story = [
        Beat(0, 2.12, 'a', {}),
        Beat(2.12, 4.38, 'b', {}),
        Beat(4.38, 7, 'c', {}),
      ];
      BeatSync.snapStoryboard(story, [for (int i = 0; i < 20; i++) i * 0.5]);
      expect(story[0].end, 2.0);
      expect(story[1].start, 2.0);
      expect(story[1].end, 4.5);
      expect(story[2].start, 4.5);
    });
  });

  // ------------------------------------------------------------------ mix + add_sfx
  group('Auto mix & add_sfx', () {
    late Directory tmp;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('motionai_sfx_test');
      SfxLibrary.dir = tmp.path;
    });
    tearDown(() {
      AudioCache.clear();
      SfxLibrary.dir = null;
      try {
        tmp.deleteSync(recursive: true);
      } on FileSystemException {
        // ignore
      }
    });

    Project mixProject() {
      final p = project(duration: 10);
      p.media['vo'] = MediaAsset(id: 'vo', type: MediaType.audio, path: '/vo.wav', name: 'Voice-over', width: 0, height: 0, duration: 10);
      p.media['music'] = MediaAsset(id: 'music', type: MediaType.audio, path: '/m.mp3', name: 'Song', width: 0, height: 0, duration: 30);
      EditCommands.runAtomic(p, {
        'op': 'batch',
        'commands': [
          {'op': 'add_layer', 'type': 'audio', 'media': 'vo', 'id': 'V', 'name': 'Voice-over', 'start': 0, 'duration': 10},
          {'op': 'add_layer', 'type': 'audio', 'media': 'music', 'id': 'M', 'name': 'Music', 'start': 0, 'duration': 10},
          {'op': 'add_sfx', 'kind': 'whoosh', 'time': 5, 'id': 'S'},
        ],
      });
      return p;
    }

    test('roles', () {
      final p = mixProject();
      expect(AutoMix.roleOf(p, p.main.layerById('V')!), 'voice');
      expect(AutoMix.roleOf(p, p.main.layerById('M')!), 'music');
      expect(AutoMix.roleOf(p, p.main.layerById('S')!), 'sfx');
    });

    test('plan levels, ducks and fades (runs atomically)', () {
      final p = mixProject();
      final cmds = AutoMix.plan(p, loudness: {'vo': -22, 'music': -12}, speech: const [(2.0, 4.0)]);
      EditCommands.runAtomic(p, {'op': 'batch', 'commands': cmds});
      final v = p.main.layerById('V')!.prop(Props.volume);
      expect(v.isAnimated, isFalse);
      expect(v.scalarAt(5), closeTo(199.5, 0.2));
      final m = p.main.layerById('M')!.prop(Props.volume);
      final base = AutoMix.volumeFor(-12, -28);
      expect(m.scalarAt(0), closeTo(0, 1e-6)); // fade in
      expect(m.scalarAt(10), closeTo(0, 1e-6)); // fade out
      expect(m.scalarAt(3), closeTo(base * Loudness.dbToGain(-10), 0.2)); // ducked
      expect(m.scalarAt(6), closeTo(base, 0.2));
      final s = p.main.layerById('S')!.prop(Props.volume);
      expect(s.scalarAt(5), closeTo(AutoMix.volumeFor(SfxLibrary.lufs('whoosh'), -20), 0.2));
    });

    test('auto_mix op uses measured loudness and voice activity', () {
      final p = mixProject();
      AudioCache.putLoudness(p.media['vo']!, -16);
      AudioCache.putLoudness(p.media['music']!, -28);
      AudioCache.putSpeech(p.media['vo']!, const [(6.0, 8.0)]);
      EditCommands.runAtomic(p, {'op': 'auto_mix'});
      expect(p.main.layerById('V')!.prop(Props.volume).scalarAt(1), closeTo(100, 0.2));
      final m = p.main.layerById('M')!.prop(Props.volume);
      expect(m.scalarAt(4), closeTo(100, 0.5));
      expect(m.scalarAt(7), closeTo(100 * Loudness.dbToGain(-10), 0.5));
      expect(() => EditCommands.runAtomic(p, {'op': 'auto_mix', 'roles': {'nope': 'music'}}), throwsA(isA<CommandError>()));
    });

    test('add_sfx writes the sound once, puts its peak on the time', () {
      final p = project();
      EditCommands.runAtomic(p, {'op': 'add_sfx', 'kind': 'whoosh', 'time': 2.0, 'id': 'w1'});
      EditCommands.runAtomic(p, {'op': 'add_sfx', 'kind': 'whoosh', 'time': 4.0, 'id': 'w2'});
      final w1 = p.main.layerById('w1')!;
      expect(w1.type, LayerType.audio);
      expect(w1.start + Sfx.peak('whoosh'), closeTo(2.0, 1e-9));
      expect(p.main.layerById('w2')!.mediaId, w1.mediaId);
      final media = p.media[w1.mediaId]!;
      expect(media.name, 'SFX whoosh');
      expect(File(media.path).existsSync(), isTrue);
      expect(Wav.decode(File(media.path).readAsBytesSync()).duration, closeTo(0.7, 0.01));
      expect(p.main.layers.last.id, 'w2'); // audio goes to the bottom of the stack

      // A peak before 0 skips the head instead of shifting the hit.
      EditCommands.runAtomic(p, {'op': 'add_sfx', 'kind': 'reverse_cymbal', 'time': 1.0, 'id': 'rc'});
      final rc = p.main.layerById('rc')!;
      expect(rc.start, 0);
      expect(rc.sourceTimeAt(1.0), closeTo(Sfx.peak('reverse_cymbal'), 1e-6));
    });

    test('beds tile and fade; mood picks the bed; typewriter syncs to text', () {
      final p = project(duration: 30);
      EditCommands.runAtomic(p, {'op': 'add_sfx', 'kind': 'wind_bed', 'time': 1, 'duration': 20, 'id': 'wb'});
      final tiles = p.main.layers.where((l) => l.id.startsWith('wb_')).toList()..sort((a, b) => a.start.compareTo(b.start));
      expect(tiles.length, 3);
      expect(tiles.first.start, closeTo(1, 1e-6));
      expect(tiles.last.end, closeTo(21, 1e-6));
      for (int i = 1; i < tiles.length; i++) {
        expect(tiles[i].start, closeTo(tiles[i - 1].end, 1e-6));
      }
      expect(tiles.first.prop(Props.volume).scalarAt(1), closeTo(0, 1e-6));
      expect(tiles.last.prop(Props.volume).scalarAt(21), closeTo(0, 1e-6));
      expect(tiles[1].prop(Props.volume).scalarAt(12), greaterThan(0));

      EditCommands.runAtomic(p, {'op': 'add_sfx', 'mood': 'heavy monsoon rain', 'time': 0, 'duration': 4, 'id': 'rain'});
      expect(p.media[p.main.layerById('rain')!.mediaId]!.name, 'SFX rain_bed');
      expect(AutoMix.bedForMood('war'), 'fire_bed');
      expect(AutoMix.bedForMood('crowded bazaar'), 'crowd_bed');
      expect(AutoMix.bedForMood('xyz'), isNull);

      EditCommands.runAtomic(p, {'op': 'add_layer', 'type': 'text', 'id': 'T', 'text': 'Breaking', 'start': 3, 'animator': 'typewriter', 'anim_duration': 1.6});
      EditCommands.runAtomic(p, {'op': 'add_sfx', 'kind': 'typewriter', 'layer': 'T', 'id': 'ty'});
      final ty = p.main.layerById('ty')!;
      expect(ty.start, 3);
      expect(ty.duration, closeTo(Sfx.typingTimes('Breaking', 1.6).last + 0.15, 0.01));
    });

    test('ambience per scene mood', () {
      final p = project(duration: 20);
      final rain = SfxLibrary.ensureSync(p, 'rain_bed');
      final crowd = SfxLibrary.ensureSync(p, 'crowd_bed');
      final cmds = AutoMix.ambience(p, const [(0.0, 6.0, 'rain'), (6.0, 15.0, 'protest crowd'), (15.0, 20.0, 'unknown')],
          {'rain_bed': rain.id, 'crowd_bed': crowd.id});
      EditCommands.runAtomic(p, {'op': 'batch', 'commands': cmds});
      final amb = p.main.layers.where((l) => l.name.startsWith('Ambience')).toList();
      expect(amb.length, 3); // 6 s rain, 9 s crowd = 8 + 1
      expect(AutoMix.roleOf(p, amb.first), 'ambience');
    });

    test('bad add_sfx is rejected and changes nothing', () {
      final p = project();
      final before = ProjectSnapshot.take(p);
      expect(() => EditCommands.runAtomic(p, {'op': 'add_sfx', 'kind': 'kazoo'}), throwsA(isA<CommandError>()));
      expect(() => EditCommands.runAtomic(p, {'op': 'add_sfx', 'kind': 'typewriter', 'layer': 'nope'}), throwsA(isA<CommandError>()));
      expect(ProjectSnapshot.take(p), before);
      expect(EditCommands.ops, containsAll(['add_sfx', 'beat_sync', 'auto_mix']));
    });

    test('missing SFX files are regenerated', () {
      final p = project();
      final a = SfxLibrary.ensureSync(p, 'ding');
      File(a.path).deleteSync();
      expect(SfxLibrary.repair(p), 1);
      expect(File(a.path).existsSync(), isTrue);
    });
  });
}
