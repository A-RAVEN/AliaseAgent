// 视图投影的映射规则与剔除彻底性（change `agent-group-chat` 任务 3.1 / 3.3 / 3.4 /
// spec「逐成员视图投影是唯一出口」）。
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/models/message.dart';
import 'package:alias_agent/services/group_view_projection.dart';

import 'group_view_fixtures.dart';

List<Map<String, dynamic>> _api(List<Message> raw, String memberId) =>
    GroupViewProjection.project(
      raw: raw,
      memberId: memberId,
      displayNames: kNames,
    ).apiMessages(acceptsImages: false, model: 'test-model');

String _flatten(List<Map<String, dynamic>> api) =>
    api.map((m) => '${m['role']}:${m['content']}').join('\n');

void main() {
  group('3.1 投影映射规则', () {
    test('用户消息原样进 user 轮', () {
      final api = _api([userRow(1, '你们两个都看一下 lib/a.dart')], 'member-a');
      // ignore: avoid_print
      print('[OBS] 用户消息 => ${_flatten(api)}');
      expect(api.length, 1);
      expect(api.single['role'], 'user');
      expect((api.single['content'] as List).single,
          {'type': 'text', 'text': '你们两个都看一下 lib/a.dart'});
    });

    test('自己的公开回复是第一人称、不带「甲 说：」前缀', () {
      final api = _api([publicRow(2, 'member-a', '我改完了 lib/a.dart')], 'member-a');
      // ignore: avoid_print
      print('[OBS] 自己的公开回复 => ${_flatten(api)}');
      expect(api.single['role'], 'assistant');
      final text = (api.single['content'] as List).single['text'] as String;
      expect(text, '我改完了 lib/a.dart');
      expect(text, isNot(contains('说：')));
    });

    test('他人公开回复进 user 轮并带「甲 说：」前缀（含已移除成员）', () {
      final api = _api([
        publicRow(2, 'member-a', '已改完 lib/a.dart'),
        publicRow(3, 'member-removed', '我看过 lib/b.dart 了'),
      ], 'member-b');
      // ignore: avoid_print
      print('[OBS] 他人公开回复 => ${_flatten(api)}');
      expect(api[0]['role'], 'user');
      expect((api[0]['content'] as List).single['text'], '甲 说：已改完 lib/a.dart');
      expect(api[1]['role'], 'user');
      expect((api[1]['content'] as List).single['text'],
          '丙 说：我看过 lib/b.dart 了',
          reason: '已移除成员的历史发言也要有归属（显示名来自成员表）');
    });

    test('自己的私有活动按 replay 回放（thinking + tool_use + 合成 tool_result）', () {
      final api = _api([
        privateToolRow(2, 'member-a',
            thinking: '先读文件',
            toolName: 'read_file',
            input: {'path': 'lib/a.dart'},
            result: '内容 A'),
      ], 'member-a');
      // ignore: avoid_print
      print('[OBS] 自己私有活动 => ${_flatten(api)}');
      expect(api.length, 2, reason: 'assistant 工具轮 + 合成 user(tool_result)');
      expect(api[0]['role'], 'assistant');
      final blocks = (api[0]['content'] as List).cast<Map<String, dynamic>>();
      expect(blocks[0]['type'], 'thinking');
      expect(blocks[0]['thinking'], '先读文件');
      expect(blocks[1]['type'], 'tool_use');
      expect(blocks[1]['name'], 'read_file');
      expect(api[1]['role'], 'user');
      final resultBlock =
          (api[1]['content'] as List).cast<Map<String, dynamic>>().single;
      expect(resultBlock['type'], 'tool_result');
      expect(resultBlock['tool_use_id'], 'tool-1');
    });

    test('他人私有活动整体剔除', () {
      final api = _api([
        privateToolRow(2, 'member-a',
            thinking: '甲的私密思路',
            toolName: 'read_file',
            input: {'path': 'lib/secret.dart'},
            result: '机密结果'),
        publicRow(3, 'member-a', '公开结论'),
      ], 'member-b');
      // ignore: avoid_print
      print('[OBS] 乙看到的 => ${_flatten(api)}');
      expect(api.length, 1);
      expect(_flatten(api), isNot(contains('私密思路')));
      expect(_flatten(api), isNot(contains('机密结果')));
      expect(_flatten(api), isNot(contains('lib/secret.dart')));
    });
  });

  group('3.3 剔除彻底性（三类内容块）', () {
    test('他人私有的 thinking 块不出现', () {
      final api = _api(
          [privateThinkingRow(1, 'member-a', '只有甲能看到的思考')], 'member-b');
      // ignore: avoid_print
      print('[OBS] thinking 检查 => ${_flatten(api)}');
      expect(_flatten(api), isNot(contains('只有甲能看到的思考')));
      for (final message in api) {
        for (final block in (message['content'] as List)) {
          expect((block as Map)['type'], isNot('thinking'));
        }
      }
    });

    test('他人私有的 tool_use 块不出现', () {
      final api = _api([
        privateToolRow(1, 'member-a',
            thinking: 'x',
            toolName: 'write_file',
            input: {'path': 'lib/private.dart'},
            result: 'ok'),
      ], 'member-b');
      // ignore: avoid_print
      print('[OBS] tool_use 检查 => ${_flatten(api)}');
      for (final message in api) {
        for (final block in (message['content'] as List)) {
          expect((block as Map)['type'], isNot('tool_use'));
        }
      }
    });

    test('他人私有的 tool_result 块不出现', () {
      final api = _api([
        privateToolRow(1, 'member-a',
            thinking: 'x',
            toolName: 'read_file',
            input: {'path': 'lib/private.dart'},
            result: '很长的私有结果 PRIVATE-MARK'),
      ], 'member-b');
      // ignore: avoid_print
      print('[OBS] tool_result 检查 => ${_flatten(api)}');
      for (final message in api) {
        for (final block in (message['content'] as List)) {
          expect((block as Map)['type'], isNot('tool_result'));
        }
      }
      expect(_flatten(api), isNot(contains('PRIVATE-MARK')));
    });
  });

  group('3.4 连续同角色不修补', () {
    test('连续 user 轮原样发出（不插填充、不改 role、不造空 text 块）', () {
      // 甲、乙先后公开回复，X（丙）自己没发言 ⇒ 视图里两条相邻 user 轮。
      final view = GroupViewProjection.project(
        raw: [
          publicRow(1, 'member-a', '甲的第一句'),
          publicRow(2, 'member-b', '乙的第一句'),
        ],
        memberId: 'member-removed',
        displayNames: kNames,
      );
      final api = view.apiMessages(acceptsImages: false, model: 'test-model');
      // ignore: avoid_print
      print('[OBS] 连续 user 轮 => ${_flatten(api)}');

      expect(api.length, 2);
      expect(api[0]['role'], 'user');
      expect(api[1]['role'], 'user');
      expect(view.messages.length, 2, reason: '不插入填充项');
      for (final message in api) {
        final blocks = (message['content'] as List).cast<Map<String, dynamic>>();
        expect(blocks.length, 1);
        expect(blocks.single['type'], 'text');
        expect((blocks.single['text'] as String).isNotEmpty, isTrue,
            reason: '不造空 text 块');
      }
    });
  });
}
