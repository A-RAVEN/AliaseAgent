import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/models/agent_type_config.dart';

/// 模板头像字段 `avatar_path` 的解析与写回（change `chat-bubbles-avatars` 任务 2.1 /
/// design D3 的「配置读取侧」口径）。
///
/// 覆盖哪几件事：
///   1. 带字符串 `avatar_path` 时真的解析出该路径；
///   2. **缺键静默**（没有头像的模板是正常状态，不是配置错误，不该刷日志）；
///   3. 数字 / 对象 / 空串 ⇒ 读作"没有覆盖"并各打一行日志点名 `avatar_path` 与原始值
///      （手误不被静默吞掉）；
///   4. `toJson` 只在有值时写回（缺席的模板不被补一个空键）。
///
/// 空串在**读取侧**不是清除指令：配置里出现空串是手误，读作"没有覆盖"。
/// 写入侧的三态（省略/null 不改、'' 清、非空设）在 `template.save` 的参数里，见
/// `test/integration/web_management_rpc_test.dart`。
void main() {
  const baseJson = <String, dynamic>{
    'provider': 'anthropic',
    'model': 'deepseek-v4-pro',
    'system_prompt': 'hi',
  };

  test('带 avatar_path 时解析出该路径', () {
    const path = r'C:\Users\me\.aliasagent\attachments\face.png';
    final cfg = AgentTypeConfig.fromJson('general', {
      ...baseJson,
      'avatar_path': path,
    });
    // ignore: avoid_print
    print('[头像字段] 解析结果="${cfg.avatarPath}"');
    expect(cfg.avatarPath, path);
  });

  test('缺 avatar_path 键 ⇒ 值为 null 且不打印告警', () {
    final captured = <String>[];
    final original = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) captured.add(message);
    };
    AgentTypeConfig cfg;
    try {
      cfg = AgentTypeConfig.fromJson('general', Map<String, dynamic>.from(baseJson));
    } finally {
      debugPrint = original;
    }
    // ignore: avoid_print
    print('[头像字段] 缺键：avatarPath=${cfg.avatarPath} 捕获到的日志=$captured');
    expect(cfg.avatarPath, isNull);
    expect(captured.join('\n'), isNot(contains('avatar_path')),
        reason: '缺键是正常状态，不该因为"没有头像"打日志');
  });

  test('数字 / 对象 / 空串 ⇒ 回落 null，并各打一行日志点名字段与原始值', () {
    final illegalValues = <Object?>[123, <String, dynamic>{'x': 1}, '', '   '];
    for (final illegal in illegalValues) {
      AgentTypeConfig.resetAvatarPathReportForTests();
      final captured = <String>[];
      final original = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null) captured.add(message);
      };
      AgentTypeConfig cfg;
      try {
        cfg = AgentTypeConfig.fromJson('general', {
          ...baseJson,
          'avatar_path': illegal,
        });
      } finally {
        debugPrint = original;
      }
      final joined = captured.join('\n');
      final avatarLines = captured.where((line) => line.contains('avatar_path')).toList();
      // ignore: avoid_print
      print('[头像字段] 非法值 ${illegal.runtimeType}=$illegal ⇒ '
          'avatarPath=${cfg.avatarPath} 头像日志行数=${avatarLines.length}');
      expect(cfg.avatarPath, isNull, reason: '非法值必须读作"没有覆盖"');
      expect(avatarLines.length, 1, reason: '每个非法值应恰好一行头像日志（不刷屏）');
      expect(joined, contains('avatar_path'));
      expect(joined, contains('$illegal'));
    }
  });

  test('toJson 只在有值时写回（缺席模板不被补空键）', () {
    final withAvatar = AgentTypeConfig.fromJson('general', {
      ...baseJson,
      'avatar_path': r'C:\tmp\a.png',
    });
    final without = AgentTypeConfig.fromJson(
        'general', Map<String, dynamic>.from(baseJson));
    final withBack = withAvatar.toJson();
    final withoutBack = without.toJson();
    // ignore: avoid_print
    print('[头像字段] toJson 带头像=${withBack['avatar_path']} '
        '不带头像 hasKey=${withoutBack.containsKey('avatar_path')}');
    expect(withBack['avatar_path'], r'C:\tmp\a.png');
    expect(withoutBack.containsKey('avatar_path'), isFalse,
        reason: '没有头像的模板不许被写回一个空键');
  });
}
