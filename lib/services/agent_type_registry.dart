import '../models/agent_type_config.dart';

/// **模板**注册表：只装可复用的 Agent 类型定义（`AgentTypeConfig`）。
///
/// 运行中的 Agent 实例**不在这里** —— 它们由 `AgentRegistry` 按上下文句柄管理
/// （change `add-agent-object-and-templates` 决策 2）。两个概念混在一起会让
/// "模板"与"某个正在跑的实例"无法区分，也会让模板列表里冒出运行态对象。
class AgentTypeRegistry {
  final Map<String, AgentTypeConfig> _types = {};

  /// 载入配置时的登记：同名覆盖（配置文件就是真相）。
  void register(AgentTypeConfig config) {
    _types[config.name] = config;
  }

  /// 添加一个**新**模板。同名已存在时抛出 [DuplicateAgentTypeException]，
  /// 不会静默覆盖（覆盖走 [update]）。
  void add(AgentTypeConfig config) {
    if (_types.containsKey(config.name)) {
      throw DuplicateAgentTypeException(config.name);
    }
    _types[config.name] = config;
  }

  /// 更新一个**已存在**模板，其它模板不受影响。不存在时抛出
  /// [MissingAgentTypeException]。
  void update(AgentTypeConfig config) {
    if (!_types.containsKey(config.name)) {
      throw MissingAgentTypeException(config.name);
    }
    _types[config.name] = config;
  }

  /// 删除一个模板（change `web-management-ui` D10，additive）。
  ///
  /// 返回是否真的删掉了：不存在返回 false（调用方据此给可归因结果，不假装成功）。
  /// **产品层守卫**（general 不可删 / 被会话引用拒删）在调用方实现，这里只做注册表
  /// 本分：删掉这一条定义，不碰运行中的实例。
  bool remove(String name) => _types.remove(name) != null;

  bool contains(String name) => _types.containsKey(name);

  AgentTypeConfig? lookup(String name) => _types[name];

  List<String> listNames() => _types.keys.toList();

  /// 只读快照，供界面列出模板时使用。
  List<AgentTypeConfig> list() => List<AgentTypeConfig>.unmodifiable(_types.values);

  /// 全部模板名的只读集合。
  Set<String> get names => Set<String>.unmodifiable(_types.keys);

  void clear() => _types.clear();
}

class DuplicateAgentTypeException implements Exception {
  final String name;
  DuplicateAgentTypeException(this.name);

  @override
  String toString() => 'Agent 模板 "$name" 已存在：添加被拒绝，既有定义保持不变。';
}

class MissingAgentTypeException implements Exception {
  final String name;
  MissingAgentTypeException(this.name);

  @override
  String toString() => 'Agent 模板 "$name" 不存在：更新被拒绝，不会新建同名模板。';
}
