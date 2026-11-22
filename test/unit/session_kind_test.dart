// `sessions.kind` 与 `sessions.overrides_json` 的纯模型读写（change
// `agent-group-chat` 任务 1.3 / design D1、D8、D16）。
//
// 两条口径：
//   ① `kind` 缺省等于 `single`（旧数据、旧创建路径都必须落到单会话）；
//   ② `overrides_json` 为 NULL 等于"没有覆盖"（不是空串、不是 `{}`）。
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/models/session.dart';

void main() {
  group('Session 的 kind 与覆盖层列', () {
    test('kind 缺省 single：旧行 / 旧创建路径都落到单会话', () {
      final legacyRow = <String, dynamic>{
        'id': 's-1',
        'title': '旧会话',
        'agent_type': 'general',
        'parent_session_id': null,
        'created_at': 1,
        'updated_at': 2,
      };
      final legacy = Session.fromRow(legacyRow);
      // ignore: avoid_print
      print('[OBS] legacy kind=${legacy.kind} isGroup=${legacy.isGroup} '
          'overridesJson=${legacy.overridesJson}');
      expect(legacy.kind, 'single');
      expect(legacy.isGroup, isFalse);
      expect(legacy.toRow()['kind'], 'single',
          reason: '没显式给 kind 时写出去的必须是 single');

      // 非法值同样回落 single（旧库/手改数据都不能凭空变成组会话）。
      final illegal = Session.fromRow({...legacyRow, 'kind': 'GROUP'});
      expect(illegal.kind, 'single');

      // 显式 group 才读成组会话。
      final group = Session.fromRow({...legacyRow, 'kind': 'group'});
      expect(group.isGroup, isTrue);
      expect(group.toRow()['kind'], 'group');

      expect(() => Session(
            id: 'x',
            title: 'x',
            kind: 'team',
            createdAt: 1,
            updatedAt: 1,
          ), throwsA(isA<AssertionError>()));
    });

    test('overrides_json 为 NULL 等于无覆盖', () {
      final legacy = Session.fromRow(<String, dynamic>{
        'id': 's-2',
        'title': '会话',
        'agent_type': 'general',
        'created_at': 1,
        'updated_at': 1,
      });
      // ignore: avoid_print
      print('[OBS] overridesJson=${legacy.overridesJson} 解析结果=${legacy.overrides}');
      expect(legacy.overridesJson, isNull);
      expect(legacy.toRow()['overrides_json'], isNull,
          reason: '没有覆盖层时写 NULL（不是 "{}"，那会变成"显式空覆盖"）');
      expect(legacy.overrides, isNull,
          reason: 'NULL 解析成"没有覆盖"，工具/提示词/思考强度全部沿用模板');
    });
  });
}
