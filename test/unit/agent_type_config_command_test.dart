import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/models/agent_type_config.dart';

/// 命令工具的配置项解析与回落（change `add-command-tool` 建立，change
/// `spill-large-tool-output` 改写）。
///
/// 覆盖哪几件事：
///   1. 两个超时键缺失时取缺省值（120000 / 600000）；
///   2. 写成非法值（0 / 负数 / 字符串）时逐个回落到各自的缺省值；
///   3. 配了合法的值时真的按配的来（不是"解析完就丢掉"）；
///   4. `toJson` 把两个超时键写回，让它们在 `~/.aliasagent/config.json` 里看得见；
///   5. **两个输出上限键已废弃**：读到不报错、不影响任何值、也不再写回
///      （`command_max_output_chars` / `command_output_full_chars`）。
///
/// 改前 → 改后的对照（`spill-large-tool-output` tasks 6.2 的同批改动）：
///   - 改前第 1/2/3 条断言里还有 `commandMaxOutputChars`（8000 / 抬到下限 1000）与
///     `commandOutputFullChars`（2000000 / 50000）两组值；
///   - 改后这两组值不再存在：头尾预览长度改由顶层 `spill.preview_chars` 决定
///     （判据见 `test/unit/spill_config_test.dart`）。新断言比旧的更严 ——
///     它额外要求"旧键不被写回"，旧版没有这条。
void main() {
  const baseJson = {
    'provider': 'anthropic',
    'model': 'deepseek-v4-pro',
    'system_prompt': 'hi',
  };

  // ⚠️ 这条必须排在文件最前面：`_deprecatedKeysReported` 是静态集合，每个键只报一次。
  // 只要别处先解析过一次带旧键的配置，这里就再也捕获不到告警了。
  test('两个旧输出上限键读入时打一行「已废弃」告警（不许静默忽略）', () {
    // tasks 11.1：`specs/command-tool` 三处要求"读到旧键 SHALL 打一行告警"，
    // 但此前没有任何用例钉它 —— 删掉 debugPrint 也不会有人发现。
    final captured = <String>[];
    final original = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) captured.add(message);
    };
    try {
      AgentTypeConfig.fromJson('general', {
        ...baseJson,
        'command_max_output_chars': 1234,
        'command_output_full_chars': 5678,
      });
    } finally {
      debugPrint = original;
    }
    // ignore: avoid_print
    print('[配置] 11.1 捕获到的告警行：$captured');
    expect(captured, isNotEmpty, reason: '读到旧键必须打告警，不许静默忽略');
    final joined = captured.join('\n');
    expect(joined, contains('command_max_output_chars'));
    expect(joined, contains('command_output_full_chars'));
    expect(joined, contains('已废弃'));
  });

  test('两个超时键缺失 → 取缺省值', () {
    final cfg =
        AgentTypeConfig.fromJson('general', Map<String, dynamic>.from(baseJson));
    // ignore: avoid_print
    print('[配置] 缺省: timeout=${cfg.commandTimeoutMs} '
        'maxTimeout=${cfg.commandMaxTimeoutMs}');
    expect(cfg.commandTimeoutMs, AgentTypeConfig.kDefaultCommandTimeoutMs);
    expect(cfg.commandMaxTimeoutMs, AgentTypeConfig.kDefaultCommandMaxTimeoutMs);
  });

  test('非法值 → 逐个回落到缺省值', () {
    final cfg = AgentTypeConfig.fromJson('general', {
      ...baseJson,
      'command_timeout_ms': 0,
      'command_max_timeout_ms': -5,
    });
    // ignore: avoid_print
    print('[配置] 非法值回落: timeout=${cfg.commandTimeoutMs} '
        'maxTimeout=${cfg.commandMaxTimeoutMs}');
    expect(cfg.commandTimeoutMs, AgentTypeConfig.kDefaultCommandTimeoutMs);
    expect(cfg.commandMaxTimeoutMs, AgentTypeConfig.kDefaultCommandMaxTimeoutMs);
  });

  test('配了合法的值 → 真的按配的来，并写回 toJson', () {
    final cfg = AgentTypeConfig.fromJson('general', {
      ...baseJson,
      'command_timeout_ms': 5000,
      'command_max_timeout_ms': 20000,
    });
    // ignore: avoid_print
    print('[配置] 按配置: timeout=${cfg.commandTimeoutMs} '
        'maxTimeout=${cfg.commandMaxTimeoutMs}');
    expect(cfg.commandTimeoutMs, 5000);
    expect(cfg.commandMaxTimeoutMs, 20000);

    final back = cfg.toJson();
    expect(back['command_timeout_ms'], 5000);
    expect(back['command_max_timeout_ms'], 20000);
  });

  test('两个超时键始终写回（即使全是缺省值）', () {
    final cfg =
        AgentTypeConfig.fromJson('general', Map<String, dynamic>.from(baseJson));
    final back = cfg.toJson();
    expect(back.containsKey('command_timeout_ms'), isTrue);
    expect(back.containsKey('command_max_timeout_ms'), isTrue);
  });

  test('两个输出上限键已废弃：读进来不报错、不影响任何值、也不再写回', () {
    final cfg = AgentTypeConfig.fromJson('general', {
      ...baseJson,
      'command_max_output_chars': 1234,
      'command_output_full_chars': 50000,
    });
    final back = cfg.toJson();
    // ignore: avoid_print
    print('[配置] 旧键 1234/50000 ⇒ 解析正常；写回里还有旧键吗：'
        '${back.containsKey('command_max_output_chars')}/'
        '${back.containsKey('command_output_full_chars')}');
    // 读进来不报错：上面这行没抛异常即成立
    expect(cfg.commandTimeoutMs, AgentTypeConfig.kDefaultCommandTimeoutMs);
    // 不再写回（写回去等于告诉用户这两个键还有用）
    expect(back.containsKey('command_max_output_chars'), isFalse);
    expect(back.containsKey('command_output_full_chars'), isFalse);
  });
}
