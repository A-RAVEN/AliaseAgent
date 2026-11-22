// 无头 Dart 核心：组合根 + WebSocket/JSON-RPC 通道 + 本机静态服务。
//
// change `web-ui-core-shim` 任务 2.1 / 2.2 / 2.3 / 2.4：
//   - 组合根复刻 Flutter 入口的三段启动逻辑：sqflite ffi 工厂、工具目录播种与
//     条件注册（共享 `tool_bootstrap.dart`）、发送门禁与 summaryStoreOpen 真实谓词；
//   - `HttpServer.bind(loopbackIPv4, 0)` 由 OS 分配端口并回显 URL（D7）；
//   - 同一端口上提供 WebSocket 升级（`/ws`），走 JSON-RPC 2.0（D3）；
//   - `AgentCallbacks` → `agent.event` notification，序列化适配见
//     `event_serialization.dart`（D9）；
//   - serve `web/` 构建产物（默认 `<cwd>/web/dist`），缺产物时显式 503，不假装就绪；
//   - 单实例锁文件（D11）：在任何 DB / spill 操作之前取得。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../models/app_config.dart';
import '../models/compaction_status.dart';
import '../models/session.dart';
import '../services/agent.dart';
import '../services/agent_factory.dart';
import '../services/agent_registry.dart';
import '../services/agent_type_registry.dart';
import '../services/config_service.dart';
import '../services/database_service.dart';
import '../services/logging.dart';
import '../services/message_page.dart';
import '../services/message_repository.dart';
import '../services/provider_resolver.dart';
import '../services/session_repository.dart';
import '../services/sidecar_bridge.dart';
import '../services/skills/skill_catalog_service.dart';
import '../services/subagent_runner.dart';
import '../services/summary_node_repository.dart';
import '../services/tool_bootstrap.dart';
import 'core_lock.dart';
import 'event_serialization.dart';
import 'json_rpc.dart';

/// 通道协议版本（不是产品版本）：客户端可用 `core.ping` 核对。
const int kCoreProtocolVersion = 1;

/// 只绑回环地址（本机信任边界，无鉴权；见用户文档的已知限制）。
const String kCoreBindHost = '127.0.0.1';

/// 启动回显的 URL 形状（`<port>` 是 OS 实际分配值的占位说明，文档守卫读它）。
const String kCoreUrlTemplate = 'http://$kCoreBindHost:<port>';

/// 启动命令（用户文档与 `--help` 同源，文档守卫读它）。
const String kCoreEntryCommand = 'dart run bin/alias_agent_core.dart';

/// 暴露的 JSON-RPC 方法名（注册表与文档守卫共用这一份清单）。
const List<String> kCoreRpcMethodNames = <String>[
  'core.ping',
  'session.list',
  'message.query',
  'agent.send',
  'agent.cancel',
];

/// WebSocket 路径（与 web 客户端一致）。
const String kCoreWebSocketPath = '/ws';

/// 启动失败：带可归因信息，入口直接打印并退出（不假装就绪）。
class HeadlessCoreStartupException implements Exception {
  final String message;

  const HeadlessCoreStartupException(this.message);

  @override
  String toString() => message;
}

/// 一个已装配好的无头核心。
///
/// 依赖都从构造函数进：生产组合根用 [HeadlessCoreRunner.start]，测试用
/// [buildHeadlessCore] 注入假 sidecar 与临时数据库。
class HeadlessCore {
  HeadlessCore({
    required this.config,
    required this.sidecar,
    required this.sessionRepo,
    required this.messageRepo,
    required this.summaryNodeRepo,
    required this.templates,
    required this.agents,
    required this.factory,
    required this.subagentRunner,
    required Future<void> ready,
  }) : _ready = ready;

  final AppConfig config;
  final ISidecar sidecar;
  final SessionRepository sessionRepo;
  final MessageRepository messageRepo;
  final SummaryNodeRepository summaryNodeRepo;
  final AgentTypeRegistry templates;
  final AgentRegistry agents;
  final AgentFactory factory;
  final SubagentRunner subagentRunner;

  /// 发送门禁：工具目录播种（含条件注册）完成前不放行 `agent.send`。
  final Future<void> _ready;

  final JsonRpcDispatcher _rpc = JsonRpcDispatcher();
  final Set<WebSocket> _clients = <WebSocket>{};

  HttpServer? _server;
  String? _webRoot;
  CoreInstanceLock? _lock;
  bool _stopped = false;

  /// 实际监听端口（未启动时抛 StateError）。
  int get port {
    final server = _server;
    if (server == null) throw StateError('无头核心尚未启动');
    return server.port;
  }

  /// 回显给用户的回环 URL（OS 实际分配的端口）。
  Uri get url => Uri(scheme: 'http', host: kCoreBindHost, port: port);

  /// WebSocket 入口（客户端连接用）。
  Uri get websocketUrl =>
      url.replace(scheme: 'ws', path: kCoreWebSocketPath);

  /// 已注册的 RPC 方法（诊断 / 测试用）。
  List<String> get rpcMethods => _rpc.methodNames;

  /// 当前 WS 订阅者数量（测试可观察重连前后的订阅者）。
  int get clientCount => _clients.length;

  /// 绑定回环地址并开始服务。[port] 默认 0 = 由 OS 分配（D7）。
  Future<void> start({int port = 0, String? webRoot}) async {
    if (_server != null) throw StateError('无头核心已经启动');
    _webRoot = webRoot;
    _registerMethods();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    _server = server;
    server.listen((request) {
      unawaited(_handleHttpRequest(request));
    }, onError: (Object error, StackTrace st) {
      debugPrint('[AliasAgent] 无头核心 HTTP 监听错误：$error\n$st');
    });
  }

  /// 停止服务：先断开 WS 客户端，再关服务器，最后释放 Agent / DB / 单实例锁。
  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    for (final client in List<WebSocket>.from(_clients)) {
      try {
        await client.close(WebSocketStatus.goingAway, 'core stopping');
      } catch (_) {
        // 已经断开：忽略。
      }
    }
    _clients.clear();
    final server = _server;
    _server = null;
    await server?.close(force: true);
    try {
      await agents.disposeAll();
    } catch (e) {
      debugPrint('[AliasAgent] 无头核心销毁 Agent 失败：$e');
    }
    try {
      await DatabaseService.close();
    } catch (e) {
      debugPrint('[AliasAgent] 无头核心关闭数据库失败：$e');
    }
    final lock = _lock;
    _lock = null;
    await lock?.release();
  }

  // ---------------------------------------------------------------------------
  // HTTP / WebSocket
  // ---------------------------------------------------------------------------

  Future<void> _handleHttpRequest(HttpRequest request) async {
    try {
      if (request.uri.path == kCoreWebSocketPath) {
        await _handleWebSocket(request);
        return;
      }
      await _serveStatic(request);
    } catch (e, st) {
      debugPrint('[AliasAgent] 无头核心处理请求失败：$e\n$st');
      try {
        _writeText(request.response, HttpStatus.internalServerError,
            'core request failed: $e');
      } catch (_) {
        // 响应已经关闭：忽略。
      }
    }
  }

  Future<void> _handleWebSocket(HttpRequest request) async {
    if (!WebSocketTransformer.isUpgradeRequest(request)) {
      _writeText(request.response, HttpStatus.badRequest,
          'WebSocket upgrade required at $kCoreWebSocketPath');
      return;
    }
    final socket = await WebSocketTransformer.upgrade(request);
    _clients.add(socket);
    socket.listen((data) async {
      String? response;
      if (data is String) {
        response = await _rpc.handleRawText(data);
      } else {
        response = jsonEncode(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': null,
          'error': <String, dynamic>{
            'code': JsonRpcErrorCode.invalidRequest,
            'message': 'Invalid Request: 通道只接受 JSON 文本帧',
          },
        });
      }
      if (response != null && socket.readyState == WebSocket.open) {
        socket.add(response);
      }
    }, onDone: () {
      _clients.remove(socket);
    }, onError: (Object _, StackTrace _) {
      _clients.remove(socket);
    });
  }

  /// 静态服务：生产 serve `web/` 构建产物；缺产物时 503 + 可归因提示。
  Future<void> _serveStatic(HttpRequest request) async {
    final response = request.response;
    if (request.method != 'GET' && request.method != 'HEAD') {
      _writeText(response, HttpStatus.methodNotAllowed,
          '只支持 GET/HEAD 静态请求（WebSocket 走 $kCoreWebSocketPath）');
      return;
    }
    final root = _webRoot;
    if (root == null || !Directory(root).existsSync()) {
      _writeText(
        response,
        HttpStatus.serviceUnavailable,
        'web 客户端产物不存在：${root ?? '(未配置 --web-root)'}\n'
        '先构建：cd web && npm install && npm run build',
      );
      return;
    }

    final rootAbs = p.normalize(p.absolute(root));
    var relative = request.uri.pathSegments.join('/');
    if (relative.isEmpty) relative = 'index.html';
    var file = File(p.normalize(p.join(rootAbs, relative)));
    if (!p.isWithin(rootAbs, file.path)) {
      _writeText(response, HttpStatus.forbidden, '拒绝访问 web 根之外的文件');
      return;
    }
    if (!file.existsSync()) {
      // 单页应用回退：没有扩展名的路径回 index.html；资源路径仍 404（不拿 HTML
      // 冒充 JS，否则客户端只看到 MIME 错误）。
      final index = File(p.join(rootAbs, 'index.html'));
      if (p.extension(relative).isEmpty && index.existsSync()) {
        file = index;
      } else {
        _writeText(response, HttpStatus.notFound, '静态文件不存在：$relative');
        return;
      }
    }
    response.statusCode = HttpStatus.ok;
    response.headers.contentType = _contentTypeFor(file.path);
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    if (request.method == 'HEAD') {
      await response.close();
      return;
    }
    await response.addStream(file.openRead());
    await response.close();
  }

  void _writeText(HttpResponse response, int status, String body) {
    response.statusCode = status;
    response.headers.contentType =
        ContentType('text', 'plain', charset: 'utf-8');
    response.write(body);
    unawaited(response.close());
  }

  ContentType _contentTypeFor(String path) {
    switch (p.extension(path).toLowerCase()) {
      case '.html':
        return ContentType('text', 'html', charset: 'utf-8');
      case '.js':
      case '.mjs':
        return ContentType('text', 'javascript', charset: 'utf-8');
      case '.css':
        return ContentType('text', 'css', charset: 'utf-8');
      case '.json':
        return ContentType('application', 'json', charset: 'utf-8');
      case '.svg':
        return ContentType('image', 'svg+xml');
      case '.png':
        return ContentType('image', 'png');
      case '.jpg':
      case '.jpeg':
        return ContentType('image', 'jpeg');
      case '.webp':
        return ContentType('image', 'webp');
      case '.woff2':
        return ContentType('font', 'woff2');
      case '.map':
        return ContentType('application', 'json', charset: 'utf-8');
      default:
        return ContentType('application', 'octet-stream');
    }
  }

  // ---------------------------------------------------------------------------
  // JSON-RPC 方法
  // ---------------------------------------------------------------------------

  void _registerMethods() {
    final handlers = <String, JsonRpcMethod>{
      'core.ping': _handlePing,
      'session.list': _handleSessionList,
      'message.query': _handleMessageQuery,
      'agent.send': _handleAgentSend,
      'agent.cancel': _handleAgentCancel,
    };
    for (final name in kCoreRpcMethodNames) {
      final handler = handlers[name];
      if (handler == null) {
        throw StateError('RPC 方法清单 $name 没有实现（注册表与常量不同步）');
      }
      _rpc.register(name, handler);
    }
  }

  Map<String, dynamic> _handlePing(Map<String, dynamic> params) => {
        'ok': true,
        'service': 'alias-agent-headless-core',
        'protocolVersion': kCoreProtocolVersion,
        'pid': pid,
      };

  Future<Map<String, dynamic>> _handleSessionList(
      Map<String, dynamic> params) async {
    final sessions = await sessionRepo.list();
    return {
      'sessions': [for (final session in sessions) serializeSession(session)],
    };
  }

  Future<Map<String, dynamic>> _handleMessageQuery(
      Map<String, dynamic> params) async {
    final sessionId = _requireString(params, 'sessionId');
    final session = await sessionRepo.get(sessionId);
    if (session == null) {
      throw JsonRpcException(
          JsonRpcErrorCode.invalidParams, '会话 "$sessionId" 不存在');
    }
    final pageSize = params['pageSize'];
    if (pageSize is! int || pageSize <= 0) {
      // 不发明默认页大小（D10）：缺参/非法参数都是可区分的 -32602。
      throw const JsonRpcException(
          JsonRpcErrorCode.invalidParams,
          'Invalid params: pageSize 必填且必须是正整数'
              '（核心不提供默认页大小，也不发明上限）');
    }
    // 游标方向（change `web-chat-screen` 任务 1.2 / design D10 additive 扩展）：
    //   - 只传 cursor（= afterSeq）：前向分页，语义与扩展前完全一致；
    //   - 只传 before：反向分页，取 seq < before 的更早一页；
    //   - 都不传：anchor=tail（缺省）取最新一页；anchor=head 取最旧页（兼容旧调用）；
    //   - 两者同时出现是歧义请求，显式 -32602，不猜优先级。
    final cursor = params['cursor'];
    if (cursor != null && cursor is! int) {
      throw const JsonRpcException(JsonRpcErrorCode.invalidParams,
          'Invalid params: cursor 必须是整数（上一页的 nextCursor）或省略');
    }
    final before = params['before'];
    if (before != null && before is! int) {
      throw const JsonRpcException(JsonRpcErrorCode.invalidParams,
          'Invalid params: before 必须是整数（上一页的 prevCursor）或省略');
    }
    if (cursor != null && before != null) {
      throw const JsonRpcException(JsonRpcErrorCode.invalidParams,
          'Invalid params: cursor 与 before 不能同时出现（前向/反向游标只能选一个）');
    }
    final anchorRaw = params['anchor'] ?? 'tail';
    if (anchorRaw is! String || !const {'tail', 'head'}.contains(anchorRaw)) {
      throw const JsonRpcException(JsonRpcErrorCode.invalidParams,
          'Invalid params: anchor 只能是 "tail"（最新页，缺省）或 "head"（最旧页）');
    }
    final MessagePage page;
    if (before != null) {
      page = await messageRepo.queryPageBeforeSeq(
        sessionId,
        pageSize: pageSize,
        beforeSeq: before,
      );
    } else if (cursor != null) {
      page = await messageRepo.queryPageBySession(
        sessionId,
        pageSize: pageSize,
        afterSeq: cursor,
      );
    } else if (anchorRaw == 'head') {
      page = await messageRepo.queryPageBySession(
        sessionId,
        pageSize: pageSize,
      );
    } else {
      page = await messageRepo.queryLatestPageBySession(
        sessionId,
        pageSize: pageSize,
      );
    }
    return {
      'sessionId': sessionId,
      'pageSize': pageSize,
      'messages': [for (final message in page.messages) serializeMessage(message)],
      'nextCursor': page.nextCursor,
      'prevCursor': page.prevCursor,
    };
  }

  Future<Map<String, dynamic>> _handleAgentSend(
      Map<String, dynamic> params) async {
    // 发送门禁：工具目录（含条件注册）没播完之前不放行。
    await _ready;
    final sessionId = _requireString(params, 'sessionId');
    final text = params['text'];
    if (text is! String) {
      throw const JsonRpcException(
          JsonRpcErrorCode.invalidParams, 'Invalid params: 缺字符串 text');
    }
    final attachments = _optionalStringList(params, 'attachments');
    final session = await sessionRepo.get(sessionId);
    if (session == null) {
      throw JsonRpcException(
          JsonRpcErrorCode.invalidParams, '会话 "$sessionId" 不存在');
    }

    final callbacks = _callbacksFor(sessionId);
    final Agent agent =
        await factory.ensure(session, callbacks: callbacks);
    // T5：ensure 复用已存在实例时不会重赋 callbacks —— 这里必须把回调指向当前
    // WS 订阅者（广播到所有当前连接），否则重连后事件发往旧回调。
    agent.callbacks = callbacks;
    try {
      final result = await agent.send(text, attachments: attachments);
      if (result.isFailed) {
        _sendEvent(sessionId, 'turn.failed', {
          'error': result.error ?? '(整轮失败但没有错误文本)',
          'metering': result.metering.toJson(),
        });
      }
      return {
        'sessionId': sessionId,
        'status': result.status.name,
        'finalText': result.finalText,
        'error': result.error,
        'metering': result.metering.toJson(),
      };
    } catch (e) {
      _sendEvent(sessionId, 'turn.failed', {'error': '$e'});
      throw JsonRpcException(
          JsonRpcErrorCode.internalError, 'agent.send 失败：$e');
    }
  }

  Future<Map<String, dynamic>> _handleAgentCancel(
      Map<String, dynamic> params) async {
    final sessionId = _requireString(params, 'sessionId');
    final agent = agents.lookup(sessionId);
    if (agent == null) {
      return {'sessionId': sessionId, 'cancelled': false,
        'reason': '该会话没有运行中的 Agent 实例'};
    }
    agent.cancel();
    return {'sessionId': sessionId, 'cancelled': true};
  }

  String _requireString(Map<String, dynamic> params, String key) {
    final value = params[key];
    if (value is! String || value.isEmpty) {
      throw JsonRpcException(
          JsonRpcErrorCode.invalidParams, 'Invalid params: 缺字符串 $key');
    }
    return value;
  }

  List<String> _optionalStringList(Map<String, dynamic> params, String key) {
    final value = params[key];
    if (value == null) return const [];
    if (value is! List || value.any((item) => item is! String)) {
      throw JsonRpcException(JsonRpcErrorCode.invalidParams,
          'Invalid params: $key 必须是字符串数组');
    }
    return value.cast<String>();
  }

  // ---------------------------------------------------------------------------
  // AgentCallbacks → agent.event
  // ---------------------------------------------------------------------------

  AgentCallbacks _callbacksFor(String sessionId) {
    void event(String type, Map<String, dynamic> data) =>
        _sendEvent(sessionId, type, data);

    return AgentCallbacks(
      onUserMessage: (message) =>
          event('user.message', serializeMessage(message)),
      onAssistantMessage: (message, isFinal) => event('assistant.message', {
        ...serializeMessage(message),
        'isFinal': isFinal,
      }),
      onChunk: (text) => event('assistant.chunk', {'text': text}),
      onThinkingDelta: (index, delta) =>
          event('thinking.delta', {'index': index, 'delta': delta}),
      onThinkingBlock: (index, thinking, signature) => event('thinking.block', {
        'index': index,
        'thinking': thinking,
        'signature': signature,
      }),
      onToolCall: (activity) => event('tool.call', activity.toJson()),
      onToolResult: (activity) => event('tool.result', activity.toJson()),
      onStreamingChanged: (streaming) =>
          event('agent.streaming', {'streaming': streaming}),
      onTurnCompleted: () => event('turn.completed', const {}),
      onSnapshot: (snapshot) {
        // 技能失败明细必须随快照推送（逐条名+原因），不能只剩计数（design D9 / M8）。
        final skills = SkillCatalogService.instance;
        event('context.snapshot', {
          ...serializeContextSnapshot(snapshot),
          'skillFailures': skills.noticeLines,
          'skillFailureNotice': skills.failureNotice,
        });
      },
      onCompactionStatusChanged: () {
        // 回调无参：回读当前 agent 的 getter（D9）。
        final status =
            agents.lookup(sessionId)?.compactionStatus ?? CompactionStatus.idle;
        event('compaction.status', serializeCompactionStatus(status));
      },
      onTitleChanged: (title) => event('session.title', {'title': title}),
      onMeteringChanged: () {
        final metering = agents.lookup(sessionId)?.metering;
        event('agent.metering', metering?.toJson() ?? const {});
      },
    );
  }

  void _sendEvent(
      String sessionId, String type, Map<String, dynamic> data) {
    _broadcast('agent.event', {
      'sessionId': sessionId,
      'type': type,
      'data': data,
    });
  }

  void _broadcast(String method, Map<String, dynamic> params) {
    if (_clients.isEmpty) return;
    final payload = jsonEncode({
      'jsonrpc': '2.0',
      'method': method,
      'params': params,
    });
    for (final client in _clients) {
      if (client.readyState == WebSocket.open) client.add(payload);
    }
  }
}

/// 会话的对外 JSON（顶层列表契约）。
Map<String, dynamic> serializeSession(Session session) => {
      'id': session.id,
      'title': session.title,
      'agentType': session.agentType,
      'parentSessionId': session.parentSessionId,
      'createdAt': session.createdAt,
      'updatedAt': session.updatedAt,
    };

// -----------------------------------------------------------------------------
// 组合根
// -----------------------------------------------------------------------------

/// 装配无头核心（依赖注入版；生产与测试共用）。
///
/// 三段启动逻辑在这里闭环：
///   ① [openDatabase] 由调用方在打开数据库前 `sqfliteFfiInit()` +
///      `databaseFactory = databaseFactoryFfi`（生产见 [HeadlessCoreRunner.start]）；
///   ② 工具目录播种与条件注册走共享的 `initSearchAndTools`；
///   ③ 发送门禁用 [initSearchAndTools] 完成时 complete 的 Completer；
///      `summaryStoreOpen` 用真实谓词 `DatabaseService.isOpen`，不用 `_neverOpen`。
Future<HeadlessCore> buildHeadlessCore({
  required AppConfig config,
  required ISidecar sidecar,
  Future<void> Function()? openDatabase,
  Future<ToolBootstrapResult> Function()? bootstrapTools,
  MessageRepository? messageRepository,
  SessionRepository? sessionRepository,
  bool backgroundFoldEnabled = true,
}) async {
  if (openDatabase != null) await openDatabase();

  final templates = AgentTypeRegistry();
  for (final template in config.agentTypes.values) {
    templates.register(template);
  }
  final providers = ProviderResolver(config);
  final sessionRepo = sessionRepository ?? SessionRepository();
  final messageRepo = messageRepository ?? MessageRepository();
  final summaryNodeRepo = SummaryNodeRepository();
  final agents = AgentRegistry();

  final toolsReady = Completer<void>();
  try {
    final result = await (bootstrapTools ??
        () => initSearchAndTools(
              config: config,
              sidecar: sidecar,
              templates: templates,
              providerResolver: () => providers,
            ))();
    for (final line in result.skillNoticeLines) {
      debugPrint('[AliasAgent] $line');
    }
    if (result.skillFailureNotice != null) {
      debugPrint('[AliasAgent] 技能目录提示：${result.skillFailureNotice}');
    }
  } finally {
    // 即使播种抛错也要放行门禁：服务器本来就没起来，但任何已连接的路径不该死等。
    if (!toolsReady.isCompleted) toolsReady.complete();
  }

  late final AgentFactory factory;
  final subagentRunner =
      SubagentRunner(factory: () => factory, sidecar: sidecar);
  factory = AgentFactory(
    templates: templates,
    providerResolver: () => providers,
    config: config,
    sidecar: sidecar,
    sessionRepo: sessionRepo,
    messageRepo: messageRepo,
    summaryNodeRepo: summaryNodeRepo,
    registry: agents,
    backgroundFoldEnabled: backgroundFoldEnabled,
    // 真实谓词：数据库已打开（本函数要求 openDatabase 已完成）⇒ true。
    summaryStoreOpen: () => DatabaseService.isOpen,
    subagentRunner: subagentRunner,
  );

  return HeadlessCore(
    config: config,
    sidecar: sidecar,
    sessionRepo: sessionRepo,
    messageRepo: messageRepo,
    summaryNodeRepo: summaryNodeRepo,
    templates: templates,
    agents: agents,
    factory: factory,
    subagentRunner: subagentRunner,
    ready: toolsReady.future,
  );
}

/// 生产组合根：单实例锁 → 配置 → sqflite ffi 工厂 + 开库 → sidecar →
/// 依赖图/工具播种 → 绑定 OS 分配端口的回环 HTTP+WS。
///
/// 失败（锁被占用 / 配置缺失 / sidecar 加载失败）都抛
/// [HeadlessCoreStartupException]，带可归因信息；入口打印后以非零码退出。
class HeadlessCoreRunner {
  static Future<HeadlessCore> start({
    String? configPath,
    String? lockPath,
    String? webRoot,
    int port = 0,
    AppConfig? configOverride,
    ISidecar Function()? sidecarLoader,
    Future<void> Function()? openDatabaseOverride,
    bool backgroundFoldEnabled = true,
  }) async {
    // ① 单实例守卫必须在任何 DB / spill 操作之前。
    final lock = CoreInstanceLock(lockPath ?? defaultCoreLockPath);
    final lockError = await lock.acquire();
    if (lockError != null) {
      throw HeadlessCoreStartupException(lockError);
    }

    HeadlessCore? core;
    try {
      final AppConfig config;
      if (configOverride != null) {
        config = configOverride;
      } else {
        final result = ConfigService.load(configPath: configPath);
        switch (result.status) {
          case ConfigStatus.ok:
            config = result.config!;
          case ConfigStatus.notFound:
            throw HeadlessCoreStartupException(
                '配置文件不存在：${configPath ?? ConfigService.configPath}\n'
                '先运行一次 Flutter 应用完成首启配置，或用 --config 指定路径。');
          case ConfigStatus.malformed:
            throw HeadlessCoreStartupException(
                '配置文件无法解析：${result.error}');
        }
      }

      if (openDatabaseOverride != null) {
        await openDatabaseOverride();
      } else {
        // ② sqflite ffi 工厂（纯 Dart 下 openDatabase 必须靠它）。
        sqfliteFfiInit();
        databaseFactory = databaseFactoryFfi;
        await DatabaseService.database;
      }

      final ISidecar sidecar;
      try {
        sidecar = (sidecarLoader ?? () => SidecarBridge.instance)();
      } catch (e) {
        throw HeadlessCoreStartupException(
            'sidecar 加载失败：$e\n'
            '以裸名字 DynamicLibrary.open(\'sidecar.dll\') 加载，'
            '要求进程 CWD 包含仓库根的 sidecar.dll（当前 CWD=${Directory.current.path}）。');
      }

      // ③ 依赖图 + 工具播种 + 发送门禁 + summaryStoreOpen 真实谓词。
      core = await buildHeadlessCore(
        config: config,
        sidecar: sidecar,
        backgroundFoldEnabled: backgroundFoldEnabled,
      );
      core._lock = lock;
      await core.start(
        port: port,
        webRoot: webRoot ?? p.join(Directory.current.path, 'web', 'dist'),
      );
      return core;
    } catch (_) {
      if (core != null) {
        await core.stop();
      } else {
        await lock.release();
      }
      rethrow;
    }
  }
}
