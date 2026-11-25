import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:video_player/video_player.dart';

import '../core/model/project.dart';
import '../platform/win_media.dart';
import 'media_bridge.dart';
import 'project_storage.dart';

/// Picks media files, copies them into app storage and probes their size
/// and duration.
class MediaImporter {
  final ProjectStorage storage;
  MediaImporter(this.storage);

  static const _videoExt = ['mp4', 'mov', 'm4v', 'webm', 'mkv', '3gp', 'avi', 'wmv'];
  static const _imageExt = ['jpg', 'jpeg', 'png', 'webp', 'gif', 'bmp', 'heic'];
  static const _audioExt = ['mp3', 'm4a', 'aac', 'wav', 'ogg', 'flac', 'opus'];

  /// Files that couldn't be imported in the last [pick], with reasons.
  final List<String> errors = [];

  Future<List<MediaAsset>> pick({required MediaType kind}) async {
    errors.clear();
    // file_picker 13: static API, multi-select by default, empty list on cancel.
    final files = await FilePicker.pickFiles(
      type: switch (kind) { MediaType.video => FileType.video, MediaType.image => FileType.image, MediaType.audio => FileType.audio },
    );
    final out = <MediaAsset>[];
    for (final f in files) {
      try {
        var path = f.path;
        if (path == null || !await File(path).exists()) {
          // Some pickers return the file contents without a usable path.
          final tmp = '${await storage.mediaDir()}/pick_${DateTime.now().microsecondsSinceEpoch}_${f.name}';
          final sink = File(tmp).openWrite();
          await sink.addStream(f.readAsByteStream());
          await sink.close();
          path = tmp;
        }
        final asset = await importPath(path, name: f.name, hint: kind);
        if (asset != null) out.add(asset);
      } catch (e) {
        errors.add('${f.name}: $e');
      }
    }
    return out;
  }

  /// Imports files dropped from Explorer (or any list of paths). Unknown
  /// file types are reported in [errors].
  Future<List<MediaAsset>> importPaths(List<String> paths) async {
    errors.clear();
    final out = <MediaAsset>[];
    for (final p in paths) {
      final name = p.split(RegExp(r'[\\/]')).last;
      final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
      if (!isSupportedExtension(ext)) {
        errors.add('$name: not a photo, video or audio file');
        continue;
      }
      try {
        final a = await importPath(p, name: name);
        if (a != null) out.add(a);
      } catch (e) {
        errors.add('$name: $e');
      }
    }
    return out;
  }

  static bool isSupportedExtension(String ext) =>
      _videoExt.contains(ext) || _imageExt.contains(ext) || _audioExt.contains(ext) || ext == 'heif' || ext == 'avif';

  Future<MediaAsset?> importPath(String path, {String? name, MediaType? hint}) async {
    final ext = path.contains('.') ? path.split('.').last.toLowerCase() : '';
    var isVideo = _videoExt.contains(ext);
    var isAudio = _audioExt.contains(ext);
    var isImage = _imageExt.contains(ext) || ext == 'heif' || ext == 'avif';
    if (!isVideo && !isImage && !isAudio) {
      // Unknown extension (some galleries hand out files without one): trust the picker.
      isVideo = hint == MediaType.video;
      isAudio = hint == MediaType.audio;
      isImage = hint == MediaType.image || hint == null;
    }
    final id = Ids.next(isVideo ? 'vid' : isAudio ? 'aud' : 'img');
    final display = name ?? path.split(Platform.pathSeparator).last;

    if (isImage) {
      // Convert to an upright JPEG/PNG the preview can always draw.
      final mediaDir = await storage.mediaDir();
      final norm = await MediaBridge.normalizeImage(path, '$mediaDir/$id');
      final stored = norm?.$1 ?? await storage.importFile(path, id);
      final bytes = await File(stored).readAsBytes();
      final ui.Codec codec;
      try {
        codec = await ui.instantiateImageCodec(bytes);
      } catch (_) {
        throw Exception('this image format is not supported');
      }
      final frame = await codec.getNextFrame();
      final w = frame.image.width.toDouble(), h = frame.image.height.toDouble();
      frame.image.dispose();
      codec.dispose();
      return MediaAsset(id: id, type: MediaType.image, path: stored, name: display, width: w, height: h);
    }

    final stored = await storage.importFile(path, id);
    if (Platform.isWindows) {
      // FFprobe reads every container/codec FFmpeg can export from.
      final info = await WinMedia.probe(stored);
      if (!info.hasVideo && !info.hasAudio) throw Exception('no audio or video found');
      final audioOnly = isAudio || !info.hasVideo;
      return MediaAsset(
        id: id,
        type: audioOnly ? MediaType.audio : MediaType.video,
        path: stored,
        name: display,
        width: info.displayWidth > 0 ? info.displayWidth.toDouble() : 1920,
        height: info.displayHeight > 0 ? info.displayHeight.toDouble() : 1080,
        duration: info.duration,
      );
    }
    final c = VideoPlayerController.file(File(stored));
    try {
      await c.initialize();
      final size = c.value.size;
      return MediaAsset(
        id: id,
        type: isAudio ? MediaType.audio : MediaType.video,
        path: stored,
        name: display,
        width: size.width > 0 ? size.width : 1920,
        height: size.height > 0 ? size.height : 1080,
        duration: c.value.duration.inMicroseconds / 1e6,
      );
    } finally {
      await c.dispose();
    }
  }
}
