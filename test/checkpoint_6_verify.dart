import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

typedef ReadFileNative = Pointer<Utf8> Function(Pointer<Utf8> path);
typedef ReadFileDart = Pointer<Utf8> Function(Pointer<Utf8> path);

typedef ListDirNative = Pointer<Utf8> Function(Pointer<Utf8> path);
typedef ListDirDart = Pointer<Utf8> Function(Pointer<Utf8> path);

typedef SetWorkspaceNative = Pointer<Utf8> Function(Pointer<Utf8> path);
typedef SetWorkspaceDart = Pointer<Utf8> Function(Pointer<Utf8> path);

DynamicLibrary _open() {
  if (Platform.isWindows) return DynamicLibrary.open('sidecar.dll');
  if (Platform.isMacOS) return DynamicLibrary.open('libsidecar.dylib');
  if (Platform.isLinux) return DynamicLibrary.open('libsidecar.so');
  throw UnsupportedError('Unsupported platform');
}

void main() {
  final lib = _open();
  final readFileFn = lib.lookupFunction<ReadFileNative, ReadFileDart>('read_file');
  final listDirFn = lib.lookupFunction<ListDirNative, ListDirDart>('list_dir');
  final setWsFn = lib.lookupFunction<SetWorkspaceNative, SetWorkspaceDart>('set_workspace');

  // Create a temp workspace with known contents
  final tmpDir = Directory.systemTemp.createTempSync('aliasagent_cp6_');
  final wsPath = tmpDir.path.replaceAll('\\', '/');
  print('Workspace: $wsPath');

  // Create test files and directories
  File('$wsPath/hello.txt').writeAsStringSync('Hello from workspace!');
  File('$wsPath/binary.bin').writeAsBytesSync([0x00, 0x01, 0x02, 0xFF, 0xFE]);
  Directory('$wsPath/subdir').createSync();
  File('$wsPath/subdir/nested.txt').writeAsStringSync('nested content');

  // Set workspace
  final wsErrPtr = setWsFn(wsPath.toNativeUtf8());
  final wsErr = wsErrPtr.toDartString();
  assert(wsErr.isEmpty, 'set_workspace should succeed, got: "$wsErr"');
  print('[F] PASS: set_workspace "$wsPath" → ok');

  // ---------- A: read_file normal ----------
  {
    final result = readFileFn('hello.txt'.toNativeUtf8()).toDartString();
    final json = jsonDecode(result) as Map<String, dynamic>;
    assert(json['ok'] == true, 'read_file hello.txt should succeed');
    assert(json['content'] == 'Hello from workspace!', 'Wrong content: ${json['content']}');
    print('[A] PASS: read_file "hello.txt" → "${json['content']}"');
  }

  // ---------- B: read_file missing ----------
  {
    final result = readFileFn('nonexistent.txt'.toNativeUtf8()).toDartString();
    final json = jsonDecode(result) as Map<String, dynamic>;
    assert(json['ok'] == false, 'read_file nonexistent should fail');
    assert((json['error'] as String).contains('File not found'), 'Wrong error: ${json['error']}');
    print('[B] PASS: read_file "nonexistent.txt" → error="${json['error']}"');
  }

  // ---------- C: read_file outside workspace ----------
  {
    final outside = Platform.isWindows ? 'C:/Windows/System32/drivers/etc/hosts' : '/etc/hosts';
    // Use absolute path to bypass workspace
    final result = readFileFn(outside.toNativeUtf8()).toDartString();
    final json = jsonDecode(result) as Map<String, dynamic>;
    assert(json['ok'] == false, 'read_file outside workspace should fail');
    assert((json['error'] as String).contains('Access denied'), 'Wrong error: ${json['error']}');
    print('[C] PASS: read_file "$outside" → "${json['error']}"');

    // Also test with ../../../ style path
    // This test verifies canonical resolution prevents escape
    final result2 = readFileFn('../../../Windows/explorer.exe'.toNativeUtf8()).toDartString();
    final json2 = jsonDecode(result2) as Map<String, dynamic>;
    assert(json2['ok'] == false, 'read_file ../../../ should fail: got $result2');
    final err2 = json2['error'] as String;
    assert(err2.contains('Access denied') || err2.contains('File not found'),
        'Expected denied/not-found for ../../../: $err2');
    print('[C] PASS: read_file "../../../..." → "$err2"');
  }

  // ---------- D: list_dir normal ----------
  {
    final result = listDirFn('.'.toNativeUtf8()).toDartString();
    final json = jsonDecode(result) as Map<String, dynamic>;
    assert(json['ok'] == true, 'list_dir . should succeed');
    final entries = json['entries'] as List;
    assert(entries.isNotEmpty, 'Should have entries');
    final names = entries.map((e) => e['name'] as String).toSet();
    final types = <String, String>{for (var e in entries) e['name'] as String: e['type'] as String};
    assert(names.contains('hello.txt'), 'Should contain hello.txt');
    assert(names.contains('subdir'), 'Should contain subdir');
    assert(types['hello.txt'] == 'file', 'hello.txt should be file');
    assert(types['subdir'] == 'directory', 'subdir should be directory');
    print('[D] PASS: list_dir "." → ${entries.length} entries: $names');
  }

  // ---------- E: list_dir outside workspace ----------
  {
    final outside = Platform.isWindows ? 'C:/Windows' : '/etc';
    final result = listDirFn(outside.toNativeUtf8()).toDartString();
    final json = jsonDecode(result) as Map<String, dynamic>;
    assert(json['ok'] == false, 'list_dir outside should fail');
    assert((json['error'] as String).contains('Access denied'), 'Wrong error: ${json['error']}');
    print('[E] PASS: list_dir "$outside" → "${json['error']}"');
  }

  // ---------- F: set_workspace changes scope ----------
  {
    // Change workspace to a different tmp dir
    final tmp2 = Directory.systemTemp.createTempSync('aliasagent_cp6_ws2_');
    final ws2 = tmp2.path.replaceAll('\\', '/');
    File('$ws2/other.txt').writeAsStringSync('other workspace');

    // Set new workspace
    final errPtr = setWsFn(ws2.toNativeUtf8());
    final err = errPtr.toDartString();
    assert(err.isEmpty, 'set_workspace to ws2 should succeed, got "$err"');

    // Now read_file from old workspace should fail (relative to new workspace)
    final result = readFileFn('hello.txt'.toNativeUtf8()).toDartString();
    final json = jsonDecode(result) as Map<String, dynamic>;
    assert(json['ok'] == false, 'hello.txt should not be in ws2');
    assert((json['error'] as String).contains('File not found'), 'Expected not found in ws2: ${json['error']}');

    // But file in ws2 works
    final result2 = readFileFn('other.txt'.toNativeUtf8()).toDartString();
    final json2 = jsonDecode(result2) as Map<String, dynamic>;
    assert(json2['ok'] == true, 'other.txt should be in ws2');
    assert(json2['content'] == 'other workspace', 'Wrong content');

    print('[F] PASS: set_workspace switches scope → old file not found, new file ok');

    // Restore original workspace
    setWsFn(wsPath.toNativeUtf8());
    tmp2.deleteSync(recursive: true);
  }

  // Cleanup
  tmpDir.deleteSync(recursive: true);

  print('');
  print('=== Checkpoint 6 A/B/C/D/E/F complete ===');
}
