import 'package:meta/meta.dart';

import '../services/logging.dart';

/// 本机用户的资料块（配置文件顶层 `profile`，change `chat-bubbles-avatars` design D2）。
///
/// 两个可选键：
///   - `avatar_path`：用户头像的上传覆盖路径（附件目录内一张图片的绝对路径）；
///   - `user_id`：用户标识，用作身份图案的哈希种子。
///
/// **读取侧口径**（design D3）：字段缺席静默读作"没有该值"；字段存在但不是字符串、
/// 或去掉空白后为空串 ⇒ 读作"没有该值"并打一行日志。配置里的空串**不是**清除指令。
///
/// `identitySeed` 是**读取期派生值**（`userId ?? kDefaultUserSeed`），MUST NOT 写进
/// 配置文件：`config.get` 返回它，是为了让 web 端不必复制这个常量。
class UserProfile {
  /// 缺省的身份图案种子（用户没手写 `user_id` 时用它）。
  ///
  /// 系统 MUST NOT 自动生成 `user_id`、也 MUST NOT 在保存时凭空写回一个 —— 只有用户
  /// 显式在配置里写了才有。
  static const String kDefaultUserSeed = 'local-user';

  final String? avatarPath;
  final String? userId;

  const UserProfile({this.avatarPath, this.userId});

  /// 两项都没有 ⇒ 不该写出 `profile` 块（旧配置不因升级产生无意义差异）。
  bool get isEmpty => avatarPath == null && userId == null;

  /// 实际生效的身份图案种子：`user_id` 若存在，否则常量缺省值。
  String get identitySeed => userId ?? kDefaultUserSeed;

  /// 只在第一次遇到非法字段值时打一行日志（免得每次读配置都喊一次）。
  static bool _illegalFieldReported = false;

  /// 仅测试用：清掉"已经报过一次非法字段"的标记，让日志断言不受用例顺序影响。
  @visibleForTesting
  static void resetProfileReportForTests() {
    _illegalFieldReported = false;
  }

  factory UserProfile.fromJson(Map<String, dynamic> json) => UserProfile(
        avatarPath: _parseField(json, 'avatar_path'),
        userId: _parseField(json, 'user_id'),
      );

  /// 解析一个可选字符串字段：缺席静默；存在但不是非空字符串 ⇒ 回落 null 并打一行日志。
  static String? _parseField(Map<String, dynamic> json, String key) {
    if (!json.containsKey(key)) return null;
    final raw = json[key];
    if (raw is String && raw.trim().isNotEmpty) return raw.trim();
    if (!_illegalFieldReported) {
      _illegalFieldReported = true;
      debugPrint('[AliasAgent] profile.$key=$raw is not a non-empty string — '
          'treating it as "no value"');
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
        if (avatarPath != null) 'avatar_path': avatarPath,
        if (userId != null) 'user_id': userId,
      };
}
