import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

/// Reads exact-size blocks (e.g. one raw RGBA frame) from a byte stream such
/// as a process's stdout. Pauses the stream when more than [highWater]
/// bytes are buffered so a fast decoder can't fill the memory.
class ByteQueue {
  final int highWater;
  final ListQueue<Uint8List> _chunks = ListQueue();
  int _length = 0;
  bool _done = false;
  Object? _error;
  Completer<void>? _wait;
  late final StreamSubscription<List<int>> _sub;

  ByteQueue(Stream<List<int>> stream, {this.highWater = 64 << 20}) {
    _sub = stream.listen(_onData, onError: (Object e) {
      _error = e;
      _wake();
    }, onDone: () {
      _done = true;
      _wake();
    });
  }

  int get buffered => _length;
  bool get isDone => _done && _length == 0;

  void _onData(List<int> d) {
    if (d.isEmpty) return;
    final u = d is Uint8List ? d : Uint8List.fromList(d);
    _chunks.add(u);
    _length += u.length;
    if (_length > highWater && !_sub.isPaused) _sub.pause();
    _wake();
  }

  void _wake() {
    final w = _wait;
    _wait = null;
    w?.complete();
  }

  /// Exactly [n] bytes, or null if the stream ended first.
  Future<Uint8List?> read(int n) async {
    while (_length < n && !_done) {
      if (_error != null) throw _error!;
      if (_sub.isPaused) _sub.resume();
      _wait = Completer<void>();
      await _wait!.future;
    }
    if (_length < n) return null;
    final Uint8List out;
    final first = _chunks.first;
    if (first.length == n) {
      out = _chunks.removeFirst();
    } else if (first.length > n) {
      out = Uint8List.fromList(Uint8List.sublistView(first, 0, n));
      _chunks.removeFirst();
      _chunks.addFirst(Uint8List.sublistView(first, n));
    } else {
      out = Uint8List(n);
      var o = 0;
      while (o < n) {
        final c = _chunks.removeFirst();
        final take = c.length < n - o ? c.length : n - o;
        out.setRange(o, o + take, c);
        o += take;
        if (take < c.length) _chunks.addFirst(Uint8List.sublistView(c, take));
      }
    }
    _length -= n;
    if (_sub.isPaused && _length <= highWater) _sub.resume();
    return out;
  }

  /// Everything until the stream ends.
  Future<Uint8List> readAll() async {
    while (!_done) {
      if (_error != null) throw _error!;
      if (_sub.isPaused) _sub.resume();
      _wait = Completer<void>();
      await _wait!.future;
    }
    final b = BytesBuilder(copy: false);
    for (final c in _chunks) {
      b.add(c);
    }
    _chunks.clear();
    _length = 0;
    return b.takeBytes();
  }

  Future<void> cancel() async {
    _done = true;
    _chunks.clear();
    _length = 0;
    _wake();
    await _sub.cancel();
  }
}
