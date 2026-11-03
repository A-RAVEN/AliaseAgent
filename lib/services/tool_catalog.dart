import '../models/agent_type_config.dart';
import '../models/app_config.dart';

/// 未知工具名：**显式报错并列出名字**，不静默从请求里删掉。
class UnknownToolsException implements Exception {
  final List<String> names;
  final String context;

  const UnknownToolsException(this.names, {this.context = ''});

  @override
  String toString() => '未知工具：${names.join("、")}'
      '${context.isEmpty ? "" : "（$context）"}：不在 ToolCatalog 中。'
      '不会静默丢弃；请修正模板的工具清单。';
}

/// 工具定义的**唯一只读目录**。
///
/// 工具定义原来只活在 `lib/main.dart` 的私有字段 `_toolDefs` 里，菜单、Agent 与
/// 测试各拿不到同一份真相。现在 `_initSearchAndTools()` 仍然负责"什么时候注册哪些
/// 工具"（基础工具在 await 之前同步注册、浏览器四件套与搜索工具按可用性条件注册），
/// 但它把结果写进本目录；读取方（Agent、模板编辑器、只读测试出口）只从目录读。
///
/// 目录对外是只读视图（[definitions] / [names] 均不可修改）；修改只能走
/// [seed]、[registerDynamic] 与 [reset] 这三个维护入口。
class ToolCatalog {
  ToolCatalog._();

  /// 进程内唯一目录（产品只有一个工具来源）。
  static final ToolCatalog instance = ToolCatalog._();

  final Map<String, Map<String, dynamic>> _defs = <String, Map<String, dynamic>>{};

  /// 当前目录里的全部工具定义（只读）。
  Map<String, Map<String, dynamic>> get definitions =>
      Map<String, Map<String, dynamic>>.unmodifiable(_defs);

  /// 当前目录里的全部工具名（只读）。
  List<String> get names => List<String>.unmodifiable(_defs.keys);

  bool contains(String name) => _defs.containsKey(name);

  Map<String, dynamic>? definition(String name) => _defs[name];

  /// 当前目录里的工具名集合（只读，供模板校验使用）。
  Set<String> get nameSet => Set<String>.unmodifiable(_defs.keys);

  /// 用一份完整定义表替换目录内容（`_initSearchAndTools()` 同步/条件注册后调用）。
  void seed(Map<String, Map<String, dynamic>> defs) {
    _defs
      ..clear()
      ..addAll(defs);
  }

  /// 条件注册单条工具（浏览器 / 搜索工具就绪时使用）。
  void registerDynamic(String name, Map<String, dynamic> definition) {
    _defs[name] = definition;
  }

  void reset() => _defs.clear();

  /// 按模板的工具清单挑出实际要交给模型的定义，保持清单顺序。
  ///
  /// 任何不在目录里的名字都会让整次解析**失败**并列出名字（不静默少给）。
  List<Map<String, dynamic>> resolve(List<String> toolNames,
      {String context = ''}) {
    final unknown = <String>[
      for (final name in toolNames)
        if (!_defs.containsKey(name)) name,
    ];
    if (unknown.isNotEmpty) {
      throw UnknownToolsException(unknown, context: context);
    }
    return [
      for (final name in toolNames) _defs[name]!,
    ];
  }

  /// 基础工具名（首启默认清单就是这一份，顺序与注册顺序一致）。
  ///
  /// 覆盖 `read_file` / `write_file` / `edit_file` / `list_dir` /
  /// `get_current_time` / `glob_file` / `grep_file` / `read_image` /
  /// `run_command` / `read_spill` / `spawn_subagent` —— 这十一项都是当前产品
  /// 无条件提供的基础能力（`spawn_subagent` 的实际执行见 `lib/services/subagent_runner.dart`）。
  static const List<String> kBaseToolNames = [
    'read_file',
    'write_file',
    'edit_file',
    'list_dir',
    'get_current_time',
    'glob_file',
    'grep_file',
    'read_image',
    'run_command',
    'read_spill',
    'spawn_subagent',
  ];

  /// 旧版首启写出的两项默认工具清单（`read_file`、`list_dir`）。
  ///
  /// 兼容判断必须**针对这个形状**：不多不少正好这两项，且顺序不限。
  static bool isLegacyDefaultTools(List<String> tools) {
    if (tools.length != 2) return false;
    return tools.toSet().containsAll(const ['read_file', 'list_dir']);
  }
}

/// 旧默认工具清单迁移的结果。
class ToolListMigrationResult {
  final AppConfig config;

  /// 每条都是给用户看的一句话（界面上显示；不只是一行日志）。
  final List<String> notices;

  /// 被升级的模板名。
  final List<String> migratedTemplates;

  const ToolListMigrationResult({
    required this.config,
    required this.notices,
    required this.migratedTemplates,
  });

  bool get changed => migratedTemplates.isNotEmpty;
}

/// 旧版首启写出的两项默认清单 → 当前基础工具清单。
///
/// 只改**旧默认形状**（恰好 `read_file` + `list_dir` 两项）：用户自定义的其它清单
/// （收窄或扩展过的）原样保留。升级必须**可见**：返回的
/// [ToolListMigrationResult.notices] 由界面显示，不能只写一行日志。
class ToolListMigration {
  const ToolListMigration._();

  static ToolListMigrationResult migrate(AppConfig config) {
    final notices = <String>[];
    final migrated = <String>[];
    final types = <String, AgentTypeConfig>{};
    for (final entry in config.agentTypes.entries) {
      final template = entry.value;
      if (!ToolCatalog.isLegacyDefaultTools(template.tools)) {
        types[entry.key] = template;
        continue;
      }
      final upgraded = AgentTypeConfig(
        name: template.name,
        provider: template.provider,
        model: template.model,
        systemPrompt: template.systemPrompt,
        tools: List<String>.unmodifiable(ToolCatalog.kBaseToolNames),
        thinkingEffort: template.thinkingEffort,
        maxContextTokens: template.maxContextTokens,
        compactionThresholdPercent: template.compactionThresholdPercent,
        compactionWaitThresholdPercent:
            template.compactionWaitThresholdPercent,
        inputModalities: template.inputModalities,
        commandTimeoutMs: template.commandTimeoutMs,
        commandMaxTimeoutMs: template.commandMaxTimeoutMs,
        standingRequirements: template.standingRequirements,
      );
      types[entry.key] = upgraded;
      migrated.add(entry.key);
      notices.add('Agent 模板 "${entry.key}" 的工具清单是旧版首启默认的两项'
          '（read_file、list_dir），已升级为当前 ${ToolCatalog.kBaseToolNames.length} '
          '项基础工具；自定义清单不会被改动。');
    }
    return ToolListMigrationResult(
      config: migrated.isEmpty ? config : config.copyWith(agentTypes: types),
      notices: List<String>.unmodifiable(notices),
      migratedTemplates: List<String>.unmodifiable(migrated),
    );
  }
}
