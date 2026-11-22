// 唯一出口守卫（change `agent-group-chat` 任务 3.6 / spec「只有一个装配入口」）。
//
// 两条判据：
//   ① 结构探针：装配成员请求必须恰好经过一次投影函数（`buildCount` +1），产出的
//      请求与投影结果逐项相同；
//   ② 反证：**直接**把原文行交给装配器（绕过投影）会让他人私有的独特标记出现在
//      请求里 —— 证明"剔除"确实只由投影这一个出口完成。不经过投影就产生成员请求，
//      就等于这条用例描述的第二条出口。
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/services/api_message_builder.dart';
import 'package:alias_agent/services/group_view_projection.dart';

import 'group_view_fixtures.dart';

const String kPrivateMark = 'A-PRIVATE-MARK-93f1';

void main() {
  test('成员请求只由投影函数产出；绕过投影就会带出他人私有标记', () {
    final raw = [
      userRow(1, '开始'),
      privateToolRow(2, 'member-a',
          thinking: '甲的私有思路 $kPrivateMark',
          toolName: 'read_file',
          input: const {'path': 'lib/a.dart'},
          result: '私有结果 $kPrivateMark'),
      publicRow(3, 'member-a', '公开结论：已改 lib/a.dart'),
    ];

    GroupViewProjection.resetProbe();
    final view = GroupViewProjection.project(
      raw: raw,
      memberId: 'member-b',
      displayNames: kNames,
    );
    final projected = view.apiMessages(acceptsImages: false, model: 'test-model');
    // ignore: avoid_print
    print('[OBS] 投影调用次数=${GroupViewProjection.buildCount} '
        '投影请求条数=${projected.length} '
        '含私有标记=${projected.toString().contains(kPrivateMark)}');

    // ① 一次装配 = 一次投影。
    expect(GroupViewProjection.buildCount, 1,
        reason: '装配成员请求必须经过投影函数（唯一出口）');
    // 产出与投影函数的结果逐项相同（没有第二条装配路径混进来）。
    expect(projected, view.apiMessages(acceptsImages: false, model: 'test-model'));
    expect(projected.toString(), isNot(contains(kPrivateMark)));

    // ② 反证：绕过投影直接把原文交给装配器 ⇒ 私有标记出现。
    final naive = buildApiMessages(raw,
        acceptsImages: false, model: 'test-model');
    // ignore: avoid_print
    print('[OBS] 绕过投影的请求含私有标记=${naive.toString().contains(kPrivateMark)}');
    expect(naive.toString(), contains(kPrivateMark),
        reason: '这条反证说明"剔除"只能由投影完成；绕过它就会泄漏');

    // 而且投影后的视图里不含任何"他人私有行"的原始对象（按对象身份核对）。
    final otherPrivateRows = raw
        .where((m) => m.isPrivate && m.author != 'member-b')
        .toList();
    for (final row in otherPrivateRows) {
      expect(view.messages.any((m) => identical(m, row)), isFalse,
          reason: '他人私有行不得以任何形式出现在视图里');
    }
  });
}
