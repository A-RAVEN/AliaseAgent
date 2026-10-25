import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/services/sidecar_bridge.dart';

/// `read_spill` 的往返（change `spill-large-tool-output`，tasks 1.2）。
///
/// 契约（见 `specs/ffi-bridge` 与 `specs/tool-output-spill`）：`offset` 与 `limit`
/// 的单位都是**字节**，读回的内容必须与 spill 文件里对应区间**逐字节相同**。
///
/// 夹具：在真实的 spill 根目录下建一个 `_it_` 前缀的会话目录，写一份 200000 字节
/// 的确定性内容（第 i 个字节 = i % 251，ASCII 范围内，避免 JSON 转义干扰），
/// 用例结束删掉该目录。内容里每个字节都能反推位置，所以"读错了哪一段"能直接看出来。
void main() {
  final bridge = SidecarBridge.instance;

  /// spill 根目录，与产品一致：`~/.aliasagent/spill/`。
  final home = Platform.environment['USERPROFILE'] ??
      Platform.environment['HOME'] ??
      '';
  late Directory sessionDir;

  setUpAll(() {
    expect(home.isNotEmpty, isTrue, reason: '拿不到用户主目录就没法定位 spill 根');
    sessionDir = Directory('$home/.aliasagent/spill/_it_roundtrip_$pid');
    if (sessionDir.existsSync()) sessionDir.deleteSync(recursive: true);
    sessionDir.createSync(recursive: true);
  });

  tearDownAll(() {
    try {
      if (sessionDir.existsSync()) sessionDir.deleteSync(recursive: true);
    } catch (_) {
      // 清理失败不影响判据
    }
  });

  /// 200000 字节的确定性内容 + 落盘，返回引用（绝对路径）。
  String writeFixture() {
    final bytes = Uint8List(200000);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = 0x20 + (i % 95); // 可打印 ASCII，不含控制字符与引号转义问题
    }
    final file = File('${sessionDir.path}/probe.txt');
    file.writeAsBytesSync(bytes, flush: true);
    expect(file.lengthSync(), 200000, reason: '夹具文件必须正好 200000 字节');
    return file.path;
  }

  test('取 (offset: 50000, limit: 1000) 与文件对应区间逐字节相同', () async {
    final ref = writeFixture();
    final fileBytes = File(ref).readAsBytesSync();
    // ignore: avoid_print
    print('[read_spill] 引用 = $ref（文件 ${fileBytes.length} 字节），'
        '请求 offset=50000 limit=1000');

    final raw = bridge.readSpill(jsonEncode({
      'ref': ref,
      'offset': 50000,
      'limit': 1000,
    }));
    final r = jsonDecode(raw) as Map<String, dynamic>;
    // ignore: avoid_print
    print('[read_spill] 实测读数: ok=${r['ok']} bytes_read=${r['bytes_read']} '
        'total_bytes=${r['total_bytes']} text长度=${(r['text'] as String?)?.length} '
        'error=${r['error']}');

    expect(r['ok'], isTrue, reason: '合法区间必须读成功：$raw');
    final text = r['text'] as String;
    expect(utf8.encode(text).length, 1000, reason: 'limit=1000 字节');
    expect(r['bytes_read'], 1000);
    expect(r['total_bytes'], 200000);

    // 逐字节相同：读回内容 == 文件 [50000, 51000)
    final expected = fileBytes.sublist(50000, 51000);
    expect(utf8.encode(text), equals(expected),
        reason: '读回的 1000 字节必须与文件对应区间逐字节相同');
  });

  test('不传 limit 时按 preview_chars × 2 取（默认 2000）', () async {
    final ref = writeFixture();
    final fileBytes = File(ref).readAsBytesSync();
    final raw =
        bridge.readSpill(jsonEncode({'ref': ref, 'offset': 100}));
    final r = jsonDecode(raw) as Map<String, dynamic>;
    // ignore: avoid_print
    print('[read_spill] 实测读数（省 limit）: ok=${r['ok']} '
        'bytes_read=${r['bytes_read']} total_bytes=${r['total_bytes']}');

    expect(r['ok'], isTrue, reason: '合法区间必须读成功：$raw');
    expect(r['bytes_read'], 2000, reason: 'limit 省略时取 preview_chars × 2');
    expect(utf8.encode(r['text'] as String),
        equals(fileBytes.sublist(100, 2100)));
  });
}
