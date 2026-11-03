import 'dart:convert';
import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:alias_agent/services/sidecar_bridge.dart';

/// Smoke tests using the REAL sidecar DLL.  Catches:
/// - Missing DLL or dependencies (libcurl, zlib)
/// - Stack overflow from C++ overload resolution bugs
/// - FFI symbol resolution failures
/// - SSRF pre-spawn check correctness
void main() {
  // change add-context-handles：上下文接口的首参是句柄。本文件的用例共用一个
  // 真实 DLL 里的上下文；2.5 的建销用例自己另建。
  const ctx = 'unit-bridge';
  setUpAll(() async {
    await SidecarBridge.instance.ensureContext(ctx, defaultWorkspace: '.');
  });
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
      () => lib!.lookupFunction<Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>), Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>)>('read_file'),
      returnsNormally,
      reason: 'read_file symbol should resolve',
    );
    expect(
      () => lib!.lookupFunction<Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>), Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>)>('glob_file'),
      returnsNormally,
      reason: 'glob_file symbol should resolve',
    );
    expect(
      () => lib!.lookupFunction<Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>), Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>)>('grep_file'),
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
    final result = bridge.setWorkspace(ctx, '.');
    // set_workspace returns null or empty string on success
    expect(result, anyOf(isNull, isEmpty));
  });

  // =========================================================================
  // 1.4 read_file (requires set_workspace first)
  // =========================================================================
  test('readFile reads pubspec.yaml after setWorkspace', () {
    final bridge = SidecarBridge.instance;
    bridge.setWorkspace(ctx, '.');
    final result = bridge.readFile(ctx, 'pubspec.yaml');
    final parsed = jsonDecode(result);
    expect(parsed['ok'], isTrue, reason: 'read_file should succeed for pubspec.yaml');
    expect(parsed['content'], contains('alias_agent'));
  });

  // =========================================================================
  // 1.5 list_dir (requires set_workspace first)
  // =========================================================================
  test('listDir lists test/unit/ after setWorkspace', () {
    final bridge = SidecarBridge.instance;
    bridge.setWorkspace(ctx, '.');
    final result = bridge.listDir(ctx, 'test/unit');
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
      final result = await bridge.webFetch(ctx,
        jsonEncode({'url': 'http://192.168.1.1/'}),
      );
      final parsed = jsonDecode(result);
      expect(parsed['ok'], isFalse, reason: 'SSRF should block 192.168.1.1');
      expect(parsed['error'].toString().toLowerCase(),
          anyOf(contains('internal address'), contains('not allowed')));
    });

    test('blocks loopback (127.0.0.1)', () async {
      final bridge = SidecarBridge.instance;
      final result = await bridge.webFetch(ctx,
        jsonEncode({'url': 'http://127.0.0.1:8080/'}),
      );
      final parsed = jsonDecode(result);
      expect(parsed['ok'], isFalse, reason: 'SSRF should block 127.0.0.1');
      expect(parsed['error'].toString().toLowerCase(),
          anyOf(contains('internal address'), contains('not allowed')));
    });

    test('blocks file:// scheme', () async {
      final bridge = SidecarBridge.instance;
      final result = await bridge.webFetch(ctx,
        jsonEncode({'url': 'file:///etc/passwd'}),
      );
      final parsed = jsonDecode(result);
      expect(parsed['ok'], isFalse, reason: 'file:// scheme should be blocked');
      expect(parsed['error'].toString().toLowerCase(), contains('not allowed'));
    });

    test('blocks localhost hostname', () async {
      final bridge = SidecarBridge.instance;
      final result = await bridge.webFetch(ctx,
        jsonEncode({'url': 'http://localhost/admin'}),
      );
      final parsed = jsonDecode(result);
      expect(parsed['ok'], isFalse, reason: 'localhost should be blocked');
      expect(parsed['error'].toString().toLowerCase(),
          anyOf(contains('internal address'), contains('not allowed')));
    });
  });

  // =========================================================================
  // 2.5 ensureContext / disposeContext（真实 DLL，两种返回都解析）
  // =========================================================================
  group('context lifecycle (real DLL)', () {
    test('首次 created:true、第二次 created:false，且第二次不覆盖工作区', () async {
      final bridge = SidecarBridge.instance;
      const id = 'bridge-ensure';
      await bridge.disposeContext(id);  // 幂等：本用例从空状态开始

      final first = await bridge.ensureContext(id, defaultWorkspace: '.');
      expect(first, isTrue, reason: '第一次 ensure 必须报 created:true');
      expect(bridge.setWorkspace(id, '.'), anyOf(isNull, isEmpty));

      // 第二次带一个**不同**的缺省工作区：created:false ⇒ 不许覆盖。
      final second =
          await bridge.ensureContext(id, defaultWorkspace: r'C:\Windows');
      expect(second, isFalse, reason: '第二次 ensure 必须报 created:false');
      final read = jsonDecode(bridge.readFile(id, 'pubspec.yaml'));
      expect(read['ok'], isTrue,
          reason: '工作区仍是第一次设的项目根，读 pubspec.yaml 应成功');

      await bridge.disposeContext(id);
    });

    test('空名字与保留名被拒绝，且不会建出上下文', () async {
      final bridge = SidecarBridge.instance;
      expect(() => bridge.ensureContext(''), throwsA(isA<StateError>()));
      expect(() => bridge.ensureContext('no-session'),
          throwsA(isA<StateError>()));
      expect(() => bridge.ensureContext('_it_x'), throwsA(isA<StateError>()));
      // 保留名没有被建成上下文：用它调工具得到 unknown_context。
      final probe = jsonDecode(bridge.readFile('no-session', 'x.txt'));
      expect(probe['ok'], isFalse);
      expect(probe['code'], 'unknown_context');
    });

    test('销毁后重建是空状态（created:true 且没有旧工作区）', () async {
      final bridge = SidecarBridge.instance;
      const id = 'bridge-recreate';
      await bridge.disposeContext(id);
      expect(await bridge.ensureContext(id, defaultWorkspace: '.'), isTrue);
      await bridge.disposeContext(id);

      expect(await bridge.ensureContext(id), isTrue,
          reason: '销毁后重建必须报 created:true');
      final read = jsonDecode(bridge.readFile(id, 'pubspec.yaml'));
      expect(read['error'], 'No workspace set',
          reason: '新建上下文不带旧工作区');
      await bridge.disposeContext(id);
    });

    test('重复销毁幂等：第二次不产生额外副作用', () async {
      final bridge = SidecarBridge.instance;
      const id = 'bridge-dispose-twice';
      await bridge.ensureContext(id);
      await bridge.disposeContext(id);
      await bridge.disposeContext(id);  // 不抛错
      // 从未建过的名字也同样幂等
      await bridge.disposeContext('bridge-never-created');
    });
  });

  // =========================================================================
  // 3.1-3.3 get_workspace（真实 DLL + 生产与测试共用的解析入口）
  // =========================================================================
  group('get_workspace（真实 DLL）', () {
    test('按句柄读回各自的工作区：句柄原样透传、不落到主目录、互不覆盖', () async {
      final bridge = SidecarBridge.instance;
      const root = 'bridge-ws-root';
      const sub = 'bridge-ws-sub';
      await bridge.disposeContext(root);  // 幂等：从空状态开始
      await bridge.disposeContext(sub);
      await bridge.ensureContext(root, defaultWorkspace: '.');
      await bridge.ensureContext(sub, defaultWorkspace: 'test');

      final rootRead = bridge.getWorkspace(root);
      final subRead = bridge.getWorkspace(sub);
      final rootAgain = bridge.getWorkspace(root);
      debugPrint('[OBS] get_workspace root=${rootRead.workspace} '
          'sub=${subRead.workspace} rootAgain=${rootAgain.workspace}');
      expect(rootRead.ok, isTrue, reason: '新建并设过工作区的句柄必须成功');
      expect(subRead.ok, isTrue);
      expect(rootAgain.ok, isTrue);
      // 句柄被原样透传到 C++：两个句柄读到两份不同的工作区，而不是同一个固定值。
      expect(rootRead.workspace, endsWith('AliasAgent'),
          reason: '根上下文的工作区应是项目根，不可能是主目录或空串');
      expect(subRead.workspace, '${rootRead.workspace}/test',
          reason: '第二个上下文应读到项目根下的 test 目录，证明句柄透传');
      expect(subRead.workspace, isNot(rootRead.workspace));
      // 读另一个句柄之后，第一个句柄的业务值原样保留。
      expect(rootAgain.workspace, rootRead.workspace);

      await bridge.disposeContext(root);
      await bridge.disposeContext(sub);
    });

    test('未知句柄返回 unknown_context，且查询没有隐式创建上下文', () async {
      final bridge = SidecarBridge.instance;
      const missing = 'bridge-ws-missing';
      await bridge.disposeContext(missing);  // 确保从未建过

      final read = bridge.getWorkspace(missing);
      debugPrint('[OBS] get_workspace missing ok=${read.ok} code=${read.code} '
          'error=${read.error}');
      expect(read.ok, isFalse, reason: '未知句柄不许返回成功');
      expect(read.code, 'unknown_context');
      expect(read.workspace, isNull, reason: '失败时不得伪造一个工作区');

      // 查询本身没有隐式建出上下文：同名 ensure 仍是 created:true，且工作区为空。
      expect(await bridge.ensureContext(missing), isTrue,
          reason: 'get_workspace 不得隐式创建上下文');
      final created = bridge.getWorkspace(missing);
      expect(created.ok, isTrue);
      expect(created.workspace, '',
          reason: '新建上下文没有工作区，必须如实返回空串');
      await bridge.disposeContext(missing);
    });

    test('共用解析入口：非 JSON 抛 StateError，失败码原样保留', () {
      expect(() => parseWorkspaceResponse('not json at all'),
          throwsA(isA<StateError>()),
          reason: '非 JSON 必须报错，不能当成空工作区');
      expect(() => parseWorkspaceResponse('[]'), throwsA(isA<StateError>()),
          reason: '非对象 JSON 同样是解析错误');
      expect(() => parseWorkspaceResponse('{"ok":true}'),
          throwsA(isA<StateError>()),
          reason: '声称成功却没有 workspace 字符串也是解析错误');
      final failed = parseWorkspaceResponse(
          '{"ok":false,"code":"unknown_context","error":"unknown context: x"}');
      expect(failed.ok, isFalse);
      expect(failed.code, 'unknown_context');
      expect(failed.error, 'unknown context: x');
      final ok = parseWorkspaceResponse('{"ok":true,"workspace":""}');
      expect(ok.ok, isTrue);
      expect(ok.workspace, '');
    });
  });
}
