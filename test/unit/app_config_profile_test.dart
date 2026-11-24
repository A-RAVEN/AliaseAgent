import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/models/app_config.dart';
import 'package:alias_agent/models/user_profile.dart';

/// 用户资料块 `profile` 的解析与写回（change `chat-bubbles-avatars` 任务 2.3 /
/// design D2 / D3）。
///
/// 覆盖哪几件事：
///   1. `profile` 带 `avatar_path` / `user_id` 时都读出，并派生实际生效种子；
///   2. **没有 `profile` 键时静默**（值为 null、`toJson` 不写块、不打日志）；
///   3. `profile` 不是对象、或字段不是字符串 / 空串时回落并打一行日志；
///   4. **字段缺席静默**：只给 `{"user_id": "a"}` 时不得因缺 `avatar_path` 打日志
///      （字段缺席与"存在但非法"是两条不同的口径）；
///   5. `copyWith(clearProfile: true)` 能清掉整个块（照 `GroupMember.clearOverrides`）；
///   6. `toJson` 只在至少一项有值时写块（旧配置不因升级产生无意义差异）。
void main() {
  Map<String, dynamic> baseJson() => <String, dynamic>{
        'version': 1,
        'providers': <String, dynamic>{},
        'agent_types': <String, dynamic>{},
      };

  Map<String, dynamic> withProfile(Map<String, dynamic>? profile) => <String, dynamic>{
        ...baseJson(),
        'profile': ?profile,
      };

  test('带 avatar_path / user_id 时都读出，identitySeed 取 user_id', () {
    const path = r'C:\Users\me\.aliasagent\attachments\face.png';
    final config = AppConfig.fromJson(withProfile({
      'avatar_path': path,
      'user_id': 'alice',
    }));
    // ignore: avoid_print
    print('[用户资料] profile=${config.profile?.toJson()} '
        'seed=${config.profile?.identitySeed}');
    expect(config.profile, isNotNull);
    expect(config.profile!.avatarPath, path);
    expect(config.profile!.userId, 'alice');
    expect(config.profile!.identitySeed, 'alice');
    expect(config.profile!.isEmpty, isFalse);
  });

  test('没有 profile 键 ⇒ null、toJson 不写块、且无告警', () {
    final captured = <String>[];
    final original = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) captured.add(message);
    };
    AppConfig config;
    try {
      config = AppConfig.fromJson(baseJson());
    } finally {
      debugPrint = original;
    }
    final back = config.toJson();
    // ignore: avoid_print
    print('[用户资料] 无 profile：profile=${config.profile} '
        'toJson containsKey=${back.containsKey('profile')} 日志=$captured');
    expect(config.profile, isNull);
    expect(back.containsKey('profile'), isFalse,
        reason: '没有资料时不许写出空块');
    expect(captured.join('\n'), isNot(contains('profile')),
        reason: '没有 profile 是正常状态，不该打告警');
  });

  test('profile 不是对象 / 字段非字符串或空串 ⇒ 回落并打一行日志', () {
    // ① 整块不是对象。
    AppConfig.resetProfileBlockReportForTests();
    final captured = <String>[];
    final original = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) captured.add(message);
    };
    AppConfig wrongBlock;
    try {
      wrongBlock = AppConfig.fromJson(<String, dynamic>{
        ...baseJson(),
        'profile': 'alice',
      });
    } finally {
      debugPrint = original;
    }
    // ignore: avoid_print
    print('[用户资料] 非对象 profile ⇒ ${wrongBlock.profile} 日志=$captured');
    expect(wrongBlock.profile, isNull);
    expect(captured.where((line) => line.contains('profile')).length, 1);

    // ② 字段类型/空串错：逐项各打一行。
    final fields = <String, Object?>{
      'avatar_path': 123,
      'user_id': '',
    };
    for (final entry in fields.entries) {
      UserProfile.resetProfileReportForTests();
      final lines = <String>[];
      final saved = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null) lines.add(message);
      };
      UserProfile parsed;
      try {
        parsed = UserProfile.fromJson(<String, dynamic>{entry.key: entry.value});
      } finally {
        debugPrint = saved;
      }
      final fieldLines = lines.where((line) => line.contains(entry.key)).toList();
      // ignore: avoid_print
      print('[用户资料] 非法字段 ${entry.key}=${entry.value} ⇒ '
          '${parsed.toJson()} 字段日志行数=${fieldLines.length}');
      expect(parsed.isEmpty, isTrue);
      expect(fieldLines.length, 1, reason: '${entry.key} 的非法值应打且只打一行日志');
    }
  });

  test('字段缺席静默：只给 user_id 时不因缺 avatar_path 打日志', () {
    UserProfile.resetProfileReportForTests();
    final captured = <String>[];
    final original = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) captured.add(message);
    };
    AppConfig config;
    try {
      config = AppConfig.fromJson(withProfile({'user_id': 'a'}));
    } finally {
      debugPrint = original;
    }
    // ignore: avoid_print
    print('[用户资料] 只给 user_id：profile=${config.profile?.toJson()} 日志=$captured');
    expect(config.profile!.userId, 'a');
    expect(config.profile!.avatarPath, isNull);
    expect(captured.join('\n'), isNot(contains('avatar_path')),
        reason: '缺 avatar_path 是正常状态，不该打日志');
    expect(config.profile!.identitySeed, 'a');
  });

  test('没有 user_id 时 identitySeed 回落到常量缺省值', () {
    final config = AppConfig.fromJson(withProfile({'avatar_path': r'C:\tmp\a.png'}));
    // ignore: avoid_print
    print('[用户资料] 缺 user_id ⇒ seed=${config.profile!.identitySeed} '
        '常量=${UserProfile.kDefaultUserSeed}');
    expect(config.profile!.userId, isNull);
    expect(config.profile!.identitySeed, UserProfile.kDefaultUserSeed);
    expect(UserProfile.kDefaultUserSeed, 'local-user');
  });

  test('copyWith(clearProfile: true) 能清掉 profile；不带该参数时保留', () {
    final config = AppConfig.fromJson(withProfile({'user_id': 'alice'}));
    final kept = config.copyWith(providers: config.providers);
    final cleared = config.copyWith(clearProfile: true);
    // ignore: avoid_print
    print('[用户资料] 保留=${kept.profile?.toJson()} 清除=${cleared.profile}');
    expect(kept.profile?.userId, 'alice');
    expect(cleared.profile, isNull,
        reason: 'clearProfile 必须真的清掉（不能被 ?? 兜住）');
    expect(cleared.toJson().containsKey('profile'), isFalse);
  });

  test('toJson 只在至少一项有值时写块', () {
    final onlyAvatar = AppConfig.fromJson(withProfile({'avatar_path': r'C:\tmp\a.png'}));
    final onlyUser = AppConfig.fromJson(withProfile({'user_id': 'bob'}));
    final emptyString = UserProfile.fromJson(<String, dynamic>{
      'avatar_path': '',
      'user_id': '',
    });
    // ignore: avoid_print
    print('[用户资料] toJson：avatar=${onlyAvatar.toJson()['profile']} '
        'user=${onlyUser.toJson()['profile']} empty=${emptyString.toJson()}');
    expect(onlyAvatar.toJson()['profile'], {'avatar_path': r'C:\tmp\a.png'});
    expect(onlyUser.toJson()['profile'], {'user_id': 'bob'});
    expect(emptyString.isEmpty, isTrue);
    expect(emptyString.toJson(), isEmpty);
  });
}
