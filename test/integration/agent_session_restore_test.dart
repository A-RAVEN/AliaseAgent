import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/main.dart';
import 'package:alias_agent/models/agent_type_config.dart';
import 'package:alias_agent/models/app_config.dart';
import 'package:alias_agent/models/message.dart';
import 'package:alias_agent/models/provider_config.dart';
import 'package:alias_agent/models/session.dart';
import 'package:alias_agent/services/agent_config_resolver.dart';
import 'package:alias_agent/services/agent_factory.dart';
import 'package:alias_agent/services/agent_registry.dart';
import 'package:alias_agent/services/compaction/model_summary_provider.dart';
import 'package:alias_agent/services/provider_resolver.dart';
import 'package:alias_agent/services/session_repository.dart';
import 'package:alias_agent/services/summary_node_repository.dart';
import 'package:alias_agent/services/tool_catalog.dart';

import '../widget/helpers/fakes.dart';
import 'helpers/fake_sidecar.dart';

/// 会话按自己的 `agent_type` 创建 / 恢复 Agent（任务 2.4）。
///
/// 固定的是：非 `general` 会话用自己模板的模型执行；历史缺字段仍默认 `general`；
/// 已存储但模板不存在时给**可区分错误**且不退回 `general`；非法窗口在创建时失败；
/// 新建会话默认 `general`。
void main() {
  late FakeSidecar sidecar;
  late FakeMessageRepository msgRepo;
  late FakeSessionRepository sessionRepo;
  late AgentRegistry agents;

  Map<String, dynamic> def(String name) => {
        'name': name,
        'description': 'fake $name',
        'input_schema': {
          'type': 'object',
          'properties': {},
          'required': [],
        },
      };

  setUp(() {
    ToolCatalog.instance.seed({
      for (final n in ['read_file', 'write_file', 'run_command', 'list_dir'])
        n: def(n),
    });
    registry.clear();
    registry.register(const AgentTypeConfig(
      name: 'general',
      provider: 'test',
      model: 'general-model',
      systemPrompt: 'GENERAL',
      tools: ['read_file'],
      maxContextTokens: 100000,
    ));
    registry.register(const AgentTypeConfig(
      name: 'reviewer',
      provider: 'test',
      model: 'reviewer-model',
      systemPrompt: 'REVIEWER',
      tools: ['read_file', 'run_command'],
      thinkingEffort: 'max',
      maxContextTokens: 64000,
    ));
    resolver = ProviderResolver(const AppConfig(
      version: 1,
      providers: {
        'test': ProviderConfig(apiKey: 'sk-test', baseUrl: ''),
      },
    ));
    sidecar = FakeSidecar();
    msgRepo = FakeMessageRepository();
    sessionRepo = FakeSessionRepository([]);
    agents = AgentRegistry();
  });

  tearDown(() {
    ToolCatalog.instance.reset();
    registry.clear();
    resolver = null;
  });

  AgentFactory factory() => AgentFactory(
        templates: registry,
        providerResolver: () => resolver,
        config: const AppConfig(version: 1),
        sidecar: sidecar,
        sessionRepo: sessionRepo,
        messageRepo: msgRepo,
        summaryNodeRepo: SummaryNodeRepository(),
        registry: agents,
        summaryProvider: FakeSummaryProvider(),
        backgroundFoldEnabled: false,
        summaryStoreOpen: () => false,
      );

  Session session(String id, String agentType) => Session(
        id: id,
        title: 'Session $id',
        agentType: agentType,
        createdAt: 1,
        updatedAt: 1,
      );

  test('非 general 会话用自己模板的模型与配置执行', () async {
    final f = factory();
    final reviewer = await f.create(session('s-review', 'reviewer'));
    sidecar.queueChunk('ok');
    sidecar.queueDone();
    await reviewer.send('评审一下');

    // ignore: avoid_print
    print('  [OBS] reviewer 实例 model=${reviewer.config.model} '
        'template=${reviewer.config.templateName} '
        '请求 model=${sidecar.lastModel} tools=${sidecar.lastToolsJson}');
    expect(reviewer.config.templateName, 'reviewer');
    expect(reviewer.config.model, 'reviewer-model');
    expect(reviewer.config.maxContextTokens, 64000);
    expect(sidecar.lastModel, 'reviewer-model');
    expect(sidecar.lastToolsJson, contains('run_command'));
    expect(sidecar.lastThinkingEffort, 'max');
  });

  test('历史缺 agent_type 的会话仍默认 general', () async {
    final restored = Session.fromRow({
      'id': 's-legacy',
      'title': '旧会话',
      'created_at': 1,
      'updated_at': 1,
      // 故意没有 agent_type 列值
    });
    expect(restored.agentType, 'general');
    final agent = await factory().create(restored);
    // ignore: avoid_print
    print('  [OBS] 旧会话恢复模板=${agent.config.templateName} '
        'model=${agent.config.model}');
    expect(agent.config.templateName, 'general');
    expect(agent.config.model, 'general-model');
  });

  test('已存储但模板不存在 ⇒ 可区分错误并带模板名，不退回 general', () async {
    var message = '';
    try {
      await factory().create(session('s-ghost', 'ghost-template'));
      fail('缺失模板必须让创建失败');
    } on MissingAgentTemplateException catch (e) {
      message = e.toString();
    }
    // ignore: avoid_print
    print('  [OBS] 缺失模板错误：$message');
    expect(message, contains('ghost-template'));
    expect(message, contains('不会退回 general'));
    expect(agents.contains('s-ghost'), isFalse);
    expect(sidecar.sendHandles, isEmpty, reason: '没有发起任何模型请求');
  });

  test('非法窗口在创建时显式失败，不按 0 继续发送全文', () async {
    registry.register(const AgentTypeConfig(
      name: 'bad-window',
      provider: 'test',
      model: 'm',
      systemPrompt: '',
      tools: ['read_file'],
      maxContextTokens: 0,
    ));
    var message = '';
    try {
      await factory().create(session('s-bad', 'bad-window'));
      fail('零窗口必须让创建失败');
    } on InvalidAgentContextWindowException catch (e) {
      message = e.toString();
    }
    // ignore: avoid_print
    print('  [OBS] 非法窗口错误：$message');
    expect(message, contains('bad-window'));
    expect(message, contains('拒绝创建'));
    expect(sidecar.sendHandles, isEmpty);
  });

  test('新建会话默认 general（SessionRepository.create 的缺省 agentType）', () async {
    final repo = _FakeCreateSessionRepository();
    final f = AgentFactory(
      templates: registry,
      providerResolver: () => resolver,
      config: const AppConfig(version: 1),
      sidecar: sidecar,
      sessionRepo: repo,
      messageRepo: msgRepo,
      summaryNodeRepo: SummaryNodeRepository(),
      registry: agents,
      summaryProvider: FakeSummaryProvider(),
      backgroundFoldEnabled: false,
      summaryStoreOpen: () => false,
    );
    final created = await repo.create();
    // ignore: avoid_print
    print('  [OBS] 新建会话 agentType=${created.agentType}');
    expect(created.agentType, 'general');
    final agent = await f.create(created);
    expect(agent.config.templateName, 'general');
  });

  test('恢复既有会话：新实例按存储的模板读回历史并用自己的模型发送', () async {    // 第一次运行：reviewer 会话里已有一条历史消息。
    msgRepo.messages.add(MessageFactory.of(
      id: 'old-1',
      seq: 1,
      sessionId: 's-review',
      role: 'user',
      content: '之前问过的问题',
    ));
    final f1 = factory();
    final first = await f1.create(session('s-review', 'reviewer'));
    expect(first.messageHistory.single.content, '之前问过的问题');

    // 重启：新的工厂 / 注册表，从同一份会话与消息库恢复。
    final agents2 = AgentRegistry();
    final f2 = AgentFactory(
      templates: registry,
      providerResolver: () => resolver,
      config: const AppConfig(version: 1),
      sidecar: sidecar,
      sessionRepo: sessionRepo,
      messageRepo: msgRepo,
      summaryNodeRepo: SummaryNodeRepository(),
      registry: agents2,
      summaryProvider: FakeSummaryProvider(),
      backgroundFoldEnabled: false,
      summaryStoreOpen: () => false,
    );
    final restored = await f2.ensure(session('s-review', 'reviewer'));
    sidecar.queueChunk('恢复后的回复');
    sidecar.queueDone();
    await restored.send('继续');

    // ignore: avoid_print
    print('  [OBS] 恢复实例模板=${restored.config.templateName} '
        '历史条数=${restored.messageHistory.length} 请求 model=${sidecar.lastModel}');
    expect(restored.config.templateName, 'reviewer');
    expect(restored.messageHistory.any((m) => m.content == '之前问过的问题'),
        isTrue);
    expect(sidecar.lastModel, 'reviewer-model',
        reason: '恢复后也必须用会话自己模板的模型，而不是 general');
    expect(agents2.contains('s-review'), isTrue);
  });

  test('ensure 不复用模板名不一致的实例，也不复用退役中的实例', () async {
    final f = factory();
    final agent = await f.create(session('s-review', 'reviewer'));

    // 数据库里这个会话被改成了 general（例如别处直接改了库，没走显式切换路径）。
    var mismatch = '';
    try {
      await f.ensure(session('s-review', 'general'));
      fail('模板名不一致时 ensure 必须显式失败，不得返回旧实例');
    } on AgentTemplateMismatchException catch (e) {
      mismatch = e.toString();
    }
    // ignore: avoid_print
    print('  [OBS] 模板名不一致：$mismatch');
    expect(mismatch, contains('reviewer'));
    expect(mismatch, contains('general'));
    expect(identical(agents.lookup('s-review'), agent), isTrue,
        reason: '失败时旧实例仍注册着，不被静默替换');

    // 退役中的实例也不得被普通 ensure 复用。
    await agent.retire();
    var retiring = '';
    try {
      await f.ensure(session('s-review', 'reviewer'));
      fail('退役中的实例不得被 ensure 复用');
    } on AgentRetiringException catch (e) {
      retiring = e.toString();
    }
    // ignore: avoid_print
    print('  [OBS] 退役中：$retiring 退役标记=${agent.isRetiring} '
        'cancel=${sidecar.cancelHandles} dispose=${sidecar.disposeContextCalls}');
    expect(retiring, contains('退役'));
    expect(agent.isRetiring, isTrue);
    expect(sidecar.cancelHandles, isEmpty, reason: '退役不中断在途请求');
    expect(sidecar.disposeContextCalls, isEmpty, reason: '退役不销毁上下文');
  });
}

/// 只用于验证 `SessionRepository.create` 的缺省 agentType（与生产实现同义）。
class _FakeCreateSessionRepository implements SessionRepository {
  @override
  Future<Session> create({String? title, String? agentType}) async => Session(
        id: 'new-default',
        title: title ?? 'New Chat',
        agentType: agentType ?? 'general',
        createdAt: 1,
        updatedAt: 1,
      );

  @override
  Future<Session?> get(String id) async => null;

  @override
  Future<List<Session>> list() async => [];

  @override
  Future<void> delete(String id) async {}

  @override
  Future<void> updateTitle(String id, String title) async {}

  @override
  Future<bool> updateTitleIfDefault(String id, String text) async => false;

  @override
  Future<void> touch(String id) async {}

  @override
  Future<Session> updateAgentType(String id, String agentType) async {
    throw SessionAgentTypeUpdateException(
      sessionId: id,
      agentType: agentType,
      updatedRows: 0,
      message: '这个假仓库不保存任何行：没有更新到唯一既有行。',
    );
  }
}

/// 测试里造一条历史消息的便捷入口（构造参数较多，集中一次）。
class MessageFactory {
  static Message of({
    required String id,
    required int seq,
    required String sessionId,
    required String role,
    required String content,
  }) =>
      Message(
        id: id,
        seq: seq,
        sessionId: sessionId,
        role: role,
        content: content,
        createdAt: 1,
      );
}
