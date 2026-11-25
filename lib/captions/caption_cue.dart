import '../core/model/layer.dart' show WordTiming;

export '../core/model/layer.dart' show WordTiming;

/// One on-screen caption: a few timed words, split into lines, with some
/// words marked for emphasis. Times are composition seconds.
class CaptionCue {
  final List<WordTiming> words;

  /// Indices of words that begin a new line (never 0), ascending.
  List<int> lineStarts;

  /// Indices of emphasised words.
  Set<int> emphasis;

  /// Explicit cue times; default to the first word start / last word end.
  double? _start, _end;

  CaptionCue(this.words, {List<int>? lineStarts, Set<int>? emphasis, double? start, double? end})
      : lineStarts = lineStarts ?? [],
        emphasis = emphasis ?? {},
        _start = start,
        _end = end;

  double get start => _start ?? (words.isEmpty ? 0 : words.first.start);
  set start(double v) => _start = v;
  double get end => _end ?? (words.isEmpty ? start : words.last.end);
  set end(double v) => _end = v;
  double get duration => end - start;

  /// The words of each line.
  List<List<WordTiming>> get lines {
    final out = <List<WordTiming>>[];
    var from = 0;
    for (final s in [...lineStarts.where((i) => i > 0 && i < words.length), words.length]) {
      if (s > from) out.add(words.sublist(from, s));
      from = s;
    }
    if (out.isEmpty) out.add(const []);
    return out;
  }

  /// Word index ranges of each line: (first, endExclusive).
  List<(int, int)> get lineRanges {
    final out = <(int, int)>[];
    var from = 0;
    for (final s in [...lineStarts.where((i) => i > 0 && i < words.length), words.length]) {
      if (s > from) out.add((from, s));
      from = s;
    }
    return out;
  }

  /// Lines joined with "\n", words with spaces.
  String get text => lines.map((l) => l.map((w) => w.word).join(' ')).join('\n');

  /// Text on one line.
  String get flatText => words.map((w) => w.word).join(' ');

  /// Moves the cue (and its words) by [dt] seconds.
  void shift(double dt) {
    for (final w in words) {
      w.start += dt;
      w.end += dt;
    }
    if (_start != null) _start = _start! + dt;
    if (_end != null) _end = _end! + dt;
  }

  CaptionCue copy() => CaptionCue(
        [for (final w in words) WordTiming(w.word, w.start, w.end)],
        lineStarts: List.of(lineStarts),
        emphasis: Set.of(emphasis),
        start: _start,
        end: _end,
      );

  @override
  String toString() => 'CaptionCue(${start.toStringAsFixed(2)}–${end.toStringAsFixed(2)} "${text.replaceAll('\n', ' / ')}")';
}
