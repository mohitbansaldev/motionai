// Downloaded AI models for the Windows app (Agent E): fetched once into the
// app support folder, checked against a known size and hash, then reused.
import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

enum HashKind { sha1, sha256 }

/// One model file: where to get it and how to recognise a good copy.
class ModelSpec {
  final String fileName;
  final List<String> urls;

  /// Exact size in bytes (also used for progress when the server sends no
  /// Content-Length).
  final int bytes;
  final HashKind hashKind;
  final String hash;

  /// Short human label for status lines ("speech model (base)").
  final String label;

  const ModelSpec({
    required this.fileName,
    required this.urls,
    required this.bytes,
    required this.hashKind,
    required this.hash,
    required this.label,
  });

  String get sizeLabel => bytes >= 1 << 20 ? '${(bytes / (1 << 20)).round()} MB' : '${(bytes / 1024).round()} KB';
}

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

class ModelStore {
  static final Map<String, Future<String>> _pending = {};

  /// Folder that holds the models (created on demand). Tests may override.
  static Future<Directory> Function() modelsDir = () async {
    final root = await getApplicationSupportDirectory();
    final d = Directory('${root.path}${Platform.pathSeparator}models');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  };

  /// HTTP client factory (tests swap in a mock).
  static http.Client Function() httpClient = http.Client.new;

  static Hash _algo(HashKind k) => k == HashKind.sha1 ? sha1 : sha256;

  /// Hex digest of [path] (runs in a background isolate).
  static Future<String> hashFile(String path, HashKind kind) => Isolate.run(() async {
        final sink = _DigestSink();
        final conv = _algo(kind).startChunkedConversion(sink);
        await for (final chunk in File(path).openRead()) {
          conv.add(chunk);
        }
        conv.close();
        return sink.value.toString();
      });

  /// Local path of [spec], downloading it first if needed. [onProgress]
  /// gets 0..1 while downloading.
  static Future<String> ensure(ModelSpec spec, {void Function(double progress)? onProgress}) {
    final running = _pending[spec.fileName];
    if (running != null) return running;
    // Block body: returning the removed future from whenComplete would make
    // the future wait for itself.
    final f = _ensure(spec, onProgress).whenComplete(() {
      _pending.remove(spec.fileName);
    });
    _pending[spec.fileName] = f;
    return f;
  }

  static Future<String> _ensure(ModelSpec spec, void Function(double)? onProgress) async {
    final dir = await modelsDir();
    final file = File('${dir.path}${Platform.pathSeparator}${spec.fileName}');
    final ok = File('${file.path}.ok');
    // V2-E >>> a model pinned by URL only (hash ""): trusted once a download
    // passed the size check (its SHA-256 is recorded in <file>.sha256).
    if (spec.hash.isEmpty && await file.exists() && await ok.exists()) return file.path;
    // <<< V2-E
    if (await file.exists()) {
      final len = await file.length();
      // "<hash> <length>" is written once a copy has been verified.
      if (await ok.exists() && (await ok.readAsString()).trim() == '${spec.hash} $len') return file.path;
      // A copy from an earlier version of the app: check it once.
      if (len > 0 && await hashFile(file.path, spec.hashKind) == spec.hash) {
        await ok.writeAsString('${spec.hash} $len');
        return file.path;
      }
    }
    Object? lastError;
    for (final url in spec.urls) {
      try {
        await _download(url, spec, file, onProgress);
        await ok.writeAsString('${spec.hash} ${await file.length()}');
        return file.path;
      } catch (e) {
        lastError = e;
      }
    }
    throw HttpException('Could not download the ${spec.label} (${spec.sizeLabel}). Check the internet connection and try again. ($lastError)');
  }

  static Future<void> _download(String url, ModelSpec spec, File dest, void Function(double)? onProgress) async {
    final part = File('${dest.path}.part');
    final client = httpClient();
    try {
      final res = await client.send(http.Request('GET', Uri.parse(url))).timeout(const Duration(seconds: 30));
      if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}');
      final total = (res.contentLength ?? 0) > 0 ? res.contentLength! : spec.bytes;
      final sink = part.openWrite();
      final digest = _DigestSink();
      final hasher = _algo(spec.hashKind).startChunkedConversion(digest);
      var got = 0, reported = -1;
      try {
        await for (final chunk in res.stream.timeout(const Duration(seconds: 60))) {
          sink.add(chunk);
          hasher.add(chunk);
          got += chunk.length;
          final pct = total > 0 ? (got * 100 ~/ total) : 0;
          if (pct != reported) {
            reported = pct;
            onProgress?.call((got / total).clamp(0.0, 1.0).toDouble());
          }
        }
      } finally {
        await sink.close();
        hasher.close();
      }
      if (res.contentLength != null && res.contentLength! > 0 && got != res.contentLength) {
        throw HttpException('incomplete download ($got of ${res.contentLength} bytes)');
      }
      // V2-E >>> no pinned hash: check the size instead and record the hash.
      if (spec.hash.isEmpty) {
        if (spec.bytes > 0 && (got - spec.bytes).abs() > spec.bytes * 0.15) {
          throw HttpException('unexpected download size ($got bytes, expected about ${spec.bytes})');
        }
        await File('${dest.path}.sha256').writeAsString('${digest.value} $got\n');
      }
      // <<< V2-E
      // The hash is the real check (the size is only for progress).
      if (spec.hash.isNotEmpty /* V2-E */ && digest.value.toString() != spec.hash) throw HttpException('downloaded file is damaged (hash mismatch, $got bytes)');
      if (await dest.exists()) await dest.delete();
      await part.rename(dest.path);
      onProgress?.call(1);
    } finally {
      client.close();
      if (await part.exists()) await part.delete().catchError((_) => part);
    }
  }
}
