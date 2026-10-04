import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/models/agent_type_config.dart';

/// 命令工具四个配置项的解析与回落（change add-command-tool，tasks.md 5.5）。
///
/// 覆盖哪几件事：
///   1. 四个键缺失时取缺省值（120000 / 600000 / 8000 / 2000000）；
///   2. 写成非法值（0 / 负数 / 字符串）时逐个回落到各自的缺省值；
///   3. 字符上限配得比下限（1000）还小时被抬到下限；
///   4. 配了合法的值时真的按配的来（不是"解析完就丢掉"）；
///   5. `toJson` 把四个键写回，让它们在 `~/.aliasagent/config.json` 里看得见。
void main() {
  const baseJson = {
    'provider': 'anthropic',
    'model': 'deepseek-v4-pro',
    'system_prompt': 'hi',
  };

  test('四个键缺失 → 全部取缺省值', () {
    final cfg = AgentTypeConfig.fromJson('general', Map<String, dynamic>.from(baseJson));
    // ignore: avoid_print
    print('[配置] 缺省: timeout=${cfg.commandTimeoutMs} '
        'maxTimeout=${cfg.commandMaxTimeoutMs} '
        'maxOutputChars=${cfg.commandMaxOutputChars} '
        'fullOutputChars=${cfg.commandOutputFullChars}');
    expect(cfg.commandTimeoutMs, AgentTypeConfig.kDefaultCommandTimeoutMs);
    expect(cfg.commandMaxTimeoutMs, AgentTypeConfig.kDefaultCommandMaxTimeoutMs);
    expect(cfg.commandMaxOutputChars, AgentTypeConfig.kDefaultCommandMaxOutputChars);
    expect(cfg.commandOutputFullChars, AgentTypeConfig.kDefaultCommandOutputFullChars);
  });

  test('非法值 → 逐个回落到缺省值', () {
    final cfg = AgentTypeConfig.fromJson('general', {
      ...baseJson,
      'command_timeout_ms': 0,
      'command_max_timeout_ms': -5,
      'command_max_output_chars': 'not a number',
      'command_output_full_chars': 0,
    });
    // ignore: avoid_print
    print('[配置] 非法值回落: timeout=${cfg.commandTimeoutMs} '
        'maxTimeout=${cfg.commandMaxTimeoutMs} '
        'maxOutputChars=${cfg.commandMaxOutputChars} '
        'fullOutputChars=${cfg.commandOutputFullChars}');
    expect(cfg.commandTimeoutMs, AgentTypeConfig.kDefaultCommandTimeoutMs);
    expect(cfg.commandMaxTimeoutMs, AgentTypeConfig.kDefaultCommandMaxTimeoutMs);
    expect(cfg.commandMaxOutputChars, AgentTypeConfig.kDefaultCommandMaxOutputChars);
    expect(cfg.commandOutputFullChars, AgentTypeConfig.kDefaultCommandOutputFullChars);
  });

  test('字符上限低于下限 → 被抬到下限', () {
    final cfg = AgentTypeConfig.fromJson('general', {
      ...baseJson,
      'command_max_output_chars': 200,
    });
    // ignore: avoid_print
    print('[配置] 200 被抬到: ${cfg.commandMaxOutputChars}');
    expect(cfg.commandMaxOutputChars, AgentTypeConfig.kMinCommandMaxOutputChars);
    expect(cfg.commandMaxOutputChars, 1000);
  });

  test('配了合法的值 → 真的按配的来，并写回 toJson', () {
    final cfg = AgentTypeConfig.fromJson('general', {
      ...baseJson,
      'command_timeout_ms': 5000,
      'command_max_timeout_ms': 20000,
      'command_max_output_chars': 1234,
      'command_output_full_chars': 50000,
    });
    // ignore: avoid_print
    print('[配置] 按配置: timeout=${cfg.commandTimeoutMs} '
        'maxTimeout=${cfg.commandMaxTimeoutMs} '
        'maxOutputChars=${cfg.commandMaxOutputChars} '
        'fullOutputChars=${cfg.commandOutputFullChars}');
    expect(cfg.commandTimeoutMs, 5000);
    expect(cfg.commandMaxTimeoutMs, 20000);
    expect(cfg.commandMaxOutputChars, 1234);
    expect(cfg.commandOutputFullChars, 50000);

    final back = cfg.toJson();
    // ignore: avoid_print
    print('[配置] 写回的四个键: ${{
      'command_timeout_ms': back['command_timeout_ms'],
      'command_max_timeout_ms': back['command_max_timeout_ms'],
      'command_max_output_chars': back['command_max_output_chars'],
      'command_output_full_chars': back['command_output_full_chars'],
    }}');
    expect(back['command_timeout_ms'], 5000);
    expect(back['command_max_timeout_ms'], 20000);
    expect(back['command_max_output_chars'], 1234);
    expect(back['command_output_full_chars'], 50000);
  });

  test('四个键始终写回（即使全是缺省值）', () {
    final cfg = AgentTypeConfig.fromJson('general', Map<String, dynamic>.from(baseJson));
    final back = cfg.toJson();
    // ignore: avoid_print
    print('[配置] 缺省时写回: ${{
      'command_timeout_ms': back['command_timeout_ms'],
      'command_max_timeout_ms': back['command_max_timeout_ms'],
      'command_max_output_chars': back['command_max_output_chars'],
      'command_output_full_chars': back['command_output_full_chars'],
    }}');
    expect(back.containsKey('command_timeout_ms'), isTrue);
    expect(back.containsKey('command_max_timeout_ms'), isTrue);
    expect(back.containsKey('command_max_output_chars'), isTrue);
    expect(back.containsKey('command_output_full_chars'), isTrue);
  });
}
