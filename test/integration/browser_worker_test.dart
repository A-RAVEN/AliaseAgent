import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

/// Worker-layer tests for scripts/browser_worker.py (add-browser-tool).
///
/// Spawns the persistent Playwright worker DIRECTLY (bypasses the C++ sidecar)
/// and drives browser_navigate / browser_click / browser_type / browser_snapshot.
/// It reads the worker's stderr `browser-record:` lines to assert the stay-hidden
/// guarantees: raise_count == 0 (never bring_to_front), single tab (tabs == 1),
/// and that the counters stay OUT of the model-visible snapshot text.
///
/// Requires a usable Python + Playwright + Edge/Chromium; auto-skips otherwise
/// (external/unavailable, TESTING.md §3.2).
void main() {
  Process? proc;
  StreamSubscription<String>? stdoutSub;
  StreamSubscription<String>? stderrSub;
  final sentLines = <String>[];
  final pendingReads = <Completer<String>>[];
  final records = <Map<String, dynamic>>[];
  var unavailable = false;

  setUp(() async {
    final python = _probePython();
    if (python == null) {
      unavailable = true;
      return;
    }
    final script = _resolveScript();
    if (script == null) {
      unavailable = true;
      return;
    }
    final p = await Process.start(python, [script.path]);
    proc = p;
    // stdout: one response line per command; complete the OLDEST pending read.
    stdoutSub = p.stdout.transform(utf8.decoder).transform(LineSplitter()).listen((line) {
      if (line.trim().isEmpty) return;
      if (pendingReads.isNotEmpty) {
        pendingReads.removeAt(0).complete(line);
      } else {
        sentLines.add(line); // unexpected extra — buffer defensively
      }
    });
    stderrSub = p.stderr.transform(utf8.decoder).transform(LineSplitter()).listen((line) {
      if (line.startsWith('browser-record: ')) {
        try {
          records.add(jsonDecode(line.substring('browser-record: '.length)) as Map<String, dynamic>);
        } catch (_) {}
      }
    });
  });

  tearDown(() async {
    try { proc?.stdin.close(); } catch (_) {}
    await stdoutSub?.cancel();
    await stderrSub?.cancel();
    try { proc?.kill(); } catch (_) {}
    try { await proc?.exitCode.timeout(const Duration(seconds: 5)); } catch (_) {}
    proc = null;
    records.clear();
    pendingReads.clear();
    sentLines.clear();
  });

  Future<String> send(Map<String, dynamic> cmd) async {
    // [OBS] emit the actual command before asserting, so a failure is attributable.
    debugPrint('[OBS] worker cmd -> ${jsonEncode(cmd)}');
    proc!.stdin.writeln(jsonEncode(cmd));
    proc!.stdin.flush();
    final completer = Completer<String>();
    pendingReads.add(completer);
    return completer.future.timeout(const Duration(seconds: 45),
        onTimeout: () => '{"ok":false,"error":"worker response timeout"}');
  }

  test('browser_worker: available probe reports present', () async {
    if (unavailable) {
      markTestSkipped('python/browser_worker.py unavailable');
      return;
    }
    final resp = jsonDecode(await send({'cmd': 'available'}));
    debugPrint('[OBS] worker available -> ${jsonEncode(resp)}');
    expect(resp['ok'], isTrue);
    expect(resp['available'], isTrue);
  });

  test('browser_worker: navigate/click/type/snapshot persist + stay-hidden', () async {
    if (unavailable) {
      markTestSkipped('python/browser_worker.py unavailable');
      return;
    }
    const html = "<html><body><h1>Hello Browser</h1><input id='q'>"
        "<button id='b'>Go</button><p id='p1'>Alpha</p>"
        "<script>document.getElementById('b').addEventListener('click',"
        "function(){document.getElementById('p1').textContent='Clicked';})</script>"
        '</body></html>';
    final url = 'data:text/html,${Uri.encodeComponent(html)}';

    // navigate
    var r = jsonDecode(await send({'cmd': 'navigate', 'url': url}));
    debugPrint('[OBS] navigate result -> ${jsonEncode(r)}');
    expect(r['ok'], isTrue);
    expect((r['snapshot'] as String).contains('Hello Browser'), isTrue);
    // The model-visible response (worker stdout) must NOT carry the per-call
    // counters — they live only in the stderr browser-record channel (the worker
    // builds this response without them; a leak would land in main.dart's content).
    for (final k in ['raise_count', 'popup_closed', 'download_denied',
        'permission_denied', 'tabs']) {
      expect(r.containsKey(k), isFalse,
          reason: 'counter "$k" leaked into the model-visible snapshot content');
    }

    // type (fill #q)
    r = jsonDecode(await send({'cmd': 'type', 'selector': '#q', 'text': 'hi there'}));
    debugPrint('[OBS] type result -> ${jsonEncode(r)}');
    expect(r['ok'], isTrue);

    // click #b -> #p1 text becomes 'Clicked'
    r = jsonDecode(await send({'cmd': 'click', 'selector': '#b'}));
    debugPrint('[OBS] click result -> ${jsonEncode(r)}');
    expect(r['ok'], isTrue);
    expect((r['snapshot'] as String).contains('Clicked'), isTrue);

    // snapshot (re-read live)
    r = jsonDecode(await send({'cmd': 'snapshot'}));
    debugPrint('[OBS] snapshot result -> ${jsonEncode(r)}');
    expect(r['ok'], isTrue);
    expect((r['snapshot'] as String).trim(), isNotEmpty);

    // Allow the stderr records to arrive before asserting counters.
    await Future<void>.delayed(const Duration(milliseconds: 300));

    // [OBS] dump ALL fetched records BEFORE asserting, so a missing record is
    // attributable (TESTING.md §3.1: a failure must be traceable to the channel).
    debugPrint('[OBS] browser-record lines received: ${records.length}');
    for (final r in records) {
      debugPrint('[OBS] record -> ${jsonEncode(r)}');
    }
    final navigateRecord = records.where((e) => e['tool'] == 'navigate').firstOrNull;
    expect(navigateRecord, isNotNull, reason: 'expected a browser-record line');
    if (navigateRecord != null) {
      debugPrint('[OBS] navigate record -> ${jsonEncode(navigateRecord)}');
      // Stay-hidden: the tool never bring_to_front (the record reports the count).
      expect(navigateRecord['raise_count'], 0);
      // Single tab reuse.
      expect(navigateRecord['tabs'], 1);
    }
  });

  test('browser_worker: click a target=_blank link FOLLOWS the new tab (design 甲)', () async {
    if (unavailable) {
      markTestSkipped('python/browser_worker.py unavailable');
      return;
    }
    // A page whose result link opens a new tab (target=_blank). Design 甲: the
    // worker must FOLLOW that tab (make it the active page), so the snapshot
    // returns the LANDING page's content, not the original page's. Original
    // single-tab close is removed; tabs>1 is expected. A real http server is used
    // (NOT a data: URL href) because Chromium does not navigate a new tab to a
    // data: URL — a target=_blank data: href stays about:blank and would never
    // produce a readable landing page, so the follow can't be observed.
    final srv = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final base = 'http://127.0.0.1:${srv.port}';
    srv.listen((req) {
      final path = req.uri.path;
      final body = path == '/landing'
          ? "<html><body><h1>LANDING</h1><p>real result content</p></body></html>"
          : "<html><body><h1>Results</h1>"
              "<a id='r' target=_blank href='/landing'>result link</a>"
              '</body></html>';
      req.response
        ..statusCode = 200
        ..headers.contentType = ContentType.html
        ..write(body)
        ..close();
    });
    try {
      var r = jsonDecode(await send({'cmd': 'navigate', 'url': '$base/'}));
      debugPrint('[OBS] navigate -> ${jsonEncode(r)}');
      expect(r['ok'], isTrue);
      expect((r['snapshot'] as String).contains('Results'), isTrue);

      r = jsonDecode(await send({'cmd': 'click', 'selector': '#r'}));
      debugPrint('[OBS] click result link -> ${jsonEncode(r)}');
      expect(r['ok'], isTrue);
      // The worker followed the new tab: the snapshot is the LANDING page, not the
      // original "Results" page. (The model-visible response does not carry the
      // counters, so tabs/adopted_tabs are read from the record channel below.)
      final snap = (r['snapshot'] as String? ?? '');
      expect(snap.contains('LANDING'), isTrue,
          reason: 'after clicking a target=_blank result, the worker must FOLLOW the '
              'new tab and snapshot the landing page, not the original results page');

      await Future<void>.delayed(const Duration(milliseconds: 300));
      debugPrint('[OBS] browser-record lines received: ${records.length}');
      for (final rec in records) {
        debugPrint('[OBS] record -> ${jsonEncode(rec)}');
      }
      final clickRec = records.where((e) => e['tool'] == 'click').firstOrNull;
      expect(clickRec, isNotNull, reason: 'expected a click browser-record');
      if (clickRec != null) {
        // Design 甲: the click followed a new tab (browser_opened/adopted_tabs > 0)
        // and multi-tab is expected (tabs may be > 1). This replaces the old
        // single-tab "popup_closed>0 && tabs==1" assertion.
        expect(clickRec['browser_opened'] as int, greaterThan(0),
            reason: 'the browser must have recorded the opened tab');
        expect(clickRec['adopted_tabs'] as int, greaterThan(0),
            reason: 'the click must have FOLLOWED the opened tab');
        expect(clickRec['tabs'] as int, greaterThanOrEqualTo(2));
      }
    } finally {
      await srv.close(force: true);
    }
  });

  test('browser_worker: download is denied (no file persists)', () async {
    if (unavailable) {
      markTestSkipped('python/browser_worker.py unavailable');
      return;
    }
    // A page with a real <a download> link -> clicking it fires the download
    // event; the worker's _on_download cancels it and increments download_denied.
    const dl = "<body><a id='d' download href='data:text/plain,hello'>dl</a></body>";
    final url = 'data:text/html,${Uri.encodeComponent(dl)}';

    var r = jsonDecode(await send({'cmd': 'navigate', 'url': url}));
    expect(r['ok'], isTrue);
    r = jsonDecode(await send({'cmd': 'click', 'selector': '#d'}));
    debugPrint('[OBS] download click -> ${jsonEncode(r)}');
    expect(r['ok'], isTrue);

    await Future<void>.delayed(const Duration(milliseconds: 300));
    debugPrint('[OBS] browser-record lines received: ${records.length}');
    for (final rec in records) {
      debugPrint('[OBS] record -> ${jsonEncode(rec)}');
    }
    final clickRec = records.where((e) => e['tool'] == 'click').firstOrNull;
    expect(clickRec, isNotNull, reason: 'expected a click browser-record');
    if (clickRec != null) {
      expect(clickRec['download_denied'] as int, greaterThan(0),
          reason: 'the download must be denied (cancelled, no file persisted)');
    }
  });

  test('browser_worker: worker source has no bring_to_front call (stay-hidden)', () {
    // A counter for "times we raised" is vacuous (nothing ever raises), so the
    // enforceable stay-hidden guard is a source-level check: the worker must not
    // contain any `.bring_to_front(` call (a future raise would add one and fail).
    final source = File('scripts/browser_worker.py').readAsStringSync();
    expect(source.contains('.bring_to_front('), isFalse,
        reason: 'stay-hidden: the worker must never raise a window');
  });
}

String? _probePython() {
  for (final p in ['python', 'python3']) {
    try {
      final res = Process.runSync(p, ['--version']);
      if (res.exitCode == 0) return p;
    } catch (_) {}
  }
  return null;
}

File? _resolveScript() {
  final f = File('scripts/browser_worker.py');
  return f.existsSync() ? f : null;
}
