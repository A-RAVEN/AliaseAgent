import 'dart:convert';
import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alias_agent/services/sidecar_bridge.dart';

/// Smoke tests using the REAL sidecar DLL.  Catches:
/// - Missing DLL or dependencies (libcurl, zlib)
/// - Stack overflow from C++ overload resolution bugs
/// - FFI symbol resolution failures
void main() {
  test('sidecar DLL loads via DynamicLibrary.open', () {
    DynamicLibrary? lib;
    String lastError = '';
    for (final path in ['sidecar.dll', r'build\windows\x64\runner\Debug\sidecar.dll']) {
      try { lib = DynamicLibrary.open(path); break; }
      on ArgumentError catch (e) { lastError = e.message; }
    }
    expect(lib, isNotNull,
        reason: 'Cannot load sidecar.dll. $lastError');
  });

  test('ensureSearchInfra returns ok without hanging', () {
    final bridge = SidecarBridge.instance;
    final result = bridge.ensureSearchInfra('{}');
    final parsed = jsonDecode(result);
    expect(parsed['ok'], isTrue);
  });

  test('getSearchProviders returns JSON', () {
    final bridge = SidecarBridge.instance;
    final result = bridge.getSearchProviders();
    expect(result, isNotEmpty);
    final parsed = jsonDecode(result);
    expect(parsed, isA<List>());
  });
}
