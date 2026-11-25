// win-30: in-memory log of app errors and notable events (newest last),
// readable by Claude through the MCP tool get_logs. Pure Dart.

class AppLogEntry {
  final DateTime time;
  final String level; // error | warning | info
  final String source; // flutter | async | export | encoder | …
  final String message;
  AppLogEntry(this.level, this.source, this.message) : time = DateTime.now();

  Map<String, dynamic> toJson() => {
        'time': time.toIso8601String(),
        'level': level,
        'source': source,
        'message': message,
      };
}

class AppLog {
  static const int capacity = 300;
  static final List<AppLogEntry> _entries = [];

  static void add(String level, String source, Object message) {
    var m = '$message';
    if (m.length > 4000) m = '${m.substring(0, 4000)}…';
    _entries.add(AppLogEntry(level, source, m));
    if (_entries.length > capacity) _entries.removeRange(0, _entries.length - capacity);
  }

  static void error(String source, Object message) => add('error', source, message);
  static void warning(String source, Object message) => add('warning', source, message);
  static void info(String source, Object message) => add('info', source, message);

  /// Newest [limit] entries (optionally only [level] and worse).
  static List<AppLogEntry> recent({int limit = 50, String? level}) {
    const rank = {'error': 0, 'warning': 1, 'info': 2};
    final max = rank[level] ?? 2;
    final out = [for (final e in _entries) if ((rank[e.level] ?? 2) <= max) e];
    return out.length <= limit ? out : out.sublist(out.length - limit);
  }

  static void clear() => _entries.clear();
}
