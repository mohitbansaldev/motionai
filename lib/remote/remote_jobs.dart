// MCP (Agent P): background jobs started by Claude (export, Director,
// captions), polled with export_status / job_status. Pure Dart.

class RemoteJob {
  final String id;
  final String kind; // export | director | captions
  final DateTime started = DateTime.now();
  String state = 'running'; // running | done | failed | cancelled
  String _message = '';

  /// How many times [message] changed (progress for jobs without a frame count).
  int updates = 0;
  Object? result;
  String? error;
  DateTime? finished;

  /// Live progress for jobs owned by a screen (export).
  Map<String, dynamic> Function()? probe;

  /// Asks the job to stop.
  void Function()? onCancel;

  RemoteJob(this.id, this.kind);

  bool get running => state == 'running';

  String get message => _message;
  set message(String v) {
    if (v == _message) return;
    _message = v;
    updates++;
  }

  /// Progress for MCP notifications: frames for exports (total = frames + 1,
  /// the last step is finishing the file), else the count of status changes.
  (num, num?, String) progress() {
    final live = probe?.call();
    final frame = live?['frame'], frames = live?['frames'];
    if (frame is num && frames is num && frames > 0) {
      final phase = '${live?['phase'] ?? ''}';
      final done = !running || phase == 'done';
      final p = done ? frames + 1 : (phase == 'finishing' ? frames + 0.5 : frame.clamp(0, frames));
      final msg = phase == 'rendering' ? 'Rendering frame ${frame.round()} of ${frames.round()}' : (message.isEmpty ? phase : message);
      return (p, frames + 1, msg);
    }
    return (updates + (running ? 0 : 1), null, message);
  }

  void done(Object? r, {String message = 'Done'}) {
    if (!running) return;
    state = 'done';
    result = r;
    this.message = message;
    finished = DateTime.now();
  }

  void fail(Object e) {
    if (!running) return;
    state = 'failed';
    error = '$e';
    message = '$e';
    finished = DateTime.now();
  }

  void cancelled([String msg = 'Cancelled']) {
    if (!running) return;
    state = 'cancelled';
    message = msg;
    finished = DateTime.now();
  }

  Map<String, dynamic> toJson() {
    final live = probe?.call();
    return {
      'job': id,
      'kind': kind,
      'state': state,
      if (message.isNotEmpty) 'message': message,
      if (live != null) ...live,
      if (result != null) 'result': result,
      if (error != null) 'error': error,
      'seconds': ((finished ?? DateTime.now()).difference(started).inMilliseconds / 1000).round(),
    };
  }
}

class RemoteJobs {
  final List<RemoteJob> _all = [];
  int _n = 0;

  RemoteJob start(String kind) {
    final j = RemoteJob('${kind}_${++_n}', kind);
    _all.add(j);
    if (_all.length > 30) _all.removeAt(0);
    return j;
  }

  RemoteJob? byId(String id) {
    for (final j in _all) {
      if (j.id == id) return j;
    }
    return null;
  }

  RemoteJob? latest(String kind) {
    for (final j in _all.reversed) {
      if (j.kind == kind) return j;
    }
    return null;
  }

  /// A running job that blocks edits (export renders the project; the
  /// Director rebuilds it). Captions only add layers at the end.
  RemoteJob? get blocking {
    for (final j in _all.reversed) {
      if (j.running && (j.kind == 'export' || j.kind == 'director')) return j;
    }
    return null;
  }

  List<RemoteJob> get all => List.unmodifiable(_all);
}
