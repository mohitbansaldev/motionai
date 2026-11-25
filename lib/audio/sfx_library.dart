import 'dart:io';
import 'dart:typed_data';

import '../core/model/project.dart';
import '../director/sfx.dart';
import 'loudness.dart';

/// Turns synthesised sound effects into project media (WAV files on disk).
///
/// Files are named `sfx_<kind>.wav` in [dir] and the media assets are named
/// `SFX <kind>` — the same convention the Director already uses, so assets
/// are shared. Because the synth is deterministic, a missing file (project
/// opened on another device) can always be regenerated: see [repair].
class SfxLibrary {
  /// Where generated WAVs go. The app should set this to the project media
  /// folder (ProjectStorage.mediaDir) at start-up; SoundSheet.open does.
  static String? dir;

  static String get _dir {
    final d = dir ?? '${Directory.systemTemp.path}${Platform.pathSeparator}motionai_sfx';
    Directory(d).createSync(recursive: true);
    return d;
  }

  static String nameFor(String kind) => 'SFX $kind';

  /// The SFX kind of a generated asset, or null.
  static String? kindOf(MediaAsset m) {
    if (m.type != MediaType.audio || !m.name.startsWith('SFX ')) return null;
    final k = m.name.substring(4).trim();
    return Sfx.all.contains(k) ? k : null;
  }

  /// The project's asset for [kind]; writes the WAV and adds the asset when
  /// needed (synchronously, so edit commands can use it).
  static MediaAsset ensureSync(Project p, String kind) {
    if (!Sfx.all.contains(kind)) throw ArgumentError('Unknown sound "$kind". Sounds: ${Sfx.all.join(', ')}');
    for (final m in p.media.values) {
      if (kindOf(m) == kind) {
        if (!File(m.path).existsSync()) _restore(m, kind);
        return m;
      }
    }
    final path = '$_dir${Platform.pathSeparator}sfx_$kind.wav';
    final f = File(path);
    if (!f.existsSync() || f.lengthSync() != 44 + (Sfx.length(kind) * Sfx.rate).round() * 4) f.writeAsBytesSync(Sfx.wav(kind));
    final id = p.media.containsKey('sfx_$kind') ? Ids.next('sfx') : 'sfx_$kind';
    final a = MediaAsset(id: id, type: MediaType.audio, path: path, name: nameFor(kind), width: 0, height: 0, duration: Sfx.length(kind));
    p.media[id] = a;
    return a;
  }

  /// Typewriter clicks at [times] (seconds) as a one-off asset.
  static MediaAsset typingSync(Project p, List<double> times) {
    final key = times.map((t) => (t * 1000).round()).fold<int>(17, (h, v) => (h * 31 + v) & 0x7FFFFFFF).toRadixString(36);
    final id = 'sfx_typing_$key';
    final existing = p.media[id];
    final bytes = Sfx.typing(times);
    final dur = (bytes.length - 44) / 4 / Sfx.rate;
    if (existing != null) {
      final f = File(existing.path);
      if (!f.existsSync()) f.writeAsBytesSync(bytes);
      return existing;
    }
    final path = '$_dir${Platform.pathSeparator}$id.wav';
    File(path).writeAsBytesSync(bytes);
    final a = MediaAsset(id: id, type: MediaType.audio, path: path, name: 'SFX typing', width: 0, height: 0, duration: dur);
    p.media[id] = a;
    return a;
  }

  /// Regenerates generated SFX files that are missing on this device.
  /// Returns how many were written.
  static int repair(Project p) {
    var n = 0;
    for (final m in p.media.values) {
      final k = kindOf(m);
      if (k == null) continue;
      if (File(m.path).existsSync()) continue;
      _restore(m, k);
      n++;
    }
    return n;
  }

  /// Rewrites a missing generated file; a path from another device that
  /// can't be written is pointed at this device's folder.
  static void _restore(MediaAsset m, String kind) {
    try {
      final f = File(m.path);
      f.parent.createSync(recursive: true);
      f.writeAsBytesSync(Sfx.wav(kind));
    } on FileSystemException {
      final path = '$_dir${Platform.pathSeparator}sfx_$kind.wav';
      File(path).writeAsBytesSync(Sfx.wav(kind));
      m.path = path;
    }
  }

  static final Map<String, double> _lufs = {};

  /// Loudness (approx. LUFS) of a generated sound.
  static double lufs(String kind) => _lufs.putIfAbsent(kind, () {
        final (l, r) = Sfx.render(kind);
        final m = Float32List(l.length);
        for (int i = 0; i < m.length; i++) {
          m[i] = (l[i] + r[i]) * 0.5;
        }
        return Loudness.lufs(m, Sfx.rate);
      });
}
