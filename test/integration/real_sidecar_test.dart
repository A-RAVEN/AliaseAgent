import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:alias_agent/services/sidecar_bridge.dart';

/// Integration tests using the REAL sidecar DLL (not FakeSidecar).
/// Verifies end-to-end FFI call sequences with real file I/O.
void main() {
  late SidecarBridge bridge;

  setUpAll(() {
    bridge = SidecarBridge.instance;
    bridge.setWorkspace('.');
    // Clean up test files from previous runs
    for (final f in ['_test_write_new.txt', '_test_edit.txt', '_test_edit2.txt', '_test_edit3.txt']) {
      try { File(f).deleteSync(); } catch (_) {}
    }
  });

  tearDownAll(() {
    for (final f in ['_test_write_new.txt', '_test_edit.txt', '_test_edit2.txt', '_test_edit3.txt']) {
      try { File(f).deleteSync(); } catch (_) {}
    }
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

  // =========================================================================
  // 3.4 write_file integration
  // =========================================================================
  test('write_file creates a new file and returns created:true', () {
    final result = bridge.writeFile('{"path":"_test_write_new.txt","content":"hello from write_file"}');
    final parsed = jsonDecode(result);
    expect(parsed['ok'], isTrue);
    expect(parsed['created'], isTrue);
    expect(parsed['bytes_written'], greaterThan(0));
  });

  test('write_file overwrites existing file and returns created:false', () {
    final result = bridge.writeFile('{"path":"_test_write_new.txt","content":"overwritten content"}');
    final parsed = jsonDecode(result);
    expect(parsed['ok'], isTrue);
    expect(parsed['created'], isFalse);
  });

  // =========================================================================
  // 3.5 edit_file integration
  // =========================================================================
  test('edit_file exact match replaces text and returns replacements:1', () {
    // First create a file to edit
    bridge.writeFile('{"path":"_test_edit.txt","content":"line one\\nline two\\nline three\\n"}');
    final result = bridge.editFile(
        '{"path":"_test_edit.txt","old_text":"line two","new_text":"line TWO"}');
    final parsed = jsonDecode(result);
    expect(parsed['ok'], isTrue);
    expect(parsed['replacements'], 1);

    // Verify the edit
    final readResult = bridge.readFile('{"path":"_test_edit.txt"}');
    final readParsed = jsonDecode(readResult);
    expect(readParsed['content'], contains('line TWO'));
    expect(readParsed['content'], isNot(contains('line two')));
  });

  test('edit_file rejects empty old_text', () {
    bridge.writeFile('{"path":"_test_edit2.txt","content":"some content\\n"}');
    final result = bridge.editFile(
        '{"path":"_test_edit2.txt","old_text":"","new_text":"replacement"}');
    final parsed = jsonDecode(result);
    expect(parsed['ok'], isFalse);
    expect(parsed['error'], contains('old_text must not be empty'));
  });

  test('edit_file returns diagnostic when no match found', () {
    bridge.writeFile('{"path":"_test_edit3.txt","content":"hello world\\n"}');
    final result = bridge.editFile(
        '{"path":"_test_edit3.txt","old_text":"nonexistent text","new_text":"replacement"}');
    final parsed = jsonDecode(result);
    expect(parsed['ok'], isFalse);
    expect(parsed['error'], 'old_text not found in file');
    expect(parsed.containsKey('diagnosis'), isTrue);
  });
}
