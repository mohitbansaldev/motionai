// win-43: Flow panel — Google Flow inside MotionAI (WebView2), so images go
// straight from a signed-in Flow page into the library: no browser download,
// no ZIP, no cloud. The page fetches each finished image itself (it is
// signed in), encodes it and posts it to the app over WebView2's own message
// channel (no localhost request, so browser Local Network Access rules do not
// apply). The app saves it to Documents\MotionAI_Flow\<folder>\ and imports
// the folder into the shared library (green screens keyed, roles from names).
//
// Claude drives it over MCP: flow_panel_open, flow_pull, flow_panel_eval,
// flow_panel_close. Windows only.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:webview_windows/webview_windows.dart';

import '../library/asset_library.dart';
import '../library/library_ops.dart';
import '../services/app_log.dart';

const String kFlowHome = 'https://flow.google.com/?hl=en';

/// Words in a Flow title that mean a person (green-screen image → char_).
const List<String> _personWords = [
  'man', 'men', 'woman', 'women', 'boy', 'girl', 'child', 'children', 'kid', 'people', 'person', 'miner', 'miners',
  'worker', 'workers', 'officer', 'officers', 'soldier', 'soldiers', 'surveyor', 'father', 'mother', 'son', 'daughter',
  'family', 'farmer', 'guard', 'king', 'queen', 'priest', 'monk', 'leader', 'figure', 'crowd', 'portrait', 'elder',
  'elderly', 'old_man', 'old_woman', 'villager', 'villagers', 'student', 'teacher', 'doctor', 'pilot', 'driver',
];

const List<String> _rolePrefixes = ['char_', 'prop_', 'plate_', 'bg_', 'fx_', 'cut_'];

/// File stem for a pulled image: keeps a role prefix already in the Flow
/// title, otherwise picks one from the image's border (green → char_/prop_,
/// black → fx_, else plate_) and the title's words.
String flowFileStem(String title, {required bool green, required bool dark}) {
  var s = title.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_').replaceAll(RegExp(r'^_+|_+$'), '');
  if (s.length > 48) s = s.substring(0, 48).replaceAll(RegExp(r'_+$'), '');
  if (s.isEmpty) s = 'image';
  for (final p in _rolePrefixes) {
    if (s.startsWith(p)) return s;
  }
  String pre;
  if (green) {
    final words = s.split('_').toSet();
    final person = _personWords.any((w) => w.contains('_') ? s.contains(w) : words.contains(w));
    pre = person ? 'char_' : 'prop_';
  } else if (dark) {
    pre = 'fx_';
  } else {
    pre = 'plate_';
  }
  return '$pre$s';
}

String _ext(String mime) => mime.contains('png')
    ? 'png'
    : mime.contains('webp')
        ? 'webp'
        : 'jpg';

/// In-page collector, installed once per page. `__mxPull.run(job, opts)`
/// scrolls Flow's grid, collects every finished image tile (title + src),
/// fetches each (4 at a time), checks its border colour and posts it as
/// base64 over window.chrome.webview.
const String _collectorJs = r'''
(() => {
  if (window.__mxPull && window.__mxPull.v === 1) return true;
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const toB64 = (blob) => new Promise((res, rej) => {
    const fr = new FileReader();
    fr.onload = () => res(String(fr.result).split(',')[1] || '');
    fr.onerror = () => rej(fr.error);
    fr.readAsDataURL(blob);
  });
  const border = async (blob) => {
    try {
      const bmp = await createImageBitmap(blob);
      const N = 16, c = new OffscreenCanvas(N, N), x = c.getContext('2d');
      x.drawImage(bmp, 0, 0, N, N);
      const d = x.getImageData(0, 0, N, N).data;
      let g = 0, k = 0, n = 0;
      for (let i = 0; i < N; i++) for (const [px, py] of [[i, 0], [i, N - 1], [0, i], [N - 1, i]]) {
        const o = (py * N + px) * 4, r = d[o], gg = d[o + 1], b = d[o + 2];
        n++;
        if (gg > 100 && gg > r * 1.3 && gg > b * 1.3) g++;
        if (r < 28 && gg < 28 && b < 28) k++;
      }
      return { green: g / n > 0.6, dark: k / n > 0.7 };
    } catch (e) { return { green: false, dark: false }; }
  };
  const scroller = () => document.querySelector('.page-container') ||
    [...document.querySelectorAll('*')].filter((e) => e.scrollHeight > e.clientHeight + 200 && /auto|scroll/.test(getComputedStyle(e).overflowY))
      .sort((a, b) => b.scrollHeight - a.scrollHeight)[0];
  const run = async (job, opts) => {
    const post = (m) => window.chrome.webview.postMessage(Object.assign({ mx: 'pull', job }, m));
    try {
      const seen = new Map();
      const grab = () => {
        for (const t of document.querySelectorAll('flow-grid-tile-container')) {
          if (t.querySelector('flow-collection-tile, flow-video-tile, flow-scene-tile')) continue;
          const img = t.querySelector('img[src]');
          if (!img || !img.src) continue;
          const holder = t.querySelector('[data-media-id]');
          const id = (holder && holder.getAttribute('data-media-id')) || img.src;
          if (!seen.has(id)) seen.set(id, { src: img.src, title: t.getAttribute('aria-label') || '' });
        }
      };
      const sc = scroller();
      if (sc) {
        sc.scrollTop = 0;
        await sleep(500);
        for (let s = 0; s < 300; s++) {
          grab();
          const before = sc.scrollTop;
          sc.scrollTop = before + sc.clientHeight * 0.8;
          await sleep(450);
          if (sc.scrollTop <= before) { grab(); break; }
        }
        sc.scrollTop = 0;
      } else grab();
      if (!seen.size) for (const i of document.querySelectorAll('img')) if (i.naturalWidth >= 300 && !seen.has(i.src)) seen.set(i.src, { src: i.src, title: i.alt || '' });
      let items = [...seen.values()];
      const want = (opts.match || []).map((m) => String(m).toLowerCase()).filter(Boolean);
      if (want.length) items = items.filter((it) => want.some((m) => it.title.toLowerCase().includes(m)));
      if (opts.limit > 0) items = items.slice(0, opts.limit);
      post({ t: 'count', n: items.length });
      let next = 0;
      const worker = async () => {
        while (next < items.length) {
          const k = next++, it = items[k];
          try {
            // win-44: the grid shows a ~512 px preview ("=s512-rw"); "=s2048" is the original.
            const full = it.src.replace(/=s\d+(-[a-z]+)*$/i, '=s2048');
            let r = await fetch(full, { credentials: 'include' });
            if (!r.ok && full !== it.src) r = await fetch(it.src, { credentials: 'include' });
            if (!r.ok) throw new Error('HTTP ' + r.status);
            const b = await r.blob();
            const bd = await border(b);
            post({ t: 'img', k, title: it.title, mime: b.type || 'image/jpeg', green: bd.green, dark: bd.dark, data: await toB64(b) });
          } catch (e) { post({ t: 'err', k, title: it.title, msg: String((e && e.message) || e) }); }
        }
      };
      await Promise.all([worker(), worker(), worker(), worker()]);
      post({ t: 'done' });
    } catch (e) { post({ t: 'fail', msg: String((e && e.message) || e) }); }
  };
  const evalJs = async (id, code) => {
    const post = (m) => window.chrome.webview.postMessage(Object.assign({ mx: 'eval', id }, m));
    try {
      const v = await (0, eval)('(async () => {' + code + '\n})()');
      let out = v;
      try { JSON.stringify(v); } catch (e) { out = String(v); }
      post({ ok: true, v: out === undefined ? null : out });
    } catch (e) { post({ ok: false, v: String((e && e.message) || e) }); }
  };
  window.__mxPull = { v: 1, run, evalJs };
  return true;
})()
''';

class FlowPanel {
  FlowPanel._();
  static final FlowPanel instance = FlowPanel._();

  static bool get supported => Platform.isWindows;

  WebviewController? _c;
  Future<WebviewController>? _starting;
  final List<StreamSubscription<Object?>> _subs = [];
  final StreamController<Map<String, dynamic>> _messages = StreamController.broadcast();
  String url = '';
  String title = '';
  bool shown = false;
  Route<void>? _route;
  int _seq = 0;

  bool get ready => _c != null;

  // win-45 >>> trusted input through WebView2's DevTools protocol
  int? _cdpPort;
  WebSocket? _ws;
  int _cdpId = 0;
  final Map<int, Completer<Map<String, dynamic>>> _cdpWait = {};

  static Future<int> _freePort() async {
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final p = s.port;
    await s.close();
    return p;
  }

  Future<WebSocket> _cdp() async {
    final open = _ws;
    if (open != null && open.readyState == WebSocket.open) return open;
    final port = _cdpPort ?? (throw StateError('Trusted input needs the Flow panel opened by this app run (restart MotionAI once after updating).'));
    final http = HttpClient();
    try {
      final req = await http.getUrl(Uri.parse('http://127.0.0.1:$port/json/list'));
      final res = await req.close();
      final list = jsonDecode(await res.transform(utf8.decoder).join()) as List;
      Map? page;
      for (final t in list) {
        if (t is Map && t['type'] == 'page' && '${t['url']}'.contains('flow.google.com')) page = t;
      }
      page ??= list.whereType<Map>().where((t) => t['type'] == 'page').firstOrNull;
      final ws = '${page?['webSocketDebuggerUrl'] ?? ''}';
      if (ws.isEmpty) throw StateError('No Flow page to control (open it with flow_panel_open).');
      final sock = await WebSocket.connect(ws);
      sock.listen((m) {
        try {
          final j = jsonDecode('$m');
          if (j is Map && j['id'] is int) _cdpWait.remove(j['id'])?.complete(Map<String, dynamic>.from(j));
        } catch (_) {}
      }, onDone: () => _ws = null, onError: (Object _) => _ws = null);
      _ws = sock;
      return sock;
    } finally {
      http.close(force: true);
    }
  }

  Future<Map<String, dynamic>> _send(String method, [Map<String, dynamic> params = const {}]) async {
    final ws = await _cdp();
    final id = ++_cdpId;
    final c = Completer<Map<String, dynamic>>();
    _cdpWait[id] = c;
    ws.add(jsonEncode({'id': id, 'method': method, 'params': params}));
    final r = await c.future.timeout(const Duration(seconds: 15), onTimeout: () {
      _cdpWait.remove(id);
      throw TimeoutException('DevTools $method timed out');
    });
    if (r['error'] != null) throw StateError('DevTools $method: ${r['error']}');
    return Map<String, dynamic>.from(r['result'] as Map? ?? const {});
  }

  Future<Object?> _eval(String expr) async {
    final r = await _send('Runtime.evaluate', {'expression': expr, 'returnByValue': true, 'awaitPromise': true});
    final v = r['result'];
    return v is Map ? v['value'] : null;
  }

  /// JS that finds one element: by aria-label (exact, then contains), visible text, or CSS selector.
  static String _finder({String? label, String? text, String? selector}) => '''(() => {
    const vis = (e) => { const r = e.getBoundingClientRect(); return r.width > 0 && r.height > 0; };
    const all = [...document.querySelectorAll(${jsonEncode(selector ?? 'button, [role=button], a, [aria-label], [role=tab], [role=switch]')})].filter(vis);
    const L = ${jsonEncode(label)}, T = ${jsonEncode(text)};
    let el = null;
    if (L) el = all.find(e => (e.getAttribute('aria-label') || '').trim() === L) || all.find(e => (e.getAttribute('aria-label') || '').toLowerCase().includes(L.toLowerCase()));
    if (!el && T) el = all.find(e => (e.innerText || '').trim() === T) || all.find(e => (e.innerText || '').toLowerCase().includes(T.toLowerCase()));
    if (!el && !L && !T) el = all[0];
    if (!el) return null;
    el.scrollIntoView({block: 'center', inline: 'center'});
    const r = el.getBoundingClientRect();
    return {x: r.x + r.width / 2, y: r.y + r.height / 2, label: el.getAttribute('aria-label'), text: (el.innerText || '').trim().slice(0, 40), pressed: el.getAttribute('aria-pressed')};
  })()''';

  /// A real mouse click (Flow accepts it) on the element found by [label] / [text] / [selector].
  Future<Map<String, dynamic>> click({String? label, String? text, String? selector}) async {
    final hit = await _eval(_finder(label: label, text: text, selector: selector));
    if (hit is! Map) throw StateError('Nothing to click for ${label ?? text ?? selector}.');
    final x = (hit['x'] as num).toDouble(), y = (hit['y'] as num).toDouble();
    await _send('Input.dispatchMouseEvent', {'type': 'mouseMoved', 'x': x, 'y': y});
    await _send('Input.dispatchMouseEvent', {'type': 'mousePressed', 'x': x, 'y': y, 'button': 'left', 'buttons': 1, 'clickCount': 1});
    await _send('Input.dispatchMouseEvent', {'type': 'mouseReleased', 'x': x, 'y': y, 'button': 'left', 'buttons': 0, 'clickCount': 1});
    return {'clicked': true, 'label': hit['label'], 'text': hit['text'], 'at': [x.round(), y.round()]};
  }

  /// A real key press; [commands] are Chromium editing commands run with it (selectAll, deleteBackward…).
  Future<void> key(String key, {int modifiers = 0, int code = 0, List<String> commands = const []}) async {
    await _send('Input.dispatchKeyEvent', {
      'type': 'rawKeyDown',
      'key': key,
      'code': key.length == 1 ? 'Key${key.toUpperCase()}' : key,
      'windowsVirtualKeyCode': code,
      'modifiers': modifiers,
      if (commands.isNotEmpty) 'commands': commands,
    });
    await _send('Input.dispatchKeyEvent', {
      'type': 'keyUp',
      'key': key,
      'code': key.length == 1 ? 'Key${key.toUpperCase()}' : key,
      'windowsVirtualKeyCode': code,
      'modifiers': modifiers,
    });
  }

  /// Types [prompt] into Flow's prompt box (replacing it), sets Agent mode, presses Start.
  /// [wait] seconds: wait until Flow finishes (the Stop button goes away).
  Future<Map<String, dynamic>> generate(String prompt, {bool? agent, int wait = 0}) async {
    await controller();
    if (agent != null) {
      final st = await _eval(_finder(label: 'Flow Agent'));
      final on = st is Map && st['pressed'] == 'true';
      if (on != agent) await click(label: 'Flow Agent');
    }
    await click(selector: '.ProseMirror');
    await key('a', modifiers: 2, code: 65, commands: const ['selectAll']); // Ctrl+A
    await key('Backspace', code: 8, commands: const ['deleteBackward']);
    await _send('Input.insertText', {'text': prompt});
    await Future<void>.delayed(const Duration(milliseconds: 400));
    Map<String, dynamic> pressed;
    try {
      pressed = await click(label: 'Start generation');
    } catch (_) {
      pressed = await click(text: 'arrow_forward');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    var running = await _eval('[...document.querySelectorAll("button")].some(b => b.getAttribute("aria-label") === "Stop")') == true;
    final sw = Stopwatch()..start();
    while (running && sw.elapsed.inSeconds < wait) {
      await Future<void>.delayed(const Duration(seconds: 4));
      running = await _eval('[...document.querySelectorAll("button")].some(b => b.getAttribute("aria-label") === "Stop")') == true;
    }
    final tail = await _eval('document.body.innerText.slice(-300)');
    return {'started': true, 'start_button': pressed, 'running': running, 'waited_seconds': sw.elapsed.inSeconds, 'page_tail': tail};
  }
  // <<< win-45

  /// The panel's WebView2, created on first use with its own persistent
  /// profile (%APPDATA%\…\MotionAI\flow_webview), so one Google sign-in stays.
  Future<WebviewController> controller() {
    final c = _c;
    if (c != null) return Future.value(c);
    return _starting ??= _create();
  }

  Future<WebviewController> _create() async {
    if (!supported) throw StateError('The Flow panel needs the Windows app.');
    final version = await WebviewController.getWebViewVersion();
    if (version == null) {
      _starting = null;
      throw StateError('Microsoft Edge WebView2 Runtime is not installed (get it from microsoft.com/edge/webview2).');
    }
    try {
      final support = await getApplicationSupportDirectory();
      final data = Directory('${support.path}${Platform.pathSeparator}flow_webview');
      await data.create(recursive: true);
      // win-45: a loopback-only DevTools port so the app can send real (trusted)
      // clicks and typing to Flow, which ignores script-made events.
      _cdpPort = await _freePort();
      await WebviewController.initializeEnvironment(
        userDataPath: data.path,
        additionalArguments: '--remote-debugging-address=127.0.0.1 --remote-debugging-port=$_cdpPort',
      );
    } catch (e) {
      // Already initialised in this run (only allowed once): fine.
      AppLog.add('info', 'flow', 'WebView2 environment: $e');
    }
    final c = WebviewController();
    try {
      await c.initialize();
    } catch (e) {
      _starting = null;
      rethrow;
    }
    await c.setBackgroundColor(const Color(0xFF0E0F13));
    await c.setPopupWindowPolicy(WebviewPopupWindowPolicy.sameWindow);
    _subs.add(c.url.listen((u) => url = u));
    _subs.add(c.title.listen((t) => title = t));
    _subs.add(c.webMessage.listen((m) {
      if (m is Map) _messages.add(Map<String, dynamic>.from(m));
    }, onError: (Object e) => AppLog.add('warning', 'flow', 'Flow panel message: $e')));
    _c = c;
    return c;
  }

  Future<void> _waitLoaded(WebviewController c, {Duration timeout = const Duration(seconds: 25)}) async {
    final done = Completer<void>();
    late final StreamSubscription<LoadingState> sub;
    sub = c.loadingState.listen((s) {
      if (s == LoadingState.navigationCompleted && !done.isCompleted) done.complete();
    });
    try {
      await done.future.timeout(timeout);
    } on TimeoutException {
      // Slow page: carry on, the caller checks the page itself.
    } finally {
      await sub.cancel();
    }
  }

  /// Opens the panel at [target] (default: Flow home; keeps the current page
  /// when it is already a Flow page and no url is given).
  Future<Map<String, dynamic>> open(NavigatorState? nav, {String? target, bool show = true}) async {
    final c = await controller();
    final want = (target ?? '').trim();
    final onFlow = url.contains('flow.google.com') || url.contains('labs.google');
    if (want.isNotEmpty || !onFlow) {
      await c.loadUrl(want.isNotEmpty ? want : kFlowHome);
      await _waitLoaded(c);
    }
    if (show && !shown && nav != null) {
      shown = true;
      final route = MaterialPageRoute<void>(
          settings: const RouteSettings(name: FlowPanelScreen.routeName), builder: (_) => const FlowPanelScreen());
      _route = route;
      unawaited(nav.push(route).whenComplete(() {
        shown = false;
        if (identical(_route, route)) _route = null;
      }));
    }
    await Future<void>.delayed(const Duration(milliseconds: 600));
    return state();
  }

  Future<Map<String, dynamic>> state() async {
    final c = _c;
    if (c == null) return {'open': false, 'hint': 'Call flow_panel_open first.'};
    Object? page;
    try {
      page = await c.executeScript('''(() => ({
        signedIn: !/accounts\\.google\\.com/.test(location.host) && !!document.querySelector('img[src*="googleusercontent"], [aria-label*="Account"], [aria-label*="Google Account"]'),
        inProject: /\\/project\\//.test(location.pathname),
        tiles: document.querySelectorAll('flow-grid-tile-container').length
      }))()''');
    } catch (_) {}
    final p = page is Map ? page : const {};
    final inProject = p['inProject'] == true;
    final onSignIn = url.contains('accounts.google.com');
    return {
      'open': true,
      'shown': shown,
      'url': url,
      'title': title,
      'in_project': inProject,
      'tiles_visible': p['tiles'] ?? 0,
      if (onSignIn) 'hint': 'Google sign-in page: the user signs in once in the Flow panel (MotionAI keeps the sign-in).',
      if (!onSignIn && !inProject) 'hint': 'Open a Flow project (flow_panel_open with its https://flow.google.com/project/… url).',
    };
  }

  /// Hides the panel (the page stays loaded, so flow_pull still works).
  Future<bool> close(NavigatorState? nav) async {
    final r = _route;
    if (r == null || nav == null || !r.isActive) return false;
    nav.removeRoute(r);
    _route = null;
    shown = false;
    return true;
  }

  Future<WebviewController> _installed() async {
    final c = _c ?? (throw StateError('The Flow panel is not open: call flow_panel_open first.'));
    await c.executeScript(_collectorJs);
    return c;
  }

  /// Runs [code] (the body of an async function; `return` a JSON value) in
  /// the Flow page and returns its result.
  Future<Object?> eval(String code, {Duration timeout = const Duration(seconds: 45)}) async {
    final c = await _installed();
    final id = 'e${++_seq}';
    final got = _messages.stream.firstWhere((m) => m['mx'] == 'eval' && m['id'] == id).timeout(timeout);
    await c.executeScript('window.__mxPull.evalJs(${jsonEncode(id)}, ${jsonEncode(code)}); true');
    final m = await got;
    if (m['ok'] != true) throw StateError('Page script failed: ${m['v']}');
    return m['v'];
  }

  /// Every finished image in the open Flow project → Documents\MotionAI_Flow\
  /// <folder>\ → the library (one kit). [match]: only titles containing one
  /// of these words; [limit]: at most this many.
  Future<Map<String, dynamic>> pull({
    required String folder,
    String? kit,
    List<String> match = const [],
    int limit = 0,
    bool import = true,
    bool removeMark = true,
    String greenScreen = 'auto',
    List<String> tags = const [],
    void Function(String status)? status,
  }) async {
    final c = await _installed();
    final safe = folder.replaceAll(RegExp(r'[^A-Za-z0-9_\- ]+'), '_').trim();
    final name = safe.isEmpty ? 'flow_${DateTime.now().millisecondsSinceEpoch}' : safe;
    final docs = await getApplicationDocumentsDirectory();
    final sep = Platform.pathSeparator;
    final dir = Directory('${docs.path}${sep}MotionAI_Flow$sep$name');
    await dir.create(recursive: true);

    final job = 'p${++_seq}';
    final sw = Stopwatch()..start();
    final saved = <String>[];
    final failed = <String>[];
    final used = <String, int>{};
    final writes = <Future<void>>[];
    var expected = -1;
    var bytes = 0;
    final finished = Completer<String?>();
    final sub = _messages.stream.where((m) => m['mx'] == 'pull' && m['job'] == job).listen((m) {
      switch (m['t']) {
        case 'count':
          expected = (m['n'] as num?)?.toInt() ?? 0;
          status?.call('Pulling $expected images…');
          break;
        case 'img':
          final data = base64Decode('${m['data'] ?? ''}');
          var stem = flowFileStem('${m['title'] ?? ''}', green: m['green'] == true, dark: m['dark'] == true);
          final n = (used[stem] ?? 0) + 1;
          used[stem] = n;
          if (n > 1) stem = '${stem}_$n';
          final file = File('${dir.path}$sep$stem.${_ext('${m['mime'] ?? ''}')}');
          bytes += data.length;
          writes.add(file.writeAsBytes(data, flush: true).then((_) {
            saved.add(file.uri.pathSegments.last);
            status?.call('Saved ${saved.length}${expected >= 0 ? ' of $expected' : ''}');
          }, onError: (Object e) => failed.add('${m['title']}: $e')));
          break;
        case 'err':
          failed.add('${m['title'] ?? 'image ${m['k']}'}: ${m['msg']}');
          break;
        case 'done':
          if (!finished.isCompleted) finished.complete(null);
          break;
        case 'fail':
          if (!finished.isCompleted) finished.complete('${m['msg']}');
          break;
      }
    });
    String? error;
    try {
      await c.executeScript('window.__mxPull.run(${jsonEncode(job)}, ${jsonEncode({'match': match, 'limit': limit})}); true');
      error = await finished.future.timeout(const Duration(minutes: 4), onTimeout: () => 'Timed out after 4 minutes.');
      await Future.wait(writes);
    } finally {
      await sub.cancel();
    }
    final pulledIn = sw.elapsedMilliseconds / 1000;
    final out = <String, dynamic>{
      'folder': dir.path,
      'found': expected < 0 ? 0 : expected,
      'saved': saved.length,
      'megabytes': (bytes / (1 << 20)).toStringAsFixed(1),
      'pull_seconds': pulledIn.toStringAsFixed(1),
      'files': (saved..sort()),
      if (failed.isNotEmpty) 'failed': failed,
      if (error != null) 'error': error,
    };
    if (import && saved.isNotEmpty) {
      status?.call('Adding ${saved.length} images to the library…');
      final lib = await AssetLibrary.shared();
      final r = await LibraryOps.importFolder(lib, {
        'path': dir.path,
        'recursive': false,
        'kit': (kit ?? '').trim().isEmpty ? name : kit,
        'green_screen': greenScreen,
        'remove_mark': removeMark,
        'tags': ['flow', ...tags],
      });
      out['library'] = r;
    }
    out['total_seconds'] = (sw.elapsedMilliseconds / 1000).toStringAsFixed(1);
    AppLog.add('info', 'flow', 'Flow pull "$name": ${saved.length} images in ${out['total_seconds']} s');
    return out;
  }
}

/// The panel the user sees (sign in once; watch what Claude does).
class FlowPanelScreen extends StatefulWidget {
  static const routeName = '/flow';
  const FlowPanelScreen({super.key});

  @override
  State<FlowPanelScreen> createState() => _FlowPanelScreenState();
}

class _FlowPanelScreenState extends State<FlowPanelScreen> {
  WebviewController? _c;
  String? _error;
  String _status = '';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    FlowPanel.instance.controller().then((c) {
      if (!mounted) return;
      setState(() => _c = c);
      if (FlowPanel.instance.url.isEmpty) c.loadUrl(kFlowHome);
    }, onError: (Object e) {
      if (mounted) setState(() => _error = '$e');
    });
  }

  Future<void> _pullAll() async {
    final ctl = TextEditingController(text: 'flow_${DateTime.now().toIso8601String().substring(0, 16).replaceAll(RegExp(r'[^0-9]'), '')}');
    final folder = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add all images to the library'),
        content: TextField(controller: ctl, autofocus: true, decoration: const InputDecoration(labelText: 'Kit / folder name')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctl.text), child: const Text('Add')),
        ],
      ),
    );
    if (folder == null || folder.trim().isEmpty || !mounted) return;
    setState(() {
      _busy = true;
      _status = 'Collecting…';
    });
    try {
      final r = await FlowPanel.instance.pull(folder: folder.trim(), status: (s) {
        if (mounted) setState(() => _status = s);
      });
      if (mounted) setState(() => _status = 'Added ${r['saved']} images in ${r['total_seconds']} s');
    } catch (e) {
      if (mounted) setState(() => _status = 'Failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    return Scaffold(
      backgroundColor: const Color(0xFF0E0F13),
      appBar: AppBar(
        backgroundColor: const Color(0xFF15161C),
        title: Row(children: [
          const Text('Google Flow', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(width: 14),
          Expanded(
            child: Text(_status, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, color: Colors.white70)),
          ),
        ]),
        actions: [
          IconButton(tooltip: 'Back', onPressed: c == null ? null : () => c.goBack(), icon: const Icon(Icons.arrow_back_rounded)),
          IconButton(tooltip: 'Reload', onPressed: c == null ? null : () => c.reload(), icon: const Icon(Icons.refresh_rounded)),
          IconButton(tooltip: 'Flow home', onPressed: c == null ? null : () => c.loadUrl(kFlowHome), icon: const Icon(Icons.home_outlined)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: FilledButton.icon(
              onPressed: c == null || _busy ? null : _pullAll,
              icon: _busy
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.download_done_rounded, size: 18),
              label: const Text('Add all to library'),
            ),
          ),
        ],
      ),
      body: _error != null
          ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!, textAlign: TextAlign.center)))
          : c == null
              ? const Center(child: CircularProgressIndicator())
              : Webview(c, permissionRequested: (url, kind, isUserInitiated) => WebviewPermissionDecision.deny),
    );
  }
}
