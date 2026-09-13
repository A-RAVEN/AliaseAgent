import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

/// Guards against the failure mode that cost a full debugging cycle on 2026-09-12:
/// `flutter test` loads the DLL by the BARE NAME `sidecar.dll`
/// (see `lib/services/sidecar_bridge.dart`), which resolves to the REPO ROOT copy.
///
/// The project DOES have a step that refreshes that copy -- `run.bat` step [3/5]
/// "Refreshing Debug sidecar and dependency DLLs to project root" -- and the failure
/// came from bypassing it (`cmake --build` + `flutter test` directly). The cost of that
/// bypass was 15 confusing `Failed to lookup symbol 'browser_available'` errors that
/// read like a code regression.
///
/// So this test states the invariant that step maintains, and names the standalone
/// command to restore it. It SKIPS when there is no built DLL to compare against
/// (fresh clone, C++ not built yet) -- it must never produce noise it cannot justify.
void main() {
  test('the sidecar DLL loaded by the suite is the newest build (else: sync it)', () {
    final root = Directory.current.path;
    final loaded = File('$root${Platform.pathSeparator}sidecar.dll');

    final candidates = [
      'sidecar/build/windows/Debug/sidecar.dll',
      'build/windows/x64/runner/Debug/sidecar.dll',
      'sidecar/build/windows/Release/sidecar.dll',
      'build/windows/x64/runner/Release/sidecar.dll',
    ].map((p) => File('$root${Platform.pathSeparator}'
        '${p.replaceAll('/', Platform.pathSeparator)}')).where((f) => f.existsSync());

    if (candidates.isEmpty) {
      markTestSkipped('no built sidecar.dll on disk -- nothing to compare against');
      return;
    }
    if (!loaded.existsSync()) {
      // Bare-name load would fail anyway; sidecar_bridge_test reports that case.
      markTestSkipped('no sidecar.dll at the repo root -- nothing to compare');
      return;
    }

    final newest = candidates.reduce((a, b) =>
        a.lastModifiedSync().isAfter(b.lastModifiedSync()) ? a : b);
    final newestBytes = newest.readAsBytesSync();
    final loadedBytes = loaded.readAsBytesSync();

    debugPrint('[OBS] dll-freshness loaded=${loaded.path} '
        '(${loadedBytes.length} bytes, ${loaded.lastModifiedSync()})');
    debugPrint('[OBS] dll-freshness newest=${newest.path} '
        '(${newestBytes.length} bytes, ${newest.lastModifiedSync()})');

    expect(loadedBytes.length == newestBytes.length &&
            _sameBytes(loadedBytes, newestBytes),
        isTrue,
        reason: 'The DLL this suite loads (repo root) is NOT the newest build '
            '(${newest.path}). Every real-DLL test will fail with confusing '
            '"Failed to lookup symbol" errors instead of telling you this. '
            'Fix it with:  powershell -NoProfile -File scripts\\sync_sidecar_dll.ps1');
  });
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
