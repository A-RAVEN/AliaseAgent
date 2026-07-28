import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:alias_agent/services/sidecar_bridge.dart';

/// Integration tests using the REAL sidecar DLL (not FakeSidecar).
/// Verifies end-to-end FFI call sequences with real file I/O.
void main() {
  late SidecarBridge bridge;

  setUpAll(() {
    bridge = SidecarBridge.instance;
    bridge.setWorkspace('.');
  });

  // =========================================================================
  // 3.1 read_file integration
  // =========================================================================
  test('read_file returns correct content for a real file', () {
    final result = bridge.readFile('pubspec.yaml');
    final parsed = jsonDecode(result);
    expect(parsed['ok'], isTrue);

    final content = parsed['content'] as String;
    expect(content, contains('name: alias_agent'));
    expect(content, contains('flutter'));
  });

  // =========================================================================
  // 3.2 list_dir integration
  // =========================================================================
  test('list_dir returns files and directories with correct format', () {
    final result = bridge.listDir('lib');
    final parsed = jsonDecode(result);
    expect(parsed['ok'], isTrue);

    final content = parsed['content'] as String;
    final entries = jsonDecode(content) as List;
    expect(entries, isNotEmpty);

    // lib/ should contain main.dart
    final names = entries.map((e) => e['name'] as String).toList();
    expect(names, contains('main.dart'));
  });

  // =========================================================================
  // 3.3 Tool execution sequence
  // =========================================================================
  test('set_workspace → read_file → list_dir work in sequence without corruption', () {
    // Re-set workspace
    final wsResult = bridge.setWorkspace('.');
    expect(wsResult, anyOf(isNull, isEmpty));

    // read_file
    final readResult = bridge.readFile('pubspec.yaml');
    final readParsed = jsonDecode(readResult);
    expect(readParsed['ok'], isTrue);

    // list_dir
    final listResult = bridge.listDir('test');
    final listParsed = jsonDecode(listResult);
    expect(listParsed['ok'], isTrue);

    // Verify no state corruption — read_file still works after list_dir
    final readAgain = bridge.readFile('pubspec.yaml');
    final readAgainParsed = jsonDecode(readAgain);
    expect(readAgainParsed['ok'], isTrue);
    expect(readAgainParsed['content'], contains('alias_agent'));
  });
}
