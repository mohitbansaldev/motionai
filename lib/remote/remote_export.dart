// MCP (Agent P): an export started by Claude. ExportScreen reads these
// settings, starts at once and reports progress through [job].

import 'remote_jobs.dart';

class RemoteExport {
  final int shortSide; // 720 | 1080 | 1440 | 2160
  final double? fps; // null = project fps
  final String? folder; // Windows output folder
  final String? fileName; // always ends in .mp4
  final bool high;
  final RemoteJob job;

  RemoteExport({required this.job, this.shortSide = 1080, this.fps, this.folder, String? fileName, this.high = true})
      : fileName = cleanFileName(fileName);

  /// A safe file name (no folders), ending in .mp4; null if empty.
  static String? cleanFileName(String? name) {
    if (name == null) return null;
    var n = name.split(RegExp(r'[\\/]')).last.trim().replaceAll(RegExp(r'[<>:"|?*\x00-\x1F]'), '_');
    if (n.isEmpty || n == '.mp4') return null;
    if (!n.toLowerCase().endsWith('.mp4')) n = '$n.mp4';
    return n;
  }

  /// Called by ExportScreen when its run ends (phase done / failed / setup = cancelled).
  void finished(String phase, String? result, String? error, {String? cancelledBy}) {
    switch (phase) {
      case 'done':
        job.done({'file': result}, message: 'Exported to $result');
      case 'failed':
        job.fail(error ?? 'Export failed');
      default:
        job.cancelled(cancelledBy == null ? 'Cancelled (export screen closed or stopped)' : 'Cancelled by $cancelledBy');
    }
  }
}
