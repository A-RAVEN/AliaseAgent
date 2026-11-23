// 组的两个持久设置（自发反应开关 + 反应轮数上限）在**模型层**的口径
// （change `group-reactive-mode` 任务 0.2 / R.1 / design D8 第 5 条、D13 /
// `session-persistence` 的「组会话、成员表与覆盖层列」）：
//
//   ① 构造函数缺省 `reactionsEnabled = true`、`maxRounds = null`；
//   ② `fromRow` 在 `reactions_enabled` **缺失或为 null** 时为 `false`（未迁移的旧库 /
//      手工夹具 = 旧点名行为），`max_reaction_rounds` 缺失或为 null 读成 `null`；
//   ③ `toRow` 写 1/0 与整数/NULL 且往返一致；`copyWith` 可改（`clearMaxRounds` 恢复默认）。
//
// 纯内存（不碰数据库）：这里测的是「行的形状 ↔ 模型」的映射，真 SQLite 的持久化由
// `test/integration/group_lifecycle_test.dart` 的增补用例覆盖。
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/models/session.dart';

/// 一条**缺** `reactions_enabled` 列的旧行（v9 及更早）。
Map<String, dynamic> _legacyRow({String kind = 'single'}) => {
      'id': 's1',
      'title': '旧会话',
      'agent_type': 'general',
      'parent_session_id': null,
      'created_at': 1,
      'updated_at': 2,
      'kind': kind,
      'overrides_json': null,
    };

void main() {
  test('构造函数缺省 reactionsEnabled == true（新建组默认开启）', () {
    final session = Session(
      id: 's',
      title: '新组',
      createdAt: 1,
      updatedAt: 1,
      kind: Session.kindGroup,
    );
    // ignore: avoid_print
    print('[OBS] 构造默认 reactionsEnabled=${session.reactionsEnabled}');
    expect(session.reactionsEnabled, isTrue);
  });

  test('显式传 false 时构造函数保留 false', () {
    final session = Session(
      id: 's',
      title: '安静组',
      createdAt: 1,
      updatedAt: 1,
      kind: Session.kindGroup,
      reactionsEnabled: false,
    );
    expect(session.reactionsEnabled, isFalse);
  });

  test('fromRow 缺列（旧库）⇒ false，不是新默认 true', () {
    final row = _legacyRow(kind: 'group');
    expect(row.containsKey('reactions_enabled'), isFalse,
        reason: '夹具必须真的没有这一列，否则这条用例在测别的东西');
    final session = Session.fromRow(row);
    // ignore: avoid_print
    print('[OBS] 缺列 fromRow reactionsEnabled=${session.reactionsEnabled}');
    expect(session.reactionsEnabled, isFalse,
        reason: '未迁移的旧库 = 旧点名行为（保守关闭）');
  });

  test('fromRow 列为 null ⇒ false', () {
    final row = _legacyRow(kind: 'group')..['reactions_enabled'] = null;
    expect(Session.fromRow(row).reactionsEnabled, isFalse);
  });

  test('fromRow 按值解释 1 / 0', () {
    final on = _legacyRow(kind: 'group')..['reactions_enabled'] = 1;
    final off = _legacyRow(kind: 'group')..['reactions_enabled'] = 0;
    // ignore: avoid_print
    print('[OBS] fromRow(1)=${Session.fromRow(on).reactionsEnabled} '
        'fromRow(0)=${Session.fromRow(off).reactionsEnabled}');
    expect(Session.fromRow(on).reactionsEnabled, isTrue);
    expect(Session.fromRow(off).reactionsEnabled, isFalse);
  });

  test('toRow 写 1 / 0，且 toRow → fromRow 往返一致', () {
    Session build(bool enabled) => Session(
          id: 's-${enabled ? 1 : 0}',
          title: 't',
          createdAt: 1,
          updatedAt: 1,
          kind: Session.kindGroup,
          reactionsEnabled: enabled,
        );

    final on = build(true).toRow();
    final off = build(false).toRow();
    // ignore: avoid_print
    print('[OBS] toRow on=${on['reactions_enabled']} '
        'off=${off['reactions_enabled']}');
    expect(on['reactions_enabled'], 1);
    expect(off['reactions_enabled'], 0);
    expect(Session.fromRow(on).reactionsEnabled, isTrue);
    expect(Session.fromRow(off).reactionsEnabled, isFalse);
  });

  // ---------------------------------------------------------------------------
  // 反应轮数上限（change `group-reactive-mode` 任务 R.1 / design D13）
  // ---------------------------------------------------------------------------

  test('构造函数缺省 maxRounds == null（= 用产品默认）', () {
    final session = Session(
      id: 'g',
      title: '新组',
      createdAt: 1,
      updatedAt: 1,
      kind: Session.kindGroup,
    );
    // ignore: avoid_print
    print('[OBS] 构造默认 maxRounds=${session.maxRounds}');
    expect(session.maxRounds, isNull);
  });

  test('上限常量与 design D13 一致（默认 8、范围 1..50）', () {
    // ignore: avoid_print
    print('[OBS] 上限常量 默认=$kDefaultMaxReactionRounds '
        '范围=$kMinMaxReactionRounds..$kMaxMaxReactionRounds');
    expect(kDefaultMaxReactionRounds, 8);
    expect(kMinMaxReactionRounds, 1);
    expect(kMaxMaxReactionRounds, 50);
    expect(kMinMaxReactionRounds, lessThanOrEqualTo(kDefaultMaxReactionRounds));
    expect(kDefaultMaxReactionRounds, lessThanOrEqualTo(kMaxMaxReactionRounds));
  });

  test('fromRow 缺列 / null ⇒ maxRounds == null；按值 6 读回 6', () {
    final legacy = _legacyRow(kind: 'group');
    expect(legacy.containsKey('max_reaction_rounds'), isFalse);
    // ignore: avoid_print
    print('[OBS] 缺列 fromRow maxRounds=${Session.fromRow(legacy).maxRounds}');
    expect(Session.fromRow(legacy).maxRounds, isNull);

    final nullRow = _legacyRow(kind: 'group')..['max_reaction_rounds'] = null;
    expect(Session.fromRow(nullRow).maxRounds, isNull);

    final set = _legacyRow(kind: 'group')..['max_reaction_rounds'] = 6;
    // ignore: avoid_print
    print('[OBS] 列=6 fromRow maxRounds=${Session.fromRow(set).maxRounds}');
    expect(Session.fromRow(set).maxRounds, 6);
  });

  test('toRow 写 max_reaction_rounds（整数 / NULL），往返一致', () {
    Session build(int? maxRounds) => Session(
          id: 'g-${maxRounds ?? 'null'}',
          title: 't',
          createdAt: 1,
          updatedAt: 1,
          kind: Session.kindGroup,
          maxRounds: maxRounds,
        );
    final set = build(6).toRow();
    final cleared = build(null).toRow();
    // ignore: avoid_print
    print('[OBS] toRow max_reaction_rounds 6=${set['max_reaction_rounds']} '
        'null=${cleared['max_reaction_rounds']}');
    expect(set['max_reaction_rounds'], 6);
    expect(cleared['max_reaction_rounds'], isNull);
    expect(Session.fromRow(set).maxRounds, 6);
    expect(Session.fromRow(cleared).maxRounds, isNull);
  });

  test('copyWith 可改 maxRounds，clearMaxRounds 恢复默认，且不动其它字段', () {
    final session = Session(
      id: 'g',
      title: '组',
      createdAt: 1,
      updatedAt: 5,
      kind: Session.kindGroup,
    );
    final limited = session.copyWith(maxRounds: 6);
    final cleared = limited.copyWith(clearMaxRounds: true);
    // ignore: avoid_print
    print('[OBS] copyWith 6=${limited.maxRounds} clear=${cleared.maxRounds} '
        'id=${limited.id} reactions=${limited.reactionsEnabled}');
    expect(limited.maxRounds, 6);
    expect(cleared.maxRounds, isNull);
    expect(limited.id, session.id);
    expect(limited.kind, Session.kindGroup);
    expect(limited.updatedAt, session.updatedAt);
    // 不传时保持原值。
    expect(limited.copyWith(title: '改标题').maxRounds, 6);
    expect(limited.copyWith(title: '改标题').reactionsEnabled, isTrue);
  });

  test('copyWith 可改 reactionsEnabled，且不改其它字段', () {
    final session = Session(
      id: 's',
      title: '组',
      createdAt: 1,
      updatedAt: 5,
      kind: Session.kindGroup,
    );
    final off = session.copyWith(reactionsEnabled: false);
    // ignore: avoid_print
    print('[OBS] copyWith => ${off.reactionsEnabled} id=${off.id} '
        'kind=${off.kind} createdAt=${off.createdAt}');
    expect(off.reactionsEnabled, isFalse);
    expect(off.id, session.id);
    expect(off.kind, Session.kindGroup);
    expect(off.createdAt, session.createdAt);
    expect(off.updatedAt, session.updatedAt);
    // 不传时保持原值。
    expect(session.copyWith(title: '改标题').reactionsEnabled, isTrue);
  });
}
