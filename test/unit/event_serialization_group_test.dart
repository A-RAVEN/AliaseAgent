// 群聊的线上序列化形状（change `agent-group-chat` 任务 7.3 / spec `web-core-shim`）。
//
//   - `serializeMessage` 带 author / visibility（可空字段如实写出）；
//   - `serializeSession` 带 kind / overrides；
//   - 事件身份（groupId/memberId）由核心的 `_sendEvent` 负责，这条在
//     `group_rpc_test` 的 7.3 用例里打真实 WebSocket。
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/core/event_serialization.dart';
import 'package:alias_agent/core/headless_core.dart';
import 'package:alias_agent/models/instance_overrides.dart';
import 'package:alias_agent/models/message.dart';
import 'package:alias_agent/models/session.dart';

void main() {
  test('serializeMessage 带 author / visibility（可空字段如实写出）', () {
    final user = serializeMessage(Message(
      id: 'm1',
      seq: 1,
      sessionId: 'g',
      role: 'user',
      content: '用户说的',
      createdAt: 1,
    ));
    final private = serializeMessage(Message(
      id: 'm2',
      seq: 2,
      sessionId: 'g',
      role: 'assistant',
      content: '',
      author: 'member-a',
      visibility: Message.visibilityPrivateToAuthor,
      createdAt: 2,
    ));
    // ignore: avoid_print
    print('[OBS] 用户行 author=${user['author']} visibility=${user['visibility']}');
    // ignore: avoid_print
    print('[OBS] 私有行 author=${private['author']} visibility=${private['visibility']}');

    expect(user.containsKey('author'), isTrue);
    expect(user['author'], isNull);
    expect(user['visibility'], 'public');
    expect(private['author'], 'member-a');
    expect(private['visibility'], 'private-to-author');
  });

  test('serializeSession 带 kind 与 overrides（没有覆盖时是 null）', () {
    final group = serializeSession(Session(
      id: 'g',
      title: '组',
      kind: Session.kindGroup,
      createdAt: 1,
      updatedAt: 1,
    ));
    final single = serializeSession(Session(
      id: 's',
      title: '单',
      createdAt: 1,
      updatedAt: 1,
      overridesJson: AgentInstanceOverrides.fromJson({
        'toolsSubset': ['read_file'],
      }).toJsonString(),
    ));
    // ignore: avoid_print
    print('[OBS] group kind=${group['kind']} overrides=${group['overrides']}');
    // ignore: avoid_print
    print('[OBS] single kind=${single['kind']} overrides=${single['overrides']}');

    expect(group['kind'], 'group');
    expect(group['overrides'], isNull);
    expect(single['kind'], 'single');
    expect((single['overrides'] as Map)['toolsSubset'], ['read_file']);
  });
}
