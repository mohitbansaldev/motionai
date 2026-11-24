import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:video_player/video_player.dart';

import '../core/model/project.dart';
import 'media_bridge.dart';
import 'project_storage.dart';

/// Picks media files, copies them into app storage and probes their size
/// and duration.
class MediaImporter {
  final ProjectStorage storage;
  MediaImporter(this.storage);

  static const _videoExt = ['mp4', 'mov', 'm4v', 'webm', 'mkv', '3gp'];
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
      final path = f.path;
      if (path == null) {
        errors.add('${f.name}: file could not be opened');
        continue;
      }
      try {
        final asset = await importPath(path, name: f.name, hint: kind);
        if (asset != null) out.add(asset);
      } catch (e) {
        errors.add('${f.name}: $e');
      }
    }
    return out;
  }

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
