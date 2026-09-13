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
/// guarantees and that the counters stay OUT of the model-visible snapshot text.
///
/// On `raise_count`: it is a VACUOUS signal -- the worker has no writer for that
/// counter (only an init and a read), so `raise_count == 0` holds no matter what
/// the code does (already recorded under task 7.8). It is kept as a cheap
/// regression tripwire, but the ENFORCEABLE stay-hidden guard is the source scan
/// in the "no bring_to_front" test below, which is why that test also checks
/// sidecar/src -- a raise could equally be introduced on the C++ side.
///
/// On `tabs`: design 甲 FOLLOWS a newly-opened page, so multi-tab is EXPECTED.
/// `tabs == 1` is asserted only for a fresh session that navigated to one page;
/// it is NOT a general stay-hidden guarantee (see the design-甲 test below).
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
      // Stay-hidden tripwire. NOTE: raise_count has no writer in the worker, so
      // this is 0 regardless -- the enforceable guard is the source scan below.
      expect(navigateRecord['raise_count'], 0);
      // A fresh session that navigated once has exactly one tab. Design 甲 FOLLOWS
      // new tabs, so multi-tab is expected later and is NOT asserted against.
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

  test('browser_worker: no bring-to-front on either side (stay-hidden)', () {
    // `raise_count` is vacuous -- the worker has no writer for it, so it reads 0
    // no matter what the code does (task 7.8 already recorded this). The
    // ENFORCEABLE stay-hidden guard is therefore a source scan, and it must cover
    // BOTH sides: task 12.13 added a window-placement path in the worker AND a
    // window-rect lookup in the C++ sidecar, either of which could raise a window.
    final py = File('scripts/browser_worker.py').readAsStringSync();
    expect(py.contains('.bring_to_front('), isFalse,
        reason: 'stay-hidden: the worker must never raise a window');

    const raiseApis = [
      'SetForegroundWindow',
      'BringWindowToTop',
      'SetActiveWindow',
      'AttachThreadInput',
      'ShowWindow',
      'SetWindowPos',
    ];
    final scanned = <String>[];
    for (final f in Directory('sidecar/src').listSync().whereType<File>()) {
      if (!f.path.endsWith('.cpp') && !f.path.endsWith('.h')) continue;
      final text = f.readAsStringSync();
      scanned.add(f.path);
      for (final api in raiseApis) {
        expect(text.contains(api), isFalse,
            reason: 'stay-hidden: ${f.path} must not call $api (bring-to-front)');
      }
    }
    debugPrint('[OBS] bring-to-front source scan covered ${scanned.length} files: $scanned');
    expect(scanned, isNotEmpty,
        reason: 'the sidecar source scan must actually scan files, not pass vacuously');
  });

  test('browser_worker: window placement avoids the app window and stays in the work area (task 12.13)',
      () {
    // Task 12.13: the headed browser used to sit over the app window; on
    // about:blank that reads as a pure white, text-free block -- the "the window
    // went white" report. The placement must therefore keep the browser clear of
    // the app (or, when that cannot fit, full-size and mostly clear) AND inside
    // the work area. Driven directly against the worker's pure function (no
    // browser launch), so this is a fast, deterministic check.
    //
    // NOTE: an earlier revision of this comment cited "237 frames, only 10.5%".
    // That measurement has no surviving artifacts and its own sub-counts did not
    // add up, so it is NOT restated here; the round-9 review retracted it.
    final python = _probePython();
    if (python == null) {
      markTestSkipped('python unavailable');
      return;
    }

    const snippet = '''
import json, sys
sys.path.insert(0, "scripts")
import browser_worker as bw

# name, app_rect, work_area, overlap_is_expected
#
# ALL rects are PHYSICAL pixels -- the space the app window itself reports in
# (windows/runner/runner.exe.manifest declares PerMonitorV2, so GetWindowRect is
# physical). This machine's true work area is 2560x1540 at 125% DPI. Task 12.17:
# the round-8 review found the earlier cases mixed in the DPI-VIRTUALIZED
# 2048x1232 figure, which made "no room beside the app" look true when 940px are
# actually free -- a mixed-unit artifact, not geometry.
cases = [
    # A narrow app leaves room for a FULL-SIZE browser beside it -> no overlap.
    ("app-narrow",       (10, 10, 600, 720),   (0, 0, 2560, 1540), False),
    ("app-on-the-right", (1500, 10, 500, 700), (0, 0, 2560, 1540), False),
    # A 1280-wide app leaves 1272px: not enough for a full-size 1280px browser plus
    # the gap, so it must OVERLAP rather than shrink to a strip.
    #
    # HONEST NOTE on this case: under the OLD placement code this assertion did
    # hold (it returned a 750x1232 window clear of the app). It was relaxed from
    # "no overlap" to "overlap allowed" as a DELIBERATE trade -- the user's verdict
    # on the clear-but-thin 520x900 window was "still thin and long, ugly", so
    # looking like a browser now outranks never covering the app. This is a
    # disclosed loosening, not a geometry necessity.
    ("app-right",        (10, 10, 1280, 720),  (0, 0, 2560, 1540), True),
    ("no-app-rect",      None,                 (0, 0, 2560, 1540), False),
    ("no-work-area",     (10, 10, 1280, 720),  None,               False),
    ("app-fills-screen", (0, 0, 2560, 1540),   (0, 0, 2560, 1540), True),
    # Real geometry (sidecar.log: "browser: app window rect 12,12,1600,900")).
    # 940px are clear to the app's right -- still short of a full-size 1280px
    # window, so it overlaps (anchored right, app's left 1252px stays visible)
    # rather than becoming a strip.
    ("app-1600x900-real", (12, 12, 1600, 900), (0, 0, 2560, 1540), True),
]
out = []
for name, app, work, may_overlap in cases:
    x, y, w, h, mode = bw.compute_window_bounds(app, work)
    out.append({"name": name, "x": x, "y": y, "w": w, "h": h, "mode": mode,
                "may_overlap": may_overlap, "app": app, "work": work})
print(json.dumps(out))
''';

    final res = Process.runSync(python, ['-c', snippet]);
    expect(res.exitCode, 0,
        reason: 'placement probe must run; stderr: ${res.stderr}');
    final rows = (jsonDecode((res.stdout as String).trim()) as List<dynamic>)
        .cast<Map<String, dynamic>>();
    expect(rows.length, 7, reason: 'all placement cases must be evaluated');

    for (final row in rows) {
      final name = row['name'] as String;
      final mode = row['mode'] as String;
      final mayOverlap = row['may_overlap'] as bool;
      // Observable现场: print every computed placement before asserting.
      debugPrint('[OBS] placement $name -> mode=$mode '
          'bounds=${row['x']},${row['y']} ${row['w']}x${row['h']}');
      for (final k in ['x', 'y', 'w', 'h', 'mode']) {
        expect(row.containsKey(k), isTrue, reason: '$name missing $k');
      }

      if (mode == 'no-work-area') {
        expect(row['x'], isNull,
            reason: '$name: unknown screen must yield no placement (Playwright default)');
        continue;
      }

      final work = (row['work'] as List<dynamic>).cast<int>();
      final wl = work[0], wt = work[1], ww = work[2], wh = work[3];
      final x = row['x'] as int, y = row['y'] as int;
      final w = row['w'] as int, h = row['h'] as int;

      expect(x, greaterThanOrEqualTo(wl), reason: '$name: left edge inside work area');
      expect(y, greaterThanOrEqualTo(wt), reason: '$name: top edge inside work area');
      expect(x + w, lessThanOrEqualTo(wl + ww),
          reason: '$name: right edge must not run off-screen');
      expect(y + h, lessThanOrEqualTo(wt + wh),
          reason: '$name: bottom edge must not run off-screen');

      // Task 12.15 oracle: the window must read as a NORMAL browser, not a strip.
      // Task 12.13 shipped 520x900 (aspect 0.58) -- these assertions FAIL on that
      // code, which is what makes them a real oracle rather than decoration.
      final aspect = w / h;
      debugPrint('[OBS] placement $name aspect=${aspect.toStringAsFixed(2)} '
          'size=${w}x$h');
      expect(aspect, greaterThanOrEqualTo(1.0),
          reason: '$name: must not be a tall thin strip (aspect $aspect)');
      expect(aspect, lessThanOrEqualTo(2.0),
          reason: '$name: must not be an extreme letterbox (aspect $aspect)');
      expect(w, greaterThanOrEqualTo(1000),
          reason: '$name: browser width $w is too small to read');
      expect(h, greaterThanOrEqualTo(700),
          reason: '$name: browser height $h is too small to read');

      final app = row['app'] as List<dynamic>?;
      if (app != null) {
        final al = app[0] as int, at = app[1] as int;
        final aw = app[2] as int, ah = app[3] as int;
        final ox = (x + w < al + aw ? x + w : al + aw) - (x > al ? x : al);
        final oy = (y + h < at + ah ? y + h : at + ah) - (y > at ? y : at);
        final overlap = (ox > 0 ? ox : 0) * (oy > 0 ? oy : 0);
        debugPrint('[OBS] placement $name overlap_with_app=${overlap}px');
        if (mayOverlap) {
          expect(mode, 'normal',
              reason: '$name: an unavoidable overlap must be REPORTED by its mode, '
                  'not silently applied');
        } else {
          expect(overlap, 0,
              reason: '$name: the browser must not cover the app window');
        }
        if (overlap > 0) {
          // Overlapping is allowed, but the app must keep a usable slice visible --
          // that is what stops it from reading as "the whole window went white"
          // (the symptom behind task 12.1).
          final appLeftVisible = (x > al ? x : al) - al;
          debugPrint('[OBS] placement $name app_left_visible=${appLeftVisible}px');
          expect(appLeftVisible, greaterThanOrEqualTo(600),
              reason: '$name: at least 600px of the app must stay visible '
                  '(got $appLeftVisible)');
        }
      }
    }

    // The placement must actually be wired into the headed launch, and corrected
    // via CDP (measured 2026-09-11: launch flags are hints -- Chromium honored the
    // position but IGNORED the requested size, pushing the window off-screen).
    final source = File('scripts/browser_worker.py').readAsStringSync();
    // Round-10 review: bare names are satisfied by the DEFINITION line
    // (`def _placement_launch_args()`) and by a docstring mention of
    // "Browser.setWindowBounds", so deleting the actual wiring stayed green.
    // Assert the CALL SITES instead.
    expect(source.contains('args=_placement_launch_args())'), isTrue,
        reason: 'the headed launch must actually PASS the placement flags');
    expect(source.contains('self._apply_window_bounds()'), isTrue,
        reason: 'the CDP pin must actually be called after launch');
    expect(source.contains('"Browser.setWindowBounds"'), isTrue,
        reason: 'bounds must be pinned authoritatively via CDP');
  });

  test('browser_worker: placement edge cases found by the round-8 review stay fixed (task 12.18)',
      () {
    // Each case below was a REAL counterexample produced by the round-8 adversarial
    // review against the 12.15 code. They are asserted here so they cannot regress:
    //   1. beside-right could emit a NEGATIVE x (window entirely left of origin)
    //   2. beside-left could overlap the app by 8px while reporting "beside"
    //      (which the docstring defines as "no overlap")
    //   3. y was padded without clamping -> bottom edge left the work area on
    //      short screens
    //   4. tiny work areas must still yield a rect inside the work area
    final python = _probePython();
    if (python == null) {
      markTestSkipped('python unavailable');
      return;
    }

    const snippet = '''
import json, sys
sys.path.insert(0, "scripts")
import browser_worker as bw

cases = [
    ("beside-negative-x",   (-1600, 10, 1500, 900), (0, 0, 1920, 1040)),
    ("beside-left-8px-gap", (1288, 10, 500, 700),   (0, 0, 2048, 1232)),
    ("short-work-area",     (10, 10, 600, 720),     (0, 0, 2048, 700)),
    ("tiny-work-area",      (10, 10, 600, 720),     (0, 0, 800, 600)),
]
out = []
for name, app, work in cases:
    x, y, w, h, mode = bw.compute_window_bounds(app, work)
    out.append({"name": name, "x": x, "y": y, "w": w, "h": h, "mode": mode,
                "app": app, "work": work})
print(json.dumps(out))
''';

    final res = Process.runSync(python, ['-c', snippet]);
    expect(res.exitCode, 0, reason: 'edge-case probe must run: ${res.stderr}');
    final rows = (jsonDecode((res.stdout as String).trim()) as List<dynamic>)
        .cast<Map<String, dynamic>>();

    for (final row in rows) {
      final name = row['name'] as String;
      final mode = row['mode'] as String;
      final x = row['x'] as int, y = row['y'] as int;
      final w = row['w'] as int, h = row['h'] as int;
      final work = (row['work'] as List<dynamic>).cast<int>();
      final wl = work[0], wt = work[1], ww = work[2], wh = work[3];
      final app = (row['app'] as List<dynamic>).cast<int>();
      final al = app[0], at = app[1], aw = app[2], ah = app[3];

      final ox = (x + w < al + aw ? x + w : al + aw) - (x > al ? x : al);
      final oy = (y + h < at + ah ? y + h : at + ah) - (y > at ? y : at);
      final overlap = (ox > 0 ? ox : 0) * (oy > 0 ? oy : 0);
      debugPrint('[OBS] edge $name mode=$mode bounds=$x,$y ${w}x$h '
          'overlap=$overlap inside=${x >= wl && y >= wt && x + w <= wl + ww && y + h <= wt + wh}');

      // (1)+(4) never emit a rect outside the work area
      expect(x, greaterThanOrEqualTo(wl), reason: '$name: x must not be negative');
      expect(y, greaterThanOrEqualTo(wt), reason: '$name: y must not be negative');
      expect(x + w, lessThanOrEqualTo(wl + ww),
          reason: '$name: right edge must stay on-screen');
      expect(y + h, lessThanOrEqualTo(wt + wh),
          reason: '$name: bottom edge must stay on-screen');
      // (2) "beside" promises no overlap -- it must actually mean it
      if (mode == 'beside') {
        expect(overlap, 0,
            reason: '$name: mode "beside" claims no overlap, but it overlaps the app');
      }

      // Round-10 review: for `beside-negative-x` the ONLY observable difference
      // between the fixed code and the code with the `rx >= wl` guard deleted is the
      // MODE label -- _inside() clamps both axes, so x/y are non-negative either way,
      // the rect is inside the work area either way, and the app rect (-1600..-100)
      // lies wholly off-screen so the "beside means zero overlap" check passes either
      // way too. Without pinning the mode here, case (1) could regress silently.
      const expectedMode = {
        'beside-negative-x': 'normal', // guard present -> falls back to right-anchored
        'beside-left-8px-gap': 'normal', // no room on the left -> overlap, reported
        'short-work-area': 'beside',
        'tiny-work-area': 'normal',
      };
      expect(mode, expectedMode[name],
          reason: '$name: the mode label is the regression signal for this case '
              '(got $mode, want ${expectedMode[name]})');
    }

    // (5) the honest disclosure must be reachable again: 12.15 renamed the mode
    // "overlap" -> "normal" but left the guard testing the old name, so the log
    // line had become dead code.
    final source = File('scripts/browser_worker.py').readAsStringSync();
    expect(source.contains('if mode == "normal"'), isTrue,
        reason: 'the overlap disclosure must guard on the CURRENT mode name');
    expect(source.contains('if mode == "overlap"'), isFalse,
        reason: 'the stale mode name must be gone (it made the log dead code)');
  });

  test('browser_worker: a repair that silently fails must NOT be reported as fixed (task 12.24)',
      () {
    // Task 12.24(7): the read-back repair path had no guard at all -- only two
    // substring checks on the source. The dangerous case is a "repair" that
    // Chromium never applied: the old code announced success off its own
    // request value. reconcile_window_bounds() returns an explicit status, and
    // this test drives its branches with a fake CDP applier. (Round-10 review: the
    // function has FIVE statuses; the no-op guard is driven here too.)
    final python = _probePython();
    if (python == null) {
      markTestSkipped('python unavailable');
      return;
    }

    const snippet = '''
import json, sys
sys.path.insert(0, "scripts")
import browser_worker as bw

WORK = (0, 0, 2560, 1540)
INSIDE = {"left": 1011, "top": 13, "width": 1024, "height": 720}
OUTSIDE = {"left": -50, "top": 13, "width": 1024, "height": 720}
HUGE = {"left": 1580, "top": 20, "width": 3200, "height": 1800}


def must_not_be_called(*a):
    raise AssertionError("apply() must not be called for this case")


def echo(l, t, w, h):
    return {"left": l, "top": t, "width": w, "height": h}


def ignores_the_move(l, t, w, h):
    # Chromium accepted the call but kept the old geometry -- the silent failure.
    return dict(OUTSIDE)


def run(name, actual, applier):
    calls = []

    def wrapped(*a):
        calls.append(a)
        return applier(*a)

    b, status, detail = bw.reconcile_window_bounds(actual, WORK, wrapped)
    return {"name": name, "status": status, "detail": detail,
            "apply_calls": len(calls),
            "final": [b.get("left"), b.get("top"), b.get("width"), b.get("height")]}


print(json.dumps([
    run("too-large", HUGE, must_not_be_called),
    run("already-inside", INSIDE, must_not_be_called),
    run("repair-verified", OUTSIDE, echo),
    run("repair-silently-fails", OUTSIDE, ignores_the_move),
    run("no-op-empty", {}, must_not_be_called),
    run("no-op-no-size", {"left": 5, "top": 5}, must_not_be_called),
]))
''';

    final res = Process.runSync(python, ['-c', snippet]);
    expect(res.exitCode, 0,
        reason: 'reconcile probe must run; stderr: ${res.stderr}');
    final rows = (jsonDecode((res.stdout as String).trim()) as List<dynamic>)
        .cast<Map<String, dynamic>>();
    expect(rows.length, 6, reason: 'all six cases must be driven');

    final byName = {for (final r in rows) r['name'] as String: r};
    for (final r in rows) {
      debugPrint('[OBS] reconcile ${r['name']} -> status=${r['status']} '
          'apply_calls=${r['apply_calls']} final=${r['final']}');
    }

    // Bigger than the work area: no repair is possible, so it must SAY so rather
    // than pretend a repair happened (and must not waste a CDP round-trip).
    expect(byName['too-large']!['status'], 'too-large');
    expect(byName['too-large']!['apply_calls'], 0,
        reason: 'an impossible repair must not be attempted');
    // Already inside: verified, no round-trip.
    expect(byName['already-inside']!['status'], 'ok');
    expect(byName['already-inside']!['apply_calls'], 0);
    // Outside and the move took effect: repaired + the FINAL rect is inside.
    expect(byName['repair-verified']!['status'], 'repaired');
    expect(byName['repair-verified']!['apply_calls'], 1);
    final fixed = (byName['repair-verified']!['final'] as List<dynamic>).cast<int>();
    expect(fixed[0], greaterThanOrEqualTo(0),
        reason: 'the repaired rect must actually be inside the work area');
    // Outside and the move was IGNORED: this is the regression tripwire. The old
    // code logged "verified ... inside the logical work area" here.
    expect(byName['repair-silently-fails']!['status'], 'unrepaired',
        reason: 'a repair that did not take effect must never be reported as ok');
    expect(byName['repair-silently-fails']!['apply_calls'], 1,
        reason: 'the repair must have been ATTEMPTED, else the case proves nothing');
    // An unusable CDP read-back must be reported as unverified, not silently pass.
    expect(byName['no-op-empty']!['status'], 'no-op');
    expect(byName['no-op-empty']!['apply_calls'], 0);
    expect(byName['no-op-no-size']!['status'], 'no-op');
    expect(byName['no-op-no-size']!['apply_calls'], 0);
    final workerSource = File('scripts/browser_worker.py').readAsStringSync();
    expect(workerSource.contains('the placement is NOT verified'), isTrue,
        reason: 'the caller must WARN on the no-op status instead of logging nothing');

    // And every branch name must be distinct -- one collapsed status would make
    // the assertions above trivially satisfiable.
    final statuses = rows.map((r) => r['status']).toSet();
    expect(statuses.length, 5,
        reason: 'five distinct outcomes expected '
            '(ok / too-large / repaired / unrepaired / no-op), got $statuses');
  });

  test('browser_worker: the OS-measured rect, not the CDP read-back, decides (task 12.27)',
      () {
    // Found during the round-10 review: one live run's CDP read-back reported
    // 1011,13 1025x721 logical while Windows reported the real window as
    // 1620x1010 physical -- Chromium's 1296x808 default, 324px off a 2560px screen.
    // The read-back said "fine", so this decision must be made on the OS rect.
    final python = _probePython();
    if (python == null) {
      markTestSkipped('python unavailable');
      return;
    }

    const snippet = '''
import json, sys
sys.path.insert(0, "scripts")
import browser_worker as bw

REQUESTED = (1011, 13, 1024, 720)  # the rect the product PASSES (logical)
S = 1.25
cases = [
    # name, real OS rect (physical), expected-mismatch
    ("correct", (1264, 16, 1280, 900), False),
    ("observed-failure", (1264, 16, 1620, 1010), True),
    ("wrong-position", (2000, 16, 1280, 900), True),
    ("too-narrow", (1264, 16, 900, 900), True),
    ("no-measurement", None, False),
]
out = []
for name, real, want in cases:
    bad, why = bw.os_rect_mismatch(REQUESTED, S, real)
    out.append({"name": name, "mismatch": bad, "why": why, "want": want})
print(json.dumps(out))
''';

    final res = Process.runSync(python, ['-c', snippet]);
    expect(res.exitCode, 0,
        reason: 'os-rect probe must run; stderr: ${res.stderr}');
    final rows = (jsonDecode((res.stdout as String).trim()) as List<dynamic>)
        .cast<Map<String, dynamic>>();
    expect(rows.length, 5);
    for (final r in rows) {
      debugPrint('[OBS] os-rect ${r['name']} mismatch=${r['mismatch']} '
          'why=${r['why']}');
      expect(r['mismatch'], r['want'],
          reason: "${r['name']}: ${r['why']}");
    }
    // Round-11 review: the probe must drive the SAME tuple the product passes.
    // It used to drive the CDP read-back (1025x721) while the product passes the
    // requested rect (1024x720) -- a 1px difference that changes the reason string.
    final observed = rows.firstWhere((r) => r['name'] == 'observed-failure');
    expect(observed['why'], 'size 1620x1010 vs expected 1280x900 physical',
        reason: 'the oracle must reproduce what the product actually prints');
    // The re-pin path and the OS measurement must be wired into the worker, not
    // merely defined. Round-11 review: asserting the LOG STRING alone stayed green
    // when the re-pin call was deleted, so assert the CALL SITE too.
    final src = File('scripts/browser_worker.py').readAsStringSync();
    expect(src.contains('real = real_window_rect(child_process_pids())'), isTrue,
        reason: 'the worker must MEASURE the OS rect after pinning');
    expect(src.contains('os_rect_mismatch((lx, ly, lw, lh), scale, real)'), isTrue,
        reason: 'the mismatch check must compare against the REQUESTED rect');
    expect(src.contains('b = apply(lx, ly, lw, lh)'), isTrue,
        reason: 'a mismatch must actually RE-PIN (deleting the call must fail here)');
    expect(src.contains('re-pinning once'), isTrue,
        reason: 'a mismatch must trigger a re-pin, not just a log line');
    // The first live run after 12.27 landed found NO window with a direct-children
    // scan (Edge's launcher makes the real browser process a grandchild), so the
    // descendant walk is part of the fix, not an optimisation.
    expect(src.contains('int(e.th32ParentProcessID)'), isTrue,
        reason: 'the scan must walk the process tree, not just direct children');
  });

  test('browser_worker: DPI-awareness init falls back and fails closed (task 12.31)', () {
    // Round-12 review: the HRESULT-checked DPI init had NO test at any layer, and on
    // this machine the first SetProcessDpiAwareness(2) always succeeds -- so the old
    // exception-only version and the new one were behaviourally indistinguishable and
    // a regression would keep every suite green. ctypes does NOT raise on a failed
    // HRESULT, so the failure path has to be simulated.
    final python = _probePython();
    if (python == null) {
      markTestSkipped('python unavailable');
      return;
    }

    const snippet = '''
import ctypes, json, sys
sys.path.insert(0, "scripts")
import browser_worker as bw

REAL_WINDDLL = ctypes.windll
_REAL_LOG = bw._log


class Fn:
    def __init__(self, ret, raises=False):
        self.ret = ret
        self.raises = raises
        self.calls = 0

    def __call__(self, *a):
        self.calls += 1
        if self.raises:
            raise OSError("api missing")
        return self.ret


class Obj:
    pass


def install(shcore_ret, user32_ret, shcore_raises=False):
    sh, u, w = Obj(), Obj(), Obj()
    sh.SetProcessDpiAwareness = Fn(shcore_ret, shcore_raises)
    u.SetProcessDPIAware = Fn(user32_ret)
    w.shcore = sh
    w.user32 = u
    ctypes.windll = w
    return sh, u


out = []

# 1) shcore returns a failure HRESULT (no exception) -> the user32 fallback must run.
bw._DPI_INIT_DONE = False
sh, u = install(-2147024891, 1)
bw._make_dpi_aware()
out.append({"name": "hresult-fail-fallback-ok", "done": bw._DPI_INIT_DONE,
            "user32_calls": u.SetProcessDPIAware.calls, "rect": "n/a"})

# 2) BOTH fail -> not aware, and a measurement must FAIL CLOSED rather than hand back
#    a virtualized rect that callers would print as "physical".
#    NOTE: asserting only `rect is None` here is NOT enough -- with both APIs stubbed
#    failing, the window enumeration also fails and returns None anyway, so the
#    assertion passes even with the guard deleted (found by mutation testing: the
#    mutation stayed green). Capture the log and require the REFUSAL to be the reason.
bw._DPI_INIT_DONE = False
sh, u = install(-2147024891, 0)
bw._make_dpi_aware()
logs = []
bw._log = lambda m: logs.append(m)
rect = bw.real_window_rect([1, 2, 3])
bw._log = _REAL_LOG
out.append({"name": "both-fail", "done": bw._DPI_INIT_DONE,
            "user32_calls": u.SetProcessDPIAware.calls, "rect": rect,
            "refusal_logged": any("refusing to measure" in m for m in logs)})

# 3) shcore raises (API absent) -> the except branch must fall back.
bw._DPI_INIT_DONE = False
sh, u = install(0, 1, shcore_raises=True)
bw._make_dpi_aware()
out.append({"name": "exception-fallback-ok", "done": bw._DPI_INIT_DONE,
            "user32_calls": u.SetProcessDPIAware.calls, "rect": "n/a"})

ctypes.windll = REAL_WINDDLL
print(json.dumps(out))
''';

    final res = Process.runSync(python, ['-c', snippet]);
    expect(res.exitCode, 0,
        reason: 'dpi probe must run; stderr: ${res.stderr}');
    final rows = (jsonDecode((res.stdout as String).trim()) as List<dynamic>)
        .cast<Map<String, dynamic>>();
    final byName = {for (final r in rows) r['name'] as String: r};
    for (final r in rows) {
      debugPrint('[OBS] dpi-init ${r['name']} done=${r['done']} '
          'user32_calls=${r['user32_calls']} rect=${r['rect']} '
          'refusal_logged=${r['refusal_logged']}');
    }
    expect(byName['hresult-fail-fallback-ok']!['done'], isTrue,
        reason: 'a failed HRESULT must trigger the SetProcessDPIAware fallback');
    expect(byName['hresult-fail-fallback-ok']!['user32_calls'], 1);
    expect(byName['both-fail']!['done'], isFalse,
        reason: 'when both APIs fail the flag must NOT claim awareness');
    expect(byName['both-fail']!['rect'], isNull,
        reason: 'with no DPI awareness the measurement must fail closed, not return '
            'a virtualized rect labelled physical');
    expect(byName['both-fail']!['refusal_logged'], isTrue,
        reason: 'the refusal must be the REASON the measurement returned nothing -- '
            'otherwise deleting the guard would still leave this case green');
    expect(byName['exception-fallback-ok']!['done'], isTrue);
    expect(byName['exception-fallback-ok']!['user32_calls'], 1);
  });

  test('browser_worker: rect drift found AFTER launch is re-pinned, and bounded (task 12.33)',
      () {
    // The launch-time check cannot see a size that a window manager re-applies later
    // (first paint / session restore), and one observed run kept the wrong size for
    // its whole life. So the check now runs after every navigation-class op -- and it
    // must be BOUNDED (never re-pin forever) and must NOT read a missing measurement
    // as drift. Injected sample sequences drive the policy.
    final python = _probePython();
    if (python == null) {
      markTestSkipped('python unavailable');
      return;
    }

    const snippet = '''
import json, sys
sys.path.insert(0, "scripts")
import browser_worker as bw

REQ = (1011, 13, 1024, 720)   # the logical rect the product actually passes
S = 1.25
GOOD = (1264, 16, 1280, 900)
DRIFT = (1264, 16, 1620, 1010)


def run(name, samples):
    repins = 0
    actions = []
    for real in samples:
        status, why = bw.classify_rect_check(REQ, S, real)
        act = bw.plan_rect_check(status)
        actions.append(act)
        if act == "repin":
            repins += 1
    return {"name": name, "actions": actions, "repins": repins}


print(json.dumps([
    run("always-good", [GOOD, GOOD, GOOD]),
    run("first-drift", [GOOD, DRIFT, GOOD]),
    run("repeated-drift", [DRIFT, DRIFT, DRIFT, DRIFT, DRIFT]),
    run("no-measurement", [None, None]),
    run("drift-then-unknown", [DRIFT, None, GOOD]),
]))
''';

    final res = Process.runSync(python, ['-c', snippet]);
    expect(res.exitCode, 0,
        reason: 'rect-check probe must run; stderr: ${res.stderr}');
    final rows = (jsonDecode((res.stdout as String).trim()) as List<dynamic>)
        .cast<Map<String, dynamic>>();
    final byName = {for (final r in rows) r['name'] as String: r};
    for (final r in rows) {
      debugPrint('[OBS] rect-check ${r['name']} actions=${r['actions']} '
          'repins=${r['repins']} max=${r['max_repins']}');
    }

    // (1) healthy session: nothing happens (and no log spam).
    expect(byName['always-good']!['actions'], ['ok', 'ok', 'ok']);
    expect(byName['always-good']!['repins'], 0);
    // (2) one drift -> EXACTLY one re-pin, then back to normal.
    expect(byName['first-drift']!['actions'], ['ok', 'repin', 'ok'],
        reason: 'a single drift must produce exactly one re-pin');
    // (3) persistent drift -> EVERY drift is repaired. An earlier version stopped
    // after two repairs and only warned; a product review showed that strands the
    // real window at Chromium's default size, 324px off-screen, for the rest of the
    // worker's life. There is no loop to bound: at most one re-pin per op.
    final repeated = (byName['repeated-drift']!['actions'] as List<dynamic>).cast<String>();
    expect(repeated.every((a) => a == 'repin'), isTrue,
        reason: 'every drift must be repaired -- no budget that strands the window '
            '(got $repeated)');
    expect(byName['repeated-drift']!['repins'], repeated.length);
    // (4) a MISSING measurement is not drift -- this is the false-positive guard.
    expect(byName['no-measurement']!['actions'], ['skip', 'skip']);
    expect(byName['no-measurement']!['repins'], 0,
        reason: 'an unmeasurable check must never be treated as a drifted window');
    // (5) drift, then unmeasurable, then fine: one re-pin only.
    expect(byName['drift-then-unknown']!['actions'], ['repin', 'skip', 'ok']);
    expect(byName['drift-then-unknown']!['repins'], 1);

    // The host must actually CALL the policy after navigation-class ops, and the
    // launch-time path must still exist (this is a widening, not a replacement).
    final src = File('scripts/browser_worker.py').readAsStringSync();
    expect(src.contains('self._recheck_window_bounds("navigate")'), isTrue,
        reason: 'navigate must re-check the real window rect');
    expect(src.contains('self._recheck_window_bounds("click")'), isTrue,
        reason: 'a click can navigate, so it must re-check too');
    // A product review proved `type` can open a page too (a form input whose submit
    // opens a new tab): the window drifted with no rect line at all.
    expect(src.contains('self._recheck_window_bounds("type")'), isTrue,
        reason: 'type can open a page, so it must re-check as well');
    expect(src.contains('plan_rect_check(status)'), isTrue,
        reason: 'the host must go through the policy, not re-pin directly');
    expect(src.contains('MAX_PLACEMENT_REPINS'), isFalse,
        reason: 'no budget that can strand the window off-screen (review finding)');
    expect(src.contains('self._apply_window_bounds()'), isTrue,
        reason: 'the launch-time pin must remain');

    // A re-pin must be MEASURED, not asserted: the first live run that exercised this
    // ended at "re-pinning (1/2)" with no evidence it worked.
    const outcome = '''
import json, sys
sys.path.insert(0, "scripts")
import browser_worker as bw

REQ = (1011, 13, 1024, 720)
S = 1.25
print(json.dumps([
    {"name": "fixed", "text": bw.describe_repin_outcome(REQ, S, (1264, 16, 1280, 900))},
    {"name": "still-broken", "text": bw.describe_repin_outcome(REQ, S, (1264, 16, 1620, 1010))},
    {"name": "unmeasurable", "text": bw.describe_repin_outcome(REQ, S, None)},
]))
''';
    final res2 = Process.runSync(python, ['-c', outcome]);
    expect(res2.exitCode, 0, reason: 'repin-outcome probe: ${res2.stderr}');
    final o = {
      for (final r in (jsonDecode((res2.stdout as String).trim()) as List<dynamic>)
          .cast<Map<String, dynamic>>())
        r['name'] as String: r['text'] as String
    };
    for (final e in o.entries) {
      debugPrint('[OBS] repin-outcome ${e.key} -> ${e.value}');
    }
    expect(o['fixed'], 'now matches');
    expect(o['still-broken'], startsWith('STILL MISMATCHED'),
        reason: 'a re-pin that did not take effect must be reported as such');
    expect(o['unmeasurable'], contains('not measurable'),
        reason: 'an unmeasurable post-re-pin state is not a success');
    expect(src.contains('window rect after re-pin'), isTrue,
        reason: 'the host must log the post-re-pin measurement');
  });

  test('browser_worker: the HOST actually re-pins when the rect drifted (task 12.33)',
      () {
    // A product review showed the previous wiring checks were substring reads: turning
    // _recheck_window_bounds into a no-op (call sites intact) left the whole suite
    // green. This drives the real method in-process with injected collaborators, so
    // neutralising it fails here.
    final python = _probePython();
    if (python == null) {
      markTestSkipped('python unavailable');
      return;
    }

    const snippet = '''
import json, sys
sys.path.insert(0, "scripts")
import browser_worker as bw

GOOD = (1264, 16, 1280, 900)
DRIFT = (1264, 16, 1620, 1010)

bw._APP_RECT = (12, 12, 1600, 900)
bw._get_work_area = lambda: (0, 0, 2560, 1540)
bw._DPI_SCALE_CACHE = 1.25          # pin the scale: machine-independent
bw._make_dpi_aware = lambda: None
bw.child_process_pids = lambda *a, **k: [4242]

calls = {"rect": 0}


def fake_rect(_pids):
    calls["rect"] += 1
    return DRIFT if calls["rect"] == 1 else GOOD     # drifted, then repaired


bw.real_window_rect = fake_rect

logs = []
bw._log = lambda m: logs.append(str(m))

sent = []


class Rec:
    def send(self, method, params=None):
        if method == "Browser.getWindowForTarget":
            return {"windowId": 7, "bounds": {}}
        sent.append((method, params))
        return {}

    def detach(self):
        pass


class Ctx:
    def new_cdp_session(self, page):
        return Rec()


class FakeSession:
    _page = object()
    _context = Ctx()
    _placement_repins = 0


bw.BrowserSession._recheck_window_bounds(FakeSession(), "navigate")
print(json.dumps({
    "writes": [p for m, p in sent if m == "Browser.setWindowBounds"],
    "other_methods": [m for m, _ in sent if m != "Browser.setWindowBounds"],
    "rect_calls": calls["rect"],
    "logs": logs,
}))
''';

    final res = Process.runSync(python, ['-c', snippet]);
    expect(res.exitCode, 0, reason: 'host probe must run: ${res.stderr}');
    final r = jsonDecode((res.stdout as String).trim()) as Map<String, dynamic>;
    debugPrint('[OBS] host repin: writes=${r['writes']} rectCalls=${r['rect_calls']} '
        'logs=${r['logs']}');

    final writes = (r['writes'] as List<dynamic>).cast<Map<String, dynamic>>();
    expect(writes.length, 1,
        reason: 'a drift must produce EXACTLY ONE CDP placement write (this is what a '
            'no-op _recheck_window_bounds would fail)');
    final bounds = writes.single['bounds'] as Map<String, dynamic>;
    expect(bounds['left'], 1011);
    expect(bounds['top'], 13);
    expect(bounds['width'], 1024);
    expect(bounds['height'], 720);
    expect(bounds['windowState'], 'normal');
    expect(r['rect_calls'], 2,
        reason: 'the host must MEASURE twice: once to detect, once to verify the repair');
    final logs = (r['logs'] as List<dynamic>).cast<String>().join('\n');
    expect(logs.contains('re-pinning'), isTrue, reason: 'the drift must be logged');
    expect(logs.contains('now matches'), isTrue,
        reason: 'the repair must be logged as MEASURED, not assumed');
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
