import 'agent.dart';

/// 运行中 Agent 实例的注册表：**按上下文句柄**管理实例。
///
/// 与 `AgentTypeRegistry`（模板定义）是两个不同对象：模板可以被反复修改、运行实例
/// 不能被当成模板；反过来，销毁一个实例也不许把它对应的模板删掉。
class AgentRegistry {
  final Map<String, Agent> _agents = <String, Agent>{};

  /// 登记一个刚创建好的实例（同一句柄重复登记会覆盖，调用方应先 [lookup]）。
  void register(Agent agent) {
    _agents[agent.sessionId] = agent;
  }

  Agent? lookup(String handle) => _agents[handle];

  bool contains(String handle) => _agents.containsKey(handle);

  /// 当前运行的实例（只读快照）。
  List<Agent> get instances => List<Agent>.unmodifiable(_agents.values);

  List<String> get handles => List<String>.unmodifiable(_agents.keys);

  /// 只从注册表移除，不销毁（销毁走 [disposeAndRemove]）。
  Agent? remove(String handle) => _agents.remove(handle);

  /// 销毁并移除：先等整轮 Future 与后台压缩写库，再 `disposeContext`，最后释放实例。
  Future<void> disposeAndRemove(String handle) async {
    final agent = _agents.remove(handle);
    if (agent != null) await agent.dispose();
  }

  Future<void> disposeAll() async {
    final agents = List<Agent>.from(_agents.values);
    _agents.clear();
    for (final agent in agents) {
      await agent.dispose();
    }
  }

  void clear() => _agents.clear();
}
