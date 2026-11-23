// 反应原语：结构化 PASS（`group_react` 终态工具）、`@显示名` 解析、反应轮规划、
// steps 封闭枚举（change `group-reactive-mode` R.10 / design D3、D5、D9）。
//
// 全部是**纯函数**（无 DB、无 sidecar）：这里只测判定与顺序，行为由 integration 覆盖。
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/models/group_member.dart';
import 'package:alias_agent/services/group_reaction.dart';

GroupMember _member(
  String id,
  String name, {
  int createdAt = 0,
  int? removedAt,
}) =>
    GroupMember(
      id: id,
      groupSessionId: 'g',
      name: name,
      templateName: 'general',
      removedAt: removedAt,
      createdAt: createdAt,
    );

/// 一个模型发出的 `group_react` 调用（Agent 拦截后交给解析器的形状）。
Map<String, dynamic> _reactCall(Object? input) => {
      'type': 'tool_use',
      'id': 'gr-1',
      'name': kGroupReactToolName,
      'input': input,
    };

void main() {
  // ---------------------------------------------------------------------------
  // 结构化 PASS：终态控制工具 group_react（R.10 / design D5）
  // ---------------------------------------------------------------------------
  group('group_react 工具定义与 parseGroupReactDecision', () {
    test('工具定义名为 group_react，schema 必填 pass:boolean 与 message:string', () {
      // ignore: avoid_print
      print('[OBS] group_react 定义=$kGroupReactToolDefinition');
      expect(kGroupReactToolDefinition['name'], 'group_react');
      final schema =
          kGroupReactToolDefinition['input_schema'] as Map<String, dynamic>;
      expect(schema['type'], 'object');
      final properties = schema['properties'] as Map<String, dynamic>;
      expect((properties['pass'] as Map)['type'], 'boolean');
      expect((properties['message'] as Map)['type'], 'string');
      expect(schema['required'], unorderedEquals(['pass', 'message']));
      // 它不在 ToolCatalog 里：materials 里没有注册入口，只作为 reaction 轮的
      // 控制工具注入（这条由 Agent 的单测覆盖；这里钉住名字不属于普通工具）。
    });

    test('pass=true ⇒ 沉默；message 不进公开内容，但保留供观察', () {
      final decision = parseGroupReactDecision([
        _reactCall({'pass': true, 'message': '我这回合不发言，等其它模型'}),
      ]);
      // ignore: avoid_print
      print('[OBS] pass=true 解析=${decision.isPass} message=${decision.message}');
      expect(decision.isPass, isTrue);
      expect(decision.isSpeak, isFalse);
      expect(decision.isFailed, isFalse);
      expect(decision.message, '我这回合不发言，等其它模型',
          reason: 'message 只为观察保留（finalText），不属于公开内容');
    });

    test('pass=false ⇒ 发言；message 是唯一公开内容', () {
      final decision = parseGroupReactDecision([
        _reactCall({'pass': false, 'message': '我同意，但路径应改成 lib/b.dart'}),
      ]);
      expect(decision.isPass, isFalse);
      expect(decision.isSpeak, isTrue);
      expect(decision.message, '我同意，但路径应改成 lib/b.dart');
    });

    test('pass=false + 空 message ⇒ 空发言（上层记 empty/forced_empty）', () {
      final decision = parseGroupReactDecision([
        _reactCall({'pass': false, 'message': ''}),
      ]);
      expect(decision.isSpeak, isTrue);
      expect(decision.message, '');
      expect(decision.isFailed, isFalse);
    });

    test('缺调用 ⇒ failed missing_group_react', () {
      final decision = parseGroupReactDecision(const []);
      // ignore: avoid_print
      print('[OBS] 缺调用 error=${decision.error}');
      expect(decision.isFailed, isTrue);
      expect(decision.error, 'missing_group_react');
    });

    test('参数非法 ⇒ failed invalid_group_react（pass 非布尔 / pass=false 缺 message）', () {
      for (final bad in <Object?>[
        {'pass': 'true', 'message': ''},
        {'message': '没有 pass'},
        {'pass': false},
        {'pass': false, 'message': 42},
        null,
        'not-a-map',
      ]) {
        final decision = parseGroupReactDecision([_reactCall(bad)]);
        // ignore: avoid_print
        print('[OBS] 非法输入=$bad => ${decision.error}');
        expect(decision.isFailed, isTrue, reason: '输入 $bad 必须判失败');
        expect(decision.error, 'invalid_group_react');
      }
    });

    test('同一轮多次调用 ⇒ failed invalid_group_react（不挑一个用）', () {
      final decision = parseGroupReactDecision([
        _reactCall({'pass': true, 'message': ''}),
        _reactCall({'pass': false, 'message': '又说了话'}),
      ]);
      expect(decision.isFailed, isTrue);
      expect(decision.error, 'invalid_group_react');
    });

    test('多余字段被忽略（不因扩展字段判非法）', () {
      final decision = parseGroupReactDecision([
        _reactCall({'pass': false, 'message': '好', 'extra': 1}),
      ]);
      expect(decision.isSpeak, isTrue);
      expect(decision.message, '好');
    });

    test('R.11 纠正提示与重试上限：上限 2，提示要求重新调用并给出参数形状', () {
      // ignore: avoid_print
      print('[OBS] kMaxGroupReactRetries=$kMaxGroupReactRetries');
      expect(kMaxGroupReactRetries, 2);
      final prompt = groupReactCorrectionPrompt(kMissingGroupReactError);
      // ignore: avoid_print
      print('[OBS] 纠正提示：$prompt');
      expect(prompt, contains('group_react'));
      expect(prompt, contains('恰好一次'));
      expect(prompt, contains('pass=true'));
      expect(prompt, contains('pass=false'));
      expect(prompt, contains('message'));
      expect(prompt, contains('重新调用'));
      expect(prompt, contains('不要用正文代替'));
    });
  });

  group('parseMentionedMemberIds：@显示名 → 成员 id', () {
    test('@ 最长名字优先', () {

      final members = [
        _member('m1', '甲', createdAt: 1),
        _member('m2', '甲二', createdAt: 2),
      ];
      final ids = parseMentionedMemberIds('@甲二 你看一下', members);
      // ignore: avoid_print
      print('[OBS] @甲二 ⇒ $ids');
      expect(ids, ['m2'], reason: '同一位置必须取最长匹配，不能被「甲」截走');
    });

    test('@ 名字后必须边界（结尾 / 空白 / 标点）', () {
      final members = [_member('m1', '甲', createdAt: 1)];
      expect(parseMentionedMemberIds('@甲', members), ['m1']);
      expect(parseMentionedMemberIds('@甲 你看', members), ['m1']);
      expect(parseMentionedMemberIds('@甲，你看', members), ['m1']);
      expect(parseMentionedMemberIds('@甲。', members), ['m1']);
      // 名字后面紧跟其它字符 ⇒ 不是这个成员（否则「@甲二」会被「甲」误吃）。
      expect(parseMentionedMemberIds('@甲二 你看', members), isEmpty);
      expect(parseMentionedMemberIds('@甲abc', members), isEmpty);
    });

    test('未知 @ 不解析（正文原样保留，解析只返回已知成员）', () {
      final members = [_member('m1', '甲', createdAt: 1)];
      // ignore: avoid_print
      print('[OBS] 未知 @ ⇒ ${parseMentionedMemberIds("@不存在的人 你好", members)}');
      expect(parseMentionedMemberIds('@不存在的人 你好', members), isEmpty);
    });

    test('已移除成员不解析', () {
      final members = [
        _member('m1', '甲', createdAt: 1, removedAt: 1),
        _member('m2', '乙', createdAt: 2),
      ];
      expect(parseMentionedMemberIds('@甲 @乙', members), ['m2']);
    });

    test('多个命中按出现顺序去重', () {
      final members = [
        _member('m1', '甲', createdAt: 1),
        _member('m2', '乙', createdAt: 2),
      ];
      final ids = parseMentionedMemberIds('@乙 先说，然后 @甲 说，@乙 再说', members);
      // ignore: avoid_print
      print('[OBS] 多命中 ⇒ $ids');
      expect(ids, ['m2', 'm1'], reason: '按出现顺序，重复的 @乙 只算一次');
    });

    test('@后面没名字 / 纯空白不算命中', () {
      final members = [_member('m1', '甲', createdAt: 1)];
      expect(parseMentionedMemberIds('@', members), isEmpty);
      expect(parseMentionedMemberIds('@ 甲', members), isEmpty);
    });

    test('没有 @ 时返回空（不是异常）', () {
      final members = [_member('m1', '甲', createdAt: 1)];
      expect(parseMentionedMemberIds('随便说一句', members), isEmpty);
    });
  });

  group('planReactionRound：谁该对这条公开消息反应', () {
    test('作者不反应自己', () {
      final members = [
        _member('a', '甲', createdAt: 1),
        _member('b', '乙', createdAt: 2),
      ];
      final plan = planReactionRound(
        members: members,
        triggerSeq: 10,
        triggerAuthor: 'a',
        lastReactedSeq: const {},
      );
      // ignore: avoid_print
      print('[OBS] 作者=a 的计划=${plan.map((e) => e.member.id).toList()}');
      expect(plan.map((e) => e.member.id).toList(), ['b']);
    });

    test('lastReacted 排除同一条（已反应过的不再选中）', () {
      final members = [
        _member('a', '甲', createdAt: 1),
        _member('b', '乙', createdAt: 2),
      ];
      final plan = planReactionRound(
        members: members,
        triggerSeq: 10,
        triggerAuthor: null,
        lastReactedSeq: const {'a': 10, 'b': 9},
      );
      // ignore: avoid_print
      print('[OBS] lastReacted a=10 b=9 ⇒ '
          '${plan.map((e) => e.member.id).toList()}');
      expect(plan.map((e) => e.member.id).toList(), ['b'],
          reason: 'a 已对 seq=10 反应过；b 只对 9 反应过，仍可反应');
    });

    test('forced 顺序在普通成员之前（按点名顺序）', () {
      final members = [
        _member('a', '甲', createdAt: 1),
        _member('b', '乙', createdAt: 2),
        _member('c', '丙', createdAt: 3),
      ];
      final plan = planReactionRound(
        members: members,
        triggerSeq: 10,
        triggerAuthor: null,
        lastReactedSeq: const {},
        forcedMemberIds: const ['c', 'b'],
      );
      // ignore: avoid_print
      print('[OBS] forced=[c,b] ⇒ '
          '${plan.map((e) => '${e.member.id}:${e.forced}').toList()}');
      expect(plan.map((e) => e.member.id).toList(), ['c', 'b', 'a'],
          reason: '被点名者按点名顺序排最前，其余按加入顺序');
      expect(plan.map((e) => e.forced).toList(), [true, true, false]);
    });

    test('没有 forced 时按加入顺序（createdAt，rowid 兜底）', () {
      final members = [
        _member('c', '丙', createdAt: 3),
        _member('a', '甲', createdAt: 1),
        _member('b', '乙', createdAt: 2),
      ];
      final plan = planReactionRound(
        members: members,
        triggerSeq: 10,
        triggerAuthor: null,
        lastReactedSeq: const {},
      );
      expect(plan.map((e) => e.member.id).toList(), ['a', 'b', 'c']);
    });

    test('已移除成员不参与', () {
      final members = [
        _member('a', '甲', createdAt: 1, removedAt: 5),
        _member('b', '乙', createdAt: 2),
      ];
      final plan = planReactionRound(
        members: members,
        triggerSeq: 10,
        triggerAuthor: null,
        lastReactedSeq: const {},
      );
      expect(plan.map((e) => e.member.id).toList(), ['b']);
    });

    test('作者在同一成员既 forced 又作者时被排除（forced 不复活作者）', () {
      final members = [
        _member('a', '甲', createdAt: 1),
        _member('b', '乙', createdAt: 2),
      ];
      final plan = planReactionRound(
        members: members,
        triggerSeq: 10,
        triggerAuthor: 'a',
        lastReactedSeq: const {},
        forcedMemberIds: const ['a', 'b'],
      );
      expect(plan.map((e) => e.member.id).toList(), ['b']);
      expect(plan.single.forced, isTrue);
    });

    test('没有可反应成员时返回空（链的正常出口）', () {
      final members = [_member('a', '甲', createdAt: 1)];
      final plan = planReactionRound(
        members: members,
        triggerSeq: 10,
        triggerAuthor: 'a',
        lastReactedSeq: const {},
      );
      expect(plan, isEmpty);
    });

    test('triggerSeq 为 0 / 空成员表时返回空', () {
      expect(
        planReactionRound(
          members: const [],
          triggerSeq: 10,
          triggerAuthor: null,
          lastReactedSeq: const {},
        ),
        isEmpty,
      );
    });

    test('forced 成员若已对同一条反应过仍被排除（lastReacted 优先）', () {
      final members = [
        _member('a', '甲', createdAt: 1),
        _member('b', '乙', createdAt: 2),
      ];
      final plan = planReactionRound(
        members: members,
        triggerSeq: 10,
        triggerAuthor: null,
        lastReactedSeq: const {'b': 10},
        forcedMemberIds: const ['b'],
      );
      expect(plan.map((e) => e.member.id).toList(), ['a']);
    });
  });

  group('steps 的封闭枚举', () {
    test('source / status 集合与 spec 一致', () {
      // ignore: avoid_print
      print('[OBS] sources=$kReactionStepSources statuses=$kReactionStepStatuses');
      expect(kReactionStepSources, {'speaker', 'mention', 'reaction'});
      expect(kReactionStepStatuses, {
        'replied',
        'passed',
        'forced_pass',
        'forced_empty',
        'empty',
        'failed',
        'cancelled',
      });
      expect(kReactionStepSources, isA<Set<String>>());
      expect(kReactionStepStatuses, isA<Set<String>>());
    });
  });
}
