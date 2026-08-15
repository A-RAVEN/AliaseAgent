import 'dart:convert';
import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alias_agent/services/sidecar_bridge.dart';

/// Smoke tests using the REAL sidecar DLL.  Catches:
/// - Missing DLL or dependencies (libcurl, zlib)
/// - Stack overflow from C++ overload resolution bugs
/// - FFI symbol resolution failures
/// - SSRF pre-spawn check correctness
void main() {
  // =========================================================================
  // 1.1 DLL load
  // =========================================================================
  test('sidecar DLL loads via DynamicLibrary.open', () {
    DynamicLibrary? lib;
    String lastError = '';
    for (final path in ['sidecar.dll', r'build\windows\x64\runner\Debug\sidecar.dll']) {
      try { lib = DynamicLibrary.open(path); break; }
      on ArgumentError catch (e) { lastError = e.message; }
    }
    expect(lib, isNotNull,
        reason: 'Cannot load sidecar.dll. $lastError');

    // Verify key symbols resolve
    expect(
      () => lib!.lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>('ping'),
      returnsNormally,
      reason: 'ping symbol should resolve',
    );
    expect(
      () => lib!.lookupFunction<Pointer<Utf8> Function(Pointer<Utf8>), Pointer<Utf8> Function(Pointer<Utf8>)>('read_file'),
      returnsNormally,
      reason: 'read_file symbol should resolve',
    );
    expect(
      () => lib!.lookupFunction<Pointer<Utf8> Function(Pointer<Utf8>), Pointer<Utf8> Function(Pointer<Utf8>)>('glob_file'),
      returnsNormally,
      reason: 'glob_file symbol should resolve',
    );
    expect(
      () => lib!.lookupFunction<Pointer<Utf8> Function(Pointer<Utf8>), Pointer<Utf8> Function(Pointer<Utf8>)>('grep_file'),
      returnsNormally,
      reason: 'grep_file symbol should resolve',
    );
  });

  // =========================================================================
  // 1.2 ping
  // =========================================================================
  test('ping returns pong', () {
    DynamicLibrary? lib;
    for (final path in ['sidecar.dll', r'build\windows\x64\runner\Debug\sidecar.dll']) {
      try { lib = DynamicLibrary.open(path); break; }
      on ArgumentError { /* try next */ }
    }
    expect(lib, isNotNull, reason: 'Cannot load sidecar.dll');

    final pingFn = lib!.lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>('ping');
    final resultPtr = pingFn();
    final result = resultPtr.toDartString();
    expect(result, equals('pong'));
  });

  // =========================================================================
  // 1.3 set_workspace
  // =========================================================================
  test('setWorkspace returns without crash', () {
    final bridge = SidecarBridge.instance;
    final result = bridge.setWorkspace('.');
    // set_workspace returns null or empty string on success
    expect(result, anyOf(isNull, isEmpty));
  });

  // =========================================================================
  // 1.4 read_file (requires set_workspace first)
  // =========================================================================
  test('readFile reads pubspec.yaml after setWorkspace', () {
    final bridge = SidecarBridge.instance;
    bridge.setWorkspace('.');
    final result = bridge.readFile('pubspec.yaml');
    final parsed = jsonDecode(result);
    expect(parsed['ok'], isTrue, reason: 'read_file should succeed for pubspec.yaml');
    expect(parsed['content'], contains('alias_agent'));
  });

  // =========================================================================
  // 1.5 list_dir (requires set_workspace first)
  // =========================================================================
  test('listDir lists test/unit/ after setWorkspace', () {
    final bridge = SidecarBridge.instance;
    bridge.setWorkspace('.');
    final result = bridge.listDir('test/unit');
    final parsed = jsonDecode(result);
    expect(parsed['ok'], isTrue, reason: 'list_dir should succeed for test/unit/');
    final content = parsed['content'] as String;
    expect(content, contains('sidecar_bridge_test.dart'));
  });

  // =========================================================================
  // 1.6 ensure_search_infra (already existed)
  // =========================================================================
  test('ensureSearchInfra returns ok without hanging', () {
    final bridge = SidecarBridge.instance;
    final result = bridge.ensureSearchInfra('{}');
    final parsed = jsonDecode(result);
    expect(parsed['ok'], isTrue);
  });

  // =========================================================================
  // 1.7 get_search_providers (already existed)
  // =========================================================================
  test('getSearchProviders returns JSON', () {
    final bridge = SidecarBridge.instance;
    final result = bridge.getSearchProviders();
    expect(result, isNotEmpty);
    final parsed = jsonDecode(result);
    expect(parsed, isA<List>());
  });

  // =========================================================================
  // 2.1-2.4 Web Fetch SSRF pre-spawn checks (offline, no network needed)
  // =========================================================================
  group('web_fetch SSRF pre-spawn checks', () {
    test('blocks literal private IPv4 (192.168.1.1)', () async {
      final bridge = SidecarBridge.instance;
      final result = await bridge.webFetch(
        jsonEncode({'url': 'http://192.168.1.1/'}),
      );
      final parsed = jsonDecode(result);
      expect(parsed['ok'], isFalse, reason: 'SSRF should block 192.168.1.1');
      expect(parsed['error'].toString().toLowerCase(),
          anyOf(contains('internal address'), contains('not allowed')));
    });

    test('blocks loopback (127.0.0.1)', () async {
      final bridge = SidecarBridge.instance;
      final result = await bridge.webFetch(
        jsonEncode({'url': 'http://127.0.0.1:8080/'}),
      );
      final parsed = jsonDecode(result);
      expect(parsed['ok'], isFalse, reason: 'SSRF should block 127.0.0.1');
      expect(parsed['error'].toString().toLowerCase(),
          anyOf(contains('internal address'), contains('not allowed')));
    });

    test('blocks file:// scheme', () async {
      final bridge = SidecarBridge.instance;
      final result = await bridge.webFetch(
        jsonEncode({'url': 'file:///etc/passwd'}),
      );
      final parsed = jsonDecode(result);
      expect(parsed['ok'], isFalse, reason: 'file:// scheme should be blocked');
      expect(parsed['error'].toString().toLowerCase(), contains('not allowed'));
    });

    test('blocks localhost hostname', () async {
      final bridge = SidecarBridge.instance;
      final result = await bridge.webFetch(
        jsonEncode({'url': 'http://localhost/admin'}),
      );
      final parsed = jsonDecode(result);
      expect(parsed['ok'], isFalse, reason: 'localhost should be blocked');
      expect(parsed['error'].toString().toLowerCase(),
          anyOf(contains('internal address'), contains('not allowed')));
    });
  });
}
