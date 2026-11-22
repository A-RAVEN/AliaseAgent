// 投影不变量（change `agent-group-chat` 任务 3.5 / spec「投影不变量」）：
//   ① 成员自己的 tool_use 与对应 tool_result 之间不夹他人公开行；
//   ② tool_result 位于所在 user 轮 content 数组最前；
//   ③ 每条可见项恰好出现一次（不重复、不遗漏）。
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/services/group_view_projection.dart';

import 'group_view_fixtures.dart';

void main() {
  group('3.5 投影不变量', () {
    test('① 自己的 tool_use 与 tool_result 之间不夹他人公开行', () {
      final view = GroupViewProjection.project(
        raw: [
          userRow(1, '开始'),
          // 甲的工具轮之前有乙的公开行（上一轮），之后才是甲自己的工具轮。
          publicRow(2, 'member-b', '乙先说了话'),
          privateToolRow(3, 'member-a', thinking: 'x', toolName: 'read_file', input: const {'path': 'a'}, result: 'A', toolId: 't-1'),
          privateToolRow(4, 'member-a', thinking: 'y', toolName: 'read_file', input: const {'path': 'b'}, result: 'B', toolId: 't-2'),
        ],
        memberId: 'member-a',
        displayNames: kNames,
      );
      final api = view.apiMessages(acceptsImages: false, model: 'test-model');
      // ignore: avoid_print
      print('[OBS] 序列=${api.map((m) => m['role']).toList()}');

      for (var i = 0; i < api.length; i++) {
        final blocks = (api[i]['content'] as List).cast<Map<String, dynamic>>();
        final hasToolUse = blocks.any((b) => b['type'] == 'tool_use');
        if (!hasToolUse) continue;
        final next = (api[i + 1]['content'] as List).cast<Map<String, dynamic>>();
        expect(api[i + 1]['role'], 'user');
        expect(next.every((b) => b['type'] == 'tool_result'), isTrue,
            reason: 'tool_use 的下一轮必须是纯 tool_result（不夹他人公开行）');
        // 该 user 轮里不能出现「Y 说：」文本。
        for (final block in next) {
          expect((block['content'] as String), isNot(contains('说：')));
        }
      }
    });

    test('② tool_result 位于所在 user 轮 content 数组最前', () {
      final view = GroupViewProjection.project(
        raw: [
          privateToolRow(1, 'member-a', thinking: 'x', toolName: 'read_file', input: const {'path': 'a'}, result: 'A'),
        ],
        memberId: 'member-a',
        displayNames: kNames,
      );
      final api = view.apiMessages(acceptsImages: false, model: 'test-model');
      final resultTurn =
          api.firstWhere((m) => m['role'] == 'user');
      final blocks = (resultTurn['content'] as List).cast<Map<String, dynamic>>();
      // ignore: avoid_print
      print('[OBS] tool_result 轮 blocks=${blocks.map((b) => b['type']).toList()}');
      expect(blocks.first['type'], 'tool_result');
      expect(blocks.where((b) => b['type'] == 'text'), isEmpty,
          reason: '纯工具结果轮里不该夹入任何正文');
    });

    test('③ 每条可见项恰好出现一次', () {
      final raw = [
        userRow(1, '用户第一句'),
        publicRow(2, 'member-b', '乙的公开回复'),
        publicRow(3, 'member-a', '甲的公开回复'),
        privateToolRow(4, 'member-a', thinking: 'x', toolName: 'read_file', input: const {'path': 'a'}, result: 'A'),
        userRow(5, '用户第二句'),
      ];
      final view = GroupViewProjection.project(
        raw: raw,
        memberId: 'member-a',
        displayNames: kNames,
      );
      // ignore: avoid_print
      print('[OBS] 视图条数=${view.messages.length} '
          'seq=${view.messages.map((m) => m.seq).toList()}');
      // 甲能看到的原文行：用户 1、乙的 2（合成）、自己的 3、自己的私有 4、用户 5
      // = 5 条视图项；每条的 seq 恰好出现一次。
      expect(view.messages.length, 5);
      final seqs = view.messages.map((m) => m.seq).toList();
      expect(seqs.toSet().length, seqs.length, reason: '不得重复');
      expect(seqs, [1, 2, 3, 4, 5], reason: '不得遗漏，顺序按子原文 seq');

      // 文本层面也各出现一次。
      final text = view.textContent;
      for (final needle in ['用户第一句', '乙 说：乙的公开回复', '甲的公开回复', '用户第二句']) {
        expect(needle.allMatches(text).length, 1, reason: '"$needle" 必须恰好出现一次');
      }
    });
  });
}
