// 归属只看文本，不依赖 `name` 字段（change `agent-group-chat` 任务 3.2 /
// spec「归属只能进文本」）。
//
// Anthropic 的 `MessageParam` 只有 role 与 content（Docs/AnthropicAPIDoc.md §1.3.2），
// DeepSeek 兼容页未记载 Messages 可用 `name`。所以装配出的**每一条**请求消息只能有
// 这两个键：多出 `name` 就是走了没有本地文档依据的字段，直接红。
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/services/group_view_projection.dart';

import 'group_view_fixtures.dart';

void main() {
  test('装配出的每条消息只有 role 与 content 两个键', () {
    final view = GroupViewProjection.project(
      raw: [
        userRow(1, '开始吧'),
        privateToolRow(2, 'member-a',
            thinking: '先看文件',
            toolName: 'read_file',
            input: {'path': 'lib/a.dart'},
            result: '内容 A'),
        publicRow(3, 'member-a', '已改完 lib/a.dart'),
        publicRow(4, 'member-b', '收到，我读 lib/b.dart'),
        privateToolRow(5, 'member-b',
            thinking: '乙的私有思路',
            toolName: 'read_file',
            input: {'path': 'lib/b.dart'},
            result: '内容 B'),
      ],
      memberId: 'member-a',
      displayNames: kNames,
    );
    final api = view.apiMessages(acceptsImages: false, model: 'test-model');

    // ignore: avoid_print
    print('[OBS] 消息数=${api.length}');
    for (final message in api) {
      // ignore: avoid_print
      print('[OBS] keys=${message.keys.toList()} role=${message['role']}');
      expect(message.keys.toSet(), {'role', 'content'},
          reason: '每条请求消息只能有 role 与 content（不许出现 name 等无文档依据的字段）');
      expect(message.containsKey('name'), isFalse);
    }
    expect(api, isNotEmpty);
  });
}
