import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:video_player/video_player.dart';

import '../core/model/project.dart';
import 'project_storage.dart';

/// Picks media files, copies them into app storage and probes their size
/// and duration.
class MediaImporter {
  final ProjectStorage storage;
  MediaImporter(this.storage);

  static const _videoExt = ['mp4', 'mov', 'm4v', 'webm', 'mkv', '3gp'];
  static const _imageExt = ['jpg', 'jpeg', 'png', 'webp', 'gif', 'bmp', 'heic'];

  Future<List<MediaAsset>> pick({required bool video}) async {
    // file_picker 13: static API, multi-select by default, empty list on cancel.
    final files = await FilePicker.pickFiles(type: video ? FileType.video : FileType.image);
    final out = <MediaAsset>[];
    for (final f in files) {
      final path = f.path;
      if (path == null) continue;
      final asset = await importPath(path, name: f.name);
      if (asset != null) out.add(asset);
    }
    return out;
  }

  Future<MediaAsset?> importPath(String path, {String? name}) async {
    final ext = path.split('.').last.toLowerCase();
    final isVideo = _videoExt.contains(ext);
    final isImage = _imageExt.contains(ext);
    if (!isVideo && !isImage) return null;
    final id = Ids.next(isVideo ? 'vid' : 'img');
    final stored = await storage.importFile(path, id);
    final display = name ?? path.split(Platform.pathSeparator).last;
    if (isVideo) {
      final c = VideoPlayerController.file(File(stored));
      try {
        await c.initialize();
        final size = c.value.size;
        return MediaAsset(
          id: id,
          type: MediaType.video,
          path: stored,
          name: display,
          width: size.width > 0 ? size.width : 1920,
          height: size.height > 0 ? size.height : 1080,
          duration: c.value.duration.inMicroseconds / 1e6,
        );
      } finally {
        await c.dispose();
      }
    } else {
      final bytes = await File(stored).readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final w = frame.image.width.toDouble(), h = frame.image.height.toDouble();
      frame.image.dispose();
      codec.dispose();
      return MediaAsset(id: id, type: MediaType.image, path: stored, name: display, width: w, height: h);
    }
  }
}
