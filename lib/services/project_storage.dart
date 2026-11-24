import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../core/model/project.dart';

/// Saves projects as JSON files and keeps imported media in the app's
/// private documents folder (so files never disappear from a cache).
class ProjectStorage {
  Directory? _root;

  Future<Directory> _dir(String name) async {
    _root ??= await getApplicationDocumentsDirectory();
    final d = Directory('${_root!.path}/motionai/$name');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  Future<List<Project>> listProjects() async {
    final d = await _dir('projects');
    final out = <Project>[];
    await for (final f in d.list()) {
      if (f is File && f.path.endsWith('.json')) {
        try {
          out.add(Project.fromJson(jsonDecode(await f.readAsString()) as Map<String, dynamic>));
        } catch (_) {
          // Skip unreadable files rather than crash the project list.
        }
      }
    }
    out.sort((a, b) => b.modified.compareTo(a.modified));
    return out;
  }

  Future<void> save(Project p) async {
    p.modified = DateTime.now();
    final d = await _dir('projects');
    final tmp = File('${d.path}/${p.id}.json.tmp');
    await tmp.writeAsString(jsonEncode(p.toJson()), flush: true);
    await tmp.rename('${d.path}/${p.id}.json');
  }

  Future<void> delete(Project p) async {
    final d = await _dir('projects');
    final f = File('${d.path}/${p.id}.json');
    if (await f.exists()) await f.delete();
  }

  /// Copies a picked file into app storage and returns the new path.
  Future<String> importFile(String sourcePath, String assetId) async {
    final d = await _dir('media');
    final dot = sourcePath.lastIndexOf('.');
    final ext = dot >= 0 ? sourcePath.substring(dot) : '';
    final dest = '${d.path}/$assetId$ext';
    await File(sourcePath).copy(dest);
    return dest;
  }
}
