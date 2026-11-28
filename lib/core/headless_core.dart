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
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../models/agent_type_config.dart';
import '../models/app_config.dart';
import '../models/compaction_status.dart';
import '../models/model_catalog_entry.dart';
import '../models/provider_config.dart';
import '../models/group_member.dart';
import '../models/instance_overrides.dart';
import '../models/session.dart';
import '../models/user_profile.dart';
import '../services/agent.dart';
import '../services/agent_config_resolver.dart';
import '../services/agent_factory.dart';
import '../services/agent_registry.dart';
import '../services/agent_session_controller.dart';
import '../services/agent_template_controller.dart';
import '../services/agent_type_registry.dart';
import '../services/config_service.dart';
import '../services/group_member_repository.dart';
import '../services/group_service.dart';
import '../services/database_service.dart';
import '../services/image_budget.dart';
import '../services/image_probe.dart';
import '../services/logging.dart';
import '../services/message_page.dart';
import '../services/message_repository.dart';
import '../services/model_discovery_service.dart';
import '../services/provider_resolver.dart';
import '../services/session_repository.dart';
import '../services/sidecar_bridge.dart';
import '../services/skills/skill_catalog_service.dart';
import '../services/subagent_runner.dart';
import '../services/summary_node_repository.dart';
import '../services/tool_bootstrap.dart';
import '../services/tool_catalog.dart';
import '../services/workspace.dart';
import 'core_lock.dart';
import 'event_serialization.dart';
import 'json_rpc.dart';

/// 通道协议版本（不是产品版本）：客户端可用 `core.ping` 核对。
const int kCoreProtocolVersion = 1;

/// 只绑回环地址（本机信任边界，无鉴权；见用户文档的已知限制）。
const String kCoreBindHost = '127.0.0.1';

/// 启动回显的 URL 形状（`<port>` 是**实际监听端口**的占位；端口来自 `--port` >
/// `core.port` > 具名默认，见 `lib/core/core_cli.dart`。文档守卫读它）。
const String kCoreUrlTemplate = 'http://$kCoreBindHost:<port>';

/// 启动命令（用户文档与 `--help` 同源，文档守卫读它）。
const String kCoreEntryCommand = 'dart run bin/alias_agent_core.dart';

/// 暴露的 JSON-RPC 方法名（注册表与文档守卫共用这一份清单）。
///
/// change `web-management-ui`：`_registerMethods` 里少一个实现就抛 `StateError`
/// （清单与实现必须一致）；文档守卫要求每个名字都出现在用户文档的 RPC 表里。
const List<String> kCoreRpcMethodNames = <String>[
  'core.ping',
  // 优雅停机（change `windows-desktop-shell` 2.2）：先回 `{ok:true}` 刷出，再停机。
  'core.shutdown',
  'session.list',
  'session.create',
  'session.delete',
  'session.rename',
  'session.switchTemplate',
  // 工作路径（change `custom-workspace`）：单聊原地切换（组用 `group.setWorkspace`）。
  'session.setWorkspace',
  // 文件夹选择对话框的列目录（change `custom-workspace` 返工任务 12.2）：只列子目录，
  // 省略 `path` 时起点是应用主目录。单聊 / 群共用同一份浏览数据源。
  'workspace.listDirs',
  'message.query',
  'agent.send',
  'agent.cancel',
  'config.get',
  'config.save',
  // 用户资料（change `chat-bubbles-avatars`）：只写 `profile` 块，不进模型请求。
  'profile.save',
  'provider.probe',
  'provider.probeFetch',
  'template.list',
  'template.save',
  'template.delete',
  'attachment.upload',
  'attachment.read',
  // 群聊（change `agent-group-chat` §7；change `group-reactive-mode` 加 `group.update`
  // 与 `group.chain`；change `custom-workspace` 加 `group.setWorkspace`）：
  // 十一个方法，实现与清单必须一致。
  'group.create',
  'group.update',
  'group.chain',
  'group.list',
  'group.delete',
  'group.member.add',
  'group.member.remove',
  'group.member.update',
  'group.send',
  'group.view',
  'group.setWorkspace',
];

/// WebSocket 路径（与 web 客户端一致）。
const String kCoreWebSocketPath = '/ws';

/// 停机期间出现告警时的进程退出码（change `windows-desktop-shell` 2.1 / design D3）。
///
/// 取「与既有 1（启动失败）、2（参数错误）不冲突的最小未用码」；有告警时**不许**
/// 以 0 退出假装成功。
const int kExitCodeShutdownWithWarnings = 3;

/// 停机报告：停机期间发生的异常逐条收在这里（不再被吞成一句 debugPrint）。
///
/// 每条 warning 由 [HeadlessCore.stop] 写进核心日志；[exitCode] 是进程该用的退出码。
class ShutdownReport {
  const ShutdownReport({this.warnings = const <String>[]});

  final List<String> warnings;

  bool get hasWarnings => warnings.isNotEmpty;

  /// 0 = 正常停机；[kExitCodeShutdownWithWarnings] = 停机有告警。
  int get exitCode => hasWarnings ? kExitCodeShutdownWithWarnings : 0;

  @override
  String toString() => 'ShutdownReport(warnings=$warnings, exitCode=$exitCode)';
}

/// 启动失败：带可归因信息，入口直接打印并退出（不假装就绪）。
class HeadlessCoreStartupException implements Exception {
  final String message;

  const HeadlessCoreStartupException(this.message);

  @override
  String toString() => message;
}

/// 运行中核心的 `ProviderResolver` 引用（change `web-management-ui` D1）。
///
/// `AgentFactory` / `initSearchAndTools` 拿到的是**读这个盒子**的闭包，而不是某个
/// 解析器实例：配置写盘后换掉盒子里的值，运行中的核心此后创建的实例就读到新
/// provider 表 —— Flutter 侧对应的动作是 `main.dart._applyProviderConfig` 里那句
/// `resolver = ProviderResolver(next)`。
class ProviderResolverRef {
  ProviderResolverRef(this.current);

  ProviderResolver current;
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
    required this.providerResolverRef,
    required this.sessionController,
    required this.templateController,
    required this.groups,
    required this.configPath,
    required this.attachmentsDir,
    // 文件夹选择对话框省略 `path` 时的起点（返工任务 12.2）。缺省 = 产品主目录；
    // 测试注入临时目录，避免列举用户真实主目录。
    String? homeDir,
    required this.probe,
    required Future<void> ready,
  })  : _ready = ready,
        homeDir = homeDir ?? ConfigService.homeDir;

  /// 当前配置（可变：配置写盘后由 [applyConfig] 进程内同步）。
  AppConfig config;
  final ISidecar sidecar;

  /// provider 表的可替换引用（见 [ProviderResolverRef]）。
  final ProviderResolverRef providerResolverRef;

  /// 会话模板切换 / 删除互斥的协调者（design D3）。
  ///
  /// 组合根构造它并在 RPC 层复用（`session.switchTemplate` / `session.delete`）：
  /// 没有它就没有 beginDelete/endDelete 守卫，删除进行中的切换会静默穿过。
  final AgentSessionController sessionController;

  /// 模板编辑 / 删除的协调者（design D9 / D10）。组合根构造，RPC 层复用同一份规则
  /// （`validate` / `save` / 校验错误字段），不另写一套。
  final AgentTemplateController templateController;

  /// 组服务（change `agent-group-chat` §5）：组/成员生命周期、调度、共享工作区。
  final GroupService groups;

  /// 核心读写的配置文件路径（design D14 注入点）。
  ///
  /// 生产 = `--config` 或产品默认 `~/.aliasagent/config.json`；测试 = `$env:TEMP`
  /// 下临时目录里的一份 —— **绝不允许**在测试里落到用户真实配置上。
  final String configPath;

  /// 附件落盘目录（design D12 / D14 注入点）。生产 = `ConfigService.attachmentsDir`。
  final String attachmentsDir;

  /// 文件夹选择对话框的缺省起点（返工任务 12.2）。
  ///
  /// 生产 = `ConfigService.homeDir`（与缺省工作区同一口径，不发明第二个「主目录」）；
  /// 测试注入临时目录 —— 用例**不得**去列举用户真实主目录。
  final String homeDir;

  /// 模型目录探测入口（design D7 / D14 注入点）。生产 = 真 HTTP 探测；
  /// 测试注入假 probe（**绝不联网**）。
  final ModelCatalogProbe probe;

  /// 启动期给用户看的提示（design D2：配置文件不存在时以空配置启动，这里说明原因）。
  /// `null` = 正常配置启动，无需提示。
  String? startupNotice;
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
  ShutdownReport? _lastShutdownReport;

  /// 停机信号：`core.shutdown` 的**响应已刷出**、或收到 SIGINT 时完成。
  ///
  /// 「先回包、再停机」的时序落点在这里（design D3）：WS 侧先把响应写出并
  /// `await socket.close()` 排空队列，然后才 complete 它；等待方
  /// [serveUntilShutdown] 收到信号后才执行 [stop]。
  final Completer<void> _shutdownSignal = Completer<void>();

  /// 已受理、但响应还没刷出的 `core.shutdown` 请求（WS 侧在刷出后据此收尾）。
  bool _shutdownResponsePending = false;

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

  /// 组合根配置进程内同步（design D1）。
  ///
  /// 等价物是 Flutter `main.dart._applyProviderConfig`：`config.save` /
  /// `provider.probe` / `template.save` / `template.delete` 成功写盘后调它。
  ///
  /// 同步范围与 Flutter 一致：重建 ProviderResolver + 重注册模板表 + 换掉配置快照。
  /// **已创建**的 Agent 实例不变（实例持有自己冻结的 `ResolvedAgentConfig`，只有
  /// thinkingEffort 走每轮重解析）；此后创建或恢复的实例读新配置。
  void applyConfig(AppConfig next) {
    config = next;
    providerResolverRef.current = ProviderResolver(next);
    templates.clear();
    for (final template in next.agentTypes.values) {
      templates.register(template);
    }
    factory.config = next;
    templateController.replaceConfig(next);
  }

  /// 绑定回环地址并开始服务。[port] 默认 0 = 由 OS 分配（测试形态）。
  ///
  /// 显式给定的端口绑不上（被占用 / 权限 / 地址不可用）时必须抛**可归因**的
  /// [HeadlessCoreStartupException]（change `windows-desktop-shell` 任务 1.3）：
  /// 消息点名端口号并给出改法（改 `core.port` 或用 `--port`），**不静默换端口** ——
  /// 固定端口的全部价值就是地址稳定。裸 `SocketException` 会让壳只能显示一句
  /// 「启动失败」，用户无从下手。
  Future<void> start({int port = 0, String? webRoot}) async {
    if (_server != null) throw StateError('无头核心已经启动');
    _webRoot = webRoot;
    _registerMethods();
    final HttpServer server;
    try {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    } on SocketException catch (e) {
      throw HeadlessCoreStartupException(
        '无头核心无法绑定端口 $port：${e.message}\n'
        '端口被占用或不可用。改 core.port（配置文件里的固定端口）或用 --port '
        '指定另一个端口后重新启动；核心不会静默改用其它端口。',
      );
    }
    _server = server;
    server.listen((request) {
      unawaited(_handleHttpRequest(request));
    }, onError: (Object error, StackTrace st) {
      debugPrint('[AliasAgent] 无头核心 HTTP 监听错误：$error\n$st');
    });
  }

  /// 停机（可重入）。顺序是**产品语义**，不许调换（design D3 / spec `core.shutdown`）：
  ///
  /// ① 对所有运行中的 Agent 调 `cancel()`（同步：只置取消标志、不等待整轮结束）；
  /// ② **`await` 每个实例的 `waitForRounds()`** —— 在途整轮收尾、事件仍可经 WS 发出，
  ///    这是「收尾事件在通道关闭前到达」的实现前提（少了它只剩「置标志就关通道」）；
  /// ③ 关 WS 客户端 → ④ 关服务器 → ⑤ `disposeAll()`（幂等）→ ⑥ 关数据库 →
  /// ⑦ 释放单实例锁。
  ///
  /// ⑤ / ⑥ 的异常收进 [ShutdownReport.warnings] 并写日志，有告警时调用方用
  /// [kExitCodeShutdownWithWarnings] 退出（不许静默当成功）。
  Future<ShutdownReport> stop() async {
    final previous = _lastShutdownReport;
    if (_stopped) return previous ?? const ShutdownReport();
    _stopped = true;
    final warnings = <String>[];

    // ① 取消所有运行中的实例（快照：等待期间注册表可能还有动作）。
    final running = List<Agent>.from(agents.instances);
    for (final agent in running) {
      try {
        agent.cancel();
      } catch (e) {
        warnings.add('取消 Agent ${agent.handle} 失败：$e');
      }
    }
    // ② 等在途整轮收尾（收尾事件还能经 WS 发出去）。
    for (final agent in running) {
      try {
        await agent.waitForRounds();
      } catch (e) {
        warnings.add('等待 Agent ${agent.handle} 收尾失败：$e');
      }
    }

    // ③ 断开 WS 客户端。
    for (final client in List<WebSocket>.from(_clients)) {
      try {
        await client.close(WebSocketStatus.goingAway, 'core stopping');
      } catch (_) {
        // 已经断开：忽略。
      }
    }
    _clients.clear();
    // ④ 关服务器。
    final server = _server;
    _server = null;
    try {
      await server?.close(force: true);
    } catch (e) {
      warnings.add('关闭 HTTP 服务器失败：$e');
    }
    // ⑤ 销毁 Agent（disposeAll 幂等：先 dispose 再清表）。
    try {
      await agents.disposeAll();
    } catch (e) {
      warnings.add('销毁 Agent 失败：$e');
    }
    // ⑥ 关数据库。
    try {
      await DatabaseService.close();
    } catch (e) {
      warnings.add('关闭数据库失败：$e');
    }
    // ⑦ 释放单实例锁。
    final lock = _lock;
    _lock = null;
    try {
      await lock?.release();
    } catch (e) {
      warnings.add('释放单实例锁失败：$e');
    }

    final report = ShutdownReport(warnings: warnings);
    for (final warning in warnings) {
      debugPrint('[AliasAgent] 停机告警：$warning');
    }
    debugPrint('[AliasAgent] 无头核心已停机'
        '（warnings=${warnings.length}，exitCode=${report.exitCode}）');
    _lastShutdownReport = report;
    return report;
  }

  /// 停机信号已就绪（`core.shutdown` 的响应**已刷出**）。由 WS 层在刷出后调用。
  void markShutdownResponseFlushed() {
    if (!_shutdownSignal.isCompleted) _shutdownSignal.complete();
  }

  /// 入口与测试**共用**的停机等待点（design D3 / spec `core.shutdown`）。
  ///
  /// 等「`core.shutdown` 的响应已刷出」或 SIGINT，然后执行 [stop] 并返回停机报告。
  /// 测试不许自己拼一套停机序列 —— 否则验的是测试自己。
  Future<ShutdownReport> serveUntilShutdown() async {
    StreamSubscription<ProcessSignal>? sigint;
    try {
      sigint = ProcessSignal.sigint.watch().listen((_) {
        if (!_shutdownSignal.isCompleted) _shutdownSignal.complete();
      });
    } catch (_) {
      // 某些平台不支持 signal watch：进程仍可由外部终止。
    }
    try {
      await _shutdownSignal.future;
    } finally {
      await sigint?.cancel();
    }
    return stop();
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
      // `core.shutdown` 的收尾必须发生在**响应刷出之后**（design D3）：handler 只
      // 登记请求，这里先把响应 `add` 进发送队列，再 `await socket.close()` ——
      // Dart 的 `WebSocket.close()` 会先把排队消息发完，因此调用方一定先收到
      // `{ok:true}`，之后才看到连接关闭。MUST NOT 反过来（先 stop 会把响应吞掉）。
      final shutdownAfterWrite = _shutdownResponsePending;
      if (response != null && socket.readyState == WebSocket.open) {
        socket.add(response);
      }
      if (shutdownAfterWrite) {
        try {
          await socket.close(
              WebSocketStatus.normalClosure, 'core shutting down');
        } catch (_) {
          // 已经断开：忽略。
        }
        _clients.remove(socket);
        markShutdownResponseFlushed();
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
      'core.shutdown': _handleCoreShutdown,
      'session.list': _handleSessionList,
      'session.create': _handleSessionCreate,
      'session.delete': _handleSessionDelete,
      'session.rename': _handleSessionRename,
      'session.switchTemplate': _handleSessionSwitchTemplate,
      'session.setWorkspace': _handleSessionSetWorkspace,
      'workspace.listDirs': _handleWorkspaceListDirs,
      'message.query': _handleMessageQuery,
      'agent.send': _handleAgentSend,
      'agent.cancel': _handleAgentCancel,
      'config.get': _handleConfigGet,
      'config.save': _handleConfigSave,
      'profile.save': _handleProfileSave,
      'provider.probe': _handleProviderProbe,
      'provider.probeFetch': _handleProviderProbeFetch,
      'template.list': _handleTemplateList,
      'template.save': _handleTemplateSave,
      'template.delete': _handleTemplateDelete,
      'attachment.upload': _handleAttachmentUpload,
      'attachment.read': _handleAttachmentRead,
      'group.create': _handleGroupCreate,
      'group.update': _handleGroupUpdate,
      'group.chain': _handleGroupChain,
      'group.list': _handleGroupList,
      'group.delete': _handleGroupDelete,
      'group.member.add': _handleGroupMemberAdd,
      'group.member.remove': _handleGroupMemberRemove,
      'group.member.update': _handleGroupMemberUpdate,
      'group.send': _handleGroupSend,
      'group.view': _handleGroupView,
      'group.setWorkspace': _handleGroupSetWorkspace,
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

  /// `core.shutdown`：**只回包、不在这里停机**（change `windows-desktop-shell` 2.2）。
  ///
  /// 时序（design D3）：① handler 返回 `{ok: true}` 并登记「响应刷出后」要做的事；
  /// ② WS 侧先把响应写进发送队列、`await socket.close()` 排空，然后 complete 停机
  /// 信号；③ 等待方 [serveUntilShutdown] 收到信号后才调 [stop]。
  ///
  /// 反过来（handler 里先 stop）会把客户端以 going-away 关掉，而响应还在队列里 ——
  /// 调用方看到的是「调了但没回」。所以这里 MUST NOT 调 stop。
  Map<String, dynamic> _handleCoreShutdown(Map<String, dynamic> params) {
    _shutdownResponsePending = true;
    debugPrint('[AliasAgent] 收到 core.shutdown：先回包，响应刷出后停机');
    return {'ok': true};
  }

  Future<Map<String, dynamic>> _handleSessionList(
      Map<String, dynamic> params) async {
    final sessions = await sessionRepo.list();
    return {
      'sessions': [for (final session in sessions) serializeSession(session)],
    };
  }

  // ---------------------------------------------------------------------------
  // 会话管理（change `web-management-ui` 任务 1.1 / design D4）
  // ---------------------------------------------------------------------------

  /// `session.create`：建一条顶层会话（默认 `general`），返回完整会话行。
  Future<Map<String, dynamic>> _handleSessionCreate(
      Map<String, dynamic> params) async {
    final rawTitle = params['title'];
    if (rawTitle != null && rawTitle is! String) {
      throw const JsonRpcException(
          JsonRpcErrorCode.invalidParams, 'Invalid params: title 必须是字符串或省略');
    }
    final title = (rawTitle as String?)?.trim();
    final rawAgentType = params['agentType'];
    String? agentType;
    if (rawAgentType != null) {
      if (rawAgentType is! String || rawAgentType.isEmpty) {
        throw const JsonRpcException(JsonRpcErrorCode.invalidParams,
            'Invalid params: agentType 必须是非空字符串或省略');
      }
      // 建一个引用不存在模板的会话 = 造一条永远建不出实例的记录：入口就拒绝。
      if (!templates.contains(rawAgentType)) {
        throw JsonRpcException(JsonRpcErrorCode.invalidParams,
            'Agent 模板 "$rawAgentType" 不存在：拒绝新建会话（不会退回 general）');
      }
      agentType = rawAgentType;
    }
    // 工作路径（change `custom-workspace` D4 / D6）：有值先校验再插行；非法 ⇒ -32602
    // 且**不创建会话行**。只有空白字符 = 省略（写 NULL、用缺省）。
    final rawWorkspace = params['workspace'];
    if (rawWorkspace != null && rawWorkspace is! String) {
      throw const JsonRpcException(JsonRpcErrorCode.invalidParams,
          'Invalid params: workspace 必须是字符串或省略');
    }
    final workspaceSetting =
        stripWorkspaceInput((rawWorkspace as String?) ?? '');
    if (workspaceSetting.isNotEmpty) {
      final problem = workspaceProblem(workspaceSetting);
      if (problem != null) {
        throw JsonRpcException(
            JsonRpcErrorCode.invalidParams,
            '工作路径被拒绝：$problem（收到 "$workspaceSetting"）');
      }
    }
    final session = await sessionRepo.create(
      title: (title == null || title.isEmpty) ? null : title,
      agentType: agentType,
      workspace: workspaceSetting.isEmpty ? null : workspaceSetting,
    );
    return {'session': serializeSession(session)};
  }

  /// `session.rename`：**自查存在性**（`SessionRepository.updateTitle` 对不存在的 id
  /// 静默 no-op，RPC 层必须自己拒绝，否则界面会以为改成功了）。
  Future<Map<String, dynamic>> _handleSessionRename(
      Map<String, dynamic> params) async {
    final sessionId = _requireString(params, 'sessionId');
    final rawTitle = params['title'];
    if (rawTitle is! String) {
      throw const JsonRpcException(
          JsonRpcErrorCode.invalidParams, 'Invalid params: title 必填且必须是字符串');
    }
    final title = rawTitle.trim();
    if (title.isEmpty) {
      throw const JsonRpcException(
          JsonRpcErrorCode.invalidParams, '标题不能为空：重命名被拒绝');
    }
    final existing = await sessionRepo.get(sessionId);
    if (existing == null) {
      throw JsonRpcException(JsonRpcErrorCode.invalidParams,
          '会话 "$sessionId" 不存在：重命名被拒绝（不静默 no-op）');
    }
    await sessionRepo.updateTitle(sessionId, title);
    final reread = await sessionRepo.get(sessionId);
    if (reread == null) {
      throw JsonRpcException(JsonRpcErrorCode.invalidParams,
          '会话 "$sessionId" 在重命名过程中被删除：未能确认新标题落库');
    }
    return {'session': serializeSession(reread)};
  }

  /// `session.delete`：复刻 Flutter `main.dart._deleteSession` 序列（design D4）：
  /// beginDelete（登记删除 + 等在途切换 + 重读行）→ cancel → disposeAndRemove
  /// （底层没证明排空就**放弃删除**，数据库保持不变）→ 最后才删数据库行 → endDelete。
  Future<Map<String, dynamic>> _handleSessionDelete(
      Map<String, dynamic> params) async {
    final sessionId = _requireString(params, 'sessionId');
    final existing = await sessionRepo.get(sessionId);
    if (existing == null) {
      throw JsonRpcException(JsonRpcErrorCode.invalidParams,
          '会话 "$sessionId" 不存在：删除被拒绝（不静默 no-op）');
    }
    try {
      final fresh = await sessionController.beginDelete(sessionId);
      if (fresh == null) {
        debugPrint('[AliasAgent] 删除会话 $sessionId：数据库行已不存在，'
            '继续清理内存状态与运行实例');
      }
      // 切换可能刚换过实例：按 id 重新查一次再 cancel / dispose。
      agents.lookup(sessionId)?.cancel();
      try {
        await agents.disposeAndRemove(sessionId);
      } catch (e) {
        // 底层没能证明排空（例如毒化上下文）：资源仍被保留，**不许假装删成功**。
        throw JsonRpcException(JsonRpcErrorCode.internalError,
            '删除会话 "$sessionId" 失败：上下文没能证明排空（$e）；'
            '已放弃删除，数据库记录保持不变');
      }
      // 最后才删数据库行：数据库删除晚于所有写入。
      await sessionRepo.delete(sessionId);
      return {'sessionId': sessionId, 'deleted': true};
    } finally {
      sessionController.endDelete(sessionId);
    }
  }

  /// `session.switchTemplate`：复用 [AgentSessionController.switchTemplate]，
  /// 失败时把**阶段 + 候选名**放进错误消息（只说"切换失败"无法归因）。
  Future<Map<String, dynamic>> _handleSessionSwitchTemplate(
      Map<String, dynamic> params) async {
    final sessionId = _requireString(params, 'sessionId');
    final templateName = _requireString(params, 'templateName');
    final session = await sessionRepo.get(sessionId);
    if (session == null) {
      throw JsonRpcException(JsonRpcErrorCode.invalidParams,
          '会话 "$sessionId" 不存在：切换模板被拒绝');
    }
    if (session.isGroup) {
      throw JsonRpcException(
        JsonRpcErrorCode.invalidParams,
        '会话 "$sessionId" 是组会话（kind=group）：组会话没有自己的模板，'
            '切换模板被拒绝（每个成员的模板来自成员行）',
      );
    }
    try {
      final agent = await sessionController.switchTemplate(
        session,
        templateName,
        callbacks: callbacksFor(sessionId),
      );
      return {
        'sessionId': sessionId,
        'agentType': agent.agentTypeName,
        'templateName': templateName,
      };
    } on AgentSwitchException catch (e) {
      throw JsonRpcException(
        JsonRpcErrorCode.invalidParams,
        '模板切换失败（阶段：${e.stage.name} / ${e.stage.label}，'
        '候选 "${e.candidateName}"）：${e.message}',
      );
    } on WorkspaceUnavailableException catch (e) {
      // 兜底：切换创建实例时工作路径不可用（正常路径会被包成 AgentSwitchException，
      // 它的 message 已含路径与出路）。仍然映射为 -32602，不变成内部错误。
      throw JsonRpcException(
          JsonRpcErrorCode.invalidParams, '模板切换失败：$e');
    } on JsonRpcException {
      rethrow;
    } catch (e) {
      throw JsonRpcException(
          JsonRpcErrorCode.internalError, '模板切换失败（候选 "$templateName"）：$e');
    }
  }

  /// `session.setWorkspace`：单聊原地切换工作路径（change `custom-workspace` D6）。
  ///
  /// 顺序钉死：kind 守卫 → 校验路径（非法 ⇒ -32602，**不改任何东西**）→ busy
  /// （实例流式 / 模板切换中 / 删除中，不排队、不改值）→ 有在册实例则 `Agent.setWorkspace`
  /// → 落库（核对**恰好一行**）→ 重读返回 `{session}`。
  Future<Map<String, dynamic>> _handleSessionSetWorkspace(
      Map<String, dynamic> params) async {
    final sessionId = _requireString(params, 'sessionId');
    final rawWorkspace = params['workspace'];
    if (rawWorkspace is! String) {
      throw const JsonRpcException(JsonRpcErrorCode.invalidParams,
          'Invalid params: workspace 必填且必须是字符串（要回主目录请显式传主目录路径）');
    }
    final session = await sessionRepo.get(sessionId);
    if (session == null) {
      throw JsonRpcException(JsonRpcErrorCode.invalidParams,
          '会话 "$sessionId" 不存在：切换工作路径被拒绝（不静默 no-op）');
    }
    if (session.isGroup) {
      throw JsonRpcException(
        JsonRpcErrorCode.invalidParams,
        '会话 "$sessionId" 是组会话（kind=group）：组的工作路径请用 group.setWorkspace'
            '（它会把新路径传播到所有在册成员实例）',
      );
    }
    final setting = stripWorkspaceInput(rawWorkspace);
    final problem = workspaceProblem(setting);
    if (problem != null) {
      throw JsonRpcException(JsonRpcErrorCode.invalidParams,
          '工作路径被拒绝：$problem（收到 "$setting"）');
    }
    if (sessionController.isSwitching(sessionId)) {
      throw JsonRpcException(JsonRpcErrorCode.invalidParams,
          '会话 "$sessionId" 正在切换模板：busy，工作路径未改动（不排队）');
    }
    if (sessionController.isDeleting(sessionId)) {
      throw JsonRpcException(JsonRpcErrorCode.invalidParams,
          '会话 "$sessionId" 正在删除：busy，工作路径未改动（不排队）');
    }
    final agent = agents.lookup(sessionId);
    if (agent != null) {
      if (agent.isStreaming) {
        throw JsonRpcException(JsonRpcErrorCode.invalidParams,
            '会话 "$sessionId" 正在生成：busy，工作路径未改动（不排队、不中途换根）');
      }
      try {
        await agent.setWorkspace(setting);
      } on WorkspaceUnavailableException catch (e) {
        throw JsonRpcException(JsonRpcErrorCode.invalidParams, '$e');
      } on StateError catch (e) {
        // Agent.setWorkspace 的并发兜底（例如竞态下刚开始生成）。
        throw JsonRpcException(JsonRpcErrorCode.invalidParams,
            '会话 "$sessionId" 切换工作路径失败：$e');
      }
    }
    final updated = await sessionRepo.updateWorkspace(sessionId, setting);
    if (updated != 1) {
      throw JsonRpcException(
        JsonRpcErrorCode.invalidParams,
        '上下文已切换到「$setting」，但没有更新到唯一既有行'
            '（实际更新 $updated 行，期望 1 行）：数据库里的工作路径未持久化（不假装成功）',
      );
    }
    final reread = await sessionRepo.get(sessionId);
    if (reread == null) {
      throw JsonRpcException(JsonRpcErrorCode.invalidParams,
          '会话 "$sessionId" 在切换工作路径过程中被删除：未能确认落库');
    }
    return {'session': serializeSession(reread)};
  }

  /// `workspace.listDirs`：文件夹选择对话框的一层子目录（返工任务 12.2 / 12.11）。
  ///
  /// 入参 `path` 可选：省略 / 只有空白 ⇒ 起点是 [homeDir]（生产 = 应用主目录）；
  /// `path == kWorkspaceDrivesRoot`（`@drives`）⇒ 「此电脑」虚拟根，列本机逻辑盘
  /// （仅 Windows；`isDirectory=false`，不能被选成工作路径）。
  /// 只列**子目录**（用户选的是工作目录，不是文件），回包
  /// `{path, parent, directories:[{name, path}], exists, isDirectory}`。
  ///
  /// 路径不存在 / 不是目录 / 读不到 ⇒ `-32602`（消息含路径与原因），
  /// **不静默返回空列表** —— 界面要能说明为什么打不开这个目录。
  Future<Map<String, dynamic>> _handleWorkspaceListDirs(
      Map<String, dynamic> params) async {
    final rawPath = params['path'];
    if (rawPath != null && rawPath is! String) {
      throw const JsonRpcException(JsonRpcErrorCode.invalidParams,
          'Invalid params: path 必须是字符串或省略（省略 = 从应用主目录开始）');
    }
    try {
      final listing = listWorkspaceDirectories(
        rawPath as String?,
        defaultDir: homeDir,
      );
      return listing.toJson();
    } on WorkspaceUnavailableException catch (e) {
      throw JsonRpcException(JsonRpcErrorCode.invalidParams, '无法列举目录：$e');
    }
  }

  Future<Map<String, dynamic>> _handleMessageQuery(
      Map<String, dynamic> params) async {    final sessionId = _requireString(params, 'sessionId');
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
    // kind 守卫（agent-group-chat D16）：组会话不建/不复用单 Agent 实例 —— 否则
    // `restore()` 会把整份原文（含他人 private 行）直接喂给模型，等于在投影之外
    // 开了第二条出口。
    if (session.isGroup) {
      throw JsonRpcException(
        JsonRpcErrorCode.invalidParams,
        '会话 "$sessionId" 是组会话（kind=group）：单 Agent 的 agent.send 被拒绝，'
            '请走群聊 RPC（group.send，带 speaker）',
      );
    }

    final callbacks = callbacksFor(sessionId);
    final Agent agent;
    try {
      agent = await factory.ensure(session, callbacks: callbacks);
    } on WorkspaceUnavailableException catch (e) {
      // change `custom-workspace` D6：持久化工作路径不可用（重启后目录被删 / 不是目录）
      // ⇒ 可归因 -32602（含路径与出路）；不静默回落缺省目录、不在空工作区里发请求。
      throw JsonRpcException(
          JsonRpcErrorCode.invalidParams, 'agent.send 无法开始：$e');
    }
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
    final rawMemberId = params['memberId'];
    if (rawMemberId != null && rawMemberId is! String) {
      throw const JsonRpcException(
          JsonRpcErrorCode.invalidParams, 'Invalid params: memberId 必须是字符串或省略');
    }
    final session = await sessionRepo.get(sessionId);
    // 组会话的 sessionId 不是任何成员实例的键：按组路由，不许返回"查不到实例"这种
    // 假原因（agent-group-chat D18）。
    if (session != null && session.isGroup) {
      try {
        final outcome =
            await groups.cancel(sessionId, memberId: rawMemberId as String?);
        return {
          'sessionId': sessionId,
          'groupId': sessionId,
          ...outcome.toJson(),
        };
      } on GroupException catch (e) {
        throw _groupError(e);
      }
    }
    final agent = agents.lookup(sessionId);
    if (agent == null) {
      return {'sessionId': sessionId, 'cancelled': false,
        'reason': '该会话没有运行中的 Agent 实例'};
    }
    agent.cancel();
    return {'sessionId': sessionId, 'cancelled': true};
  }

  // ---------------------------------------------------------------------------
  // 配置与 provider（change `web-management-ui` 任务 3.1 / design D6 / D7）
  // ---------------------------------------------------------------------------

  /// 从盘上重读最新配置（D1：不要拿内存里的旧快照盖掉用户刚写进去的编辑）。
  ///
  /// 文件不存在 ⇒ 内存里的配置（空配置启动/首启时就是空表）；malformed ⇒ 可归因失败
  /// （**不**静默当成空配置，那会在用户不知情时抹掉他的文件）。
  AppConfig _readLatestConfig() {
    final result = ConfigService.load(configPath: configPath);
    switch (result.status) {
      case ConfigStatus.ok:
        return result.config!;
      case ConfigStatus.notFound:
        return config;
      case ConfigStatus.malformed:
        throw JsonRpcException(JsonRpcErrorCode.internalError,
            '配置文件无法解析：${result.error}');
    }
  }

  /// 对外配置视图：**api_key 脱敏**（只报 hasApiKey，不回显任何片段）。
  Map<String, dynamic> _redactedConfig(AppConfig source) => {
        'missing': !File(configPath).existsSync(),
        'configPath': configPath,
        'providers': {
          for (final entry in source.providers.entries)
            entry.key: {
              'baseUrl': entry.value.baseUrl,
              'hasApiKey': entry.value.apiKey.isNotEmpty,
              'models': [for (final model in entry.value.models) model.toJson()],
              'discoveredAt': entry.value.discoveredAt,
            },
        },
        'agentTypes': {
          for (final entry in source.agentTypes.entries)
            entry.key: {...entry.value.toJson(), 'name': entry.key},
        },
        'tools': (ToolCatalog.instance.names.toList()..sort()),
        // 用户资料（change `chat-bubbles-avatars` D2）：路径无密钥风险，原样回显；
        // `identitySeed` 是读取期派生值（userId ?? kDefaultUserSeed），不写回配置。
        'profile': _profilePayload(source.profile),
      };

  /// `profile` 块的对外载荷（`config.get` / `profile.save` 共用同一形状）。
  Map<String, dynamic> _profilePayload(UserProfile? profile) => {
        'avatarPath': profile?.avatarPath,
        'userId': profile?.userId,
        'identitySeed': profile?.identitySeed ?? UserProfile.kDefaultUserSeed,
      };

  /// 头像路径校验（change `chat-bubbles-avatars` D3）：必须在注入的附件目录内、且
  /// **确实是一个存在的文件**。判定复用 `_handleAttachmentRead` 的同一写法
  /// （`p.normalize` + `p.isWithin`）；**禁字符串前缀比较**（`…\att` 会误容 `…\attacker`）。
  String _requireAvatarPath(String rawPath) {
    final dirAbs = p.normalize(p.absolute(attachmentsDir));
    final fileAbs = p.normalize(p.absolute(rawPath));
    if (fileAbs != dirAbs && !p.isWithin(dirAbs, fileAbs)) {
      throw JsonRpcException(
        JsonRpcErrorCode.invalidParams,
        '头像路径必须位于附件目录（$dirAbs）内：拒绝 "$rawPath"',
      );
    }
    // 「是文件而不是目录」的判定：`FileSystemEntity.isFileSync` 对目录返回 false。
    if (!FileSystemEntity.isFileSync(fileAbs)) {
      throw JsonRpcException(
        JsonRpcErrorCode.invalidParams,
        '头像路径不是一个存在的文件（$fileAbs）：拒绝 "$rawPath"',
      );
    }
    return fileAbs;
  }

  /// `config.get`：读盘 + 脱敏。文件不存在时 `missing: true`（web 端据此开首启向导）。
  Future<Map<String, dynamic>> _handleConfigGet(
      Map<String, dynamic> params) async {
    return _redactedConfig(_readLatestConfig());
  }

  /// `config.save`：**整份 provider 表**提交（缺省不传的现存 provider = 删除）。
  ///
  /// 校验规则复用 Flutter Providers 页同一套（D6 / D8）：
  ///   - 名字非空、网关地址必须是绝对 http(s)、新增 provider 必须给密钥；
  ///   - 已有 provider 传空密钥 = 沿用原密钥（不静默丢密钥）；
  ///   - `rename_from` 在同一保存动作里级联改写引用模板；
  ///   - 删除被模板引用的 provider ⇒ 拒绝并点名引用名单。
  /// 校验全部通过才写盘，然后 [applyConfig] 进程内同步。
  Future<Map<String, dynamic>> _handleConfigSave(
      Map<String, dynamic> params) async {
    final rawProviders = params['providers'];
    if (rawProviders is! Map) {
      throw const JsonRpcException(JsonRpcErrorCode.invalidParams,
          'Invalid params: providers 必须是对象（键 = provider 名，'
          '值 = {base_url, api_key?, rename_from?}；缺省的现存 provider 视为删除）');
    }
    final current = _readLatestConfig();
    final nextProviders = <String, ProviderConfig>{};
    final renames = <String, String>{};
    for (final entry in rawProviders.entries) {
      final rawName = entry.key;
      if (rawName is! String || rawName.trim().isEmpty) {
        throw const JsonRpcException(
            JsonRpcErrorCode.invalidParams, 'provider 名不能为空');
      }
      final name = rawName.trim();
      final spec = entry.value;
      if (spec is! Map) {
        throw JsonRpcException(JsonRpcErrorCode.invalidParams,
            'provider "$name" 的配置必须是对象');
      }
      final rawBaseUrl = spec['base_url'];
      if (rawBaseUrl is! String || rawBaseUrl.trim().isEmpty) {
        throw JsonRpcException(JsonRpcErrorCode.invalidParams,
            'provider "$name" 缺 base_url');
      }
      final baseUrl = rawBaseUrl.trim();
      final uri = Uri.tryParse(baseUrl);
      if (uri == null ||
          !uri.hasScheme ||
          (uri.scheme != 'http' && uri.scheme != 'https') ||
          uri.host.isEmpty) {
        throw JsonRpcException(
          JsonRpcErrorCode.invalidParams,
          '网关地址必须是以 http:// 或 https:// 开头的绝对地址'
          '（provider "$name" 收到 "$baseUrl"）',
        );
      }
      final rawApiKey = spec['api_key'];
      if (rawApiKey != null && rawApiKey is! String) {
        throw JsonRpcException(JsonRpcErrorCode.invalidParams,
            'provider "$name" 的 api_key 必须是字符串或省略');
      }
      final rawRename = spec['rename_from'];
      if (rawRename != null && rawRename is! String) {
        throw JsonRpcException(JsonRpcErrorCode.invalidParams,
            'provider "$name" 的 rename_from 必须是字符串或省略');
      }
      final renameFrom = (rawRename as String?)?.trim();

      ProviderConfig? before;
      if (renameFrom != null && renameFrom.isNotEmpty && renameFrom != name) {
        before = current.providers[renameFrom];
        if (before == null) {
          throw JsonRpcException(JsonRpcErrorCode.invalidParams,
              '被改名的 provider "$renameFrom" 不存在：保存被拒绝');
        }
        if (current.providers.containsKey(name)) {
          throw JsonRpcException(JsonRpcErrorCode.invalidParams,
              'Provider "$name" 已存在：改名目标被占用，保存被拒绝');
        }
        renames[renameFrom] = name;
      } else {
        before = current.providers[name];
      }

      final typedKey = ((rawApiKey as String?) ?? '').trim();
      final apiKey = typedKey.isEmpty ? (before?.apiKey ?? '') : typedKey;
      if (apiKey.isEmpty) {
        throw JsonRpcException(JsonRpcErrorCode.invalidParams,
            '请填写 API Key（provider "$name" 是新增的，没有可沿用的旧密钥）');
      }
      // 向导用：把 probeFetch 探测到的目录随同一次保存写盘（不再联网探测第二次），
      // 可选；不传 = 保留既有目录与 discovered_at（编辑 provider 不丢目录）。
      final rawModels = spec['models'];
      List<ModelCatalogEntry> models = before?.models ?? const [];
      String? discoveredAt = before?.discoveredAt;
      if (rawModels != null) {
        if (rawModels is! List) {
          throw JsonRpcException(JsonRpcErrorCode.invalidParams,
              'provider "$name" 的 models 必须是数组或省略');
        }
        final parsed = <ModelCatalogEntry>[];
        for (var index = 0; index < rawModels.length; index++) {
          final entry = ModelCatalogEntry.fromJson(rawModels[index]);
          if (entry == null) {
            throw JsonRpcException(
              JsonRpcErrorCode.invalidParams,
              'provider "$name" 的 models[$index] 缺字符串 id：目录条目被拒绝'
              '（不静默丢弃，也不写半份目录）',
            );
          }
          parsed.add(entry);
        }
        models = List<ModelCatalogEntry>.unmodifiable(parsed);
        final rawDiscoveredAt = spec['discovered_at'];
        if (rawDiscoveredAt != null && rawDiscoveredAt is! String) {
          throw JsonRpcException(JsonRpcErrorCode.invalidParams,
              'provider "$name" 的 discovered_at 必须是字符串或省略');
        }
        final typedDiscoveredAt = (rawDiscoveredAt as String?)?.trim();
        discoveredAt = (typedDiscoveredAt != null && typedDiscoveredAt.isNotEmpty)
            ? typedDiscoveredAt
            : DateTime.now().toUtc().toIso8601String();
      }
      nextProviders[name] = ProviderConfig(
        apiKey: apiKey,
        baseUrl: normalizeBaseUrl(baseUrl),
        models: models,
        discoveredAt: discoveredAt,
      );
    }

    // 改名：同一保存动作里级联改写引用旧名的模板。
    final types = Map<String, AgentTypeConfig>.from(current.agentTypes);
    for (final rename in renames.entries) {
      for (final template in types.entries.toList()) {
        if (template.value.provider == rename.key) {
          types[template.key] = AgentTypeConfig.fromJson(template.key, {
            ...template.value.toJson(),
            'provider': rename.value,
          });
        }
      }
    }

    // 删除：现存但没提交、也不是被改名旧名。被模板引用 ⇒ 拒绝并点名引用名单。
    final removed = <String>[
      for (final name in current.providers.keys)
        if (!nextProviders.containsKey(name) && !renames.containsKey(name)) name,
    ];
    for (final name in removed) {
      final refs = <String>[
        for (final template in types.entries)
          if (template.value.provider == name) template.key,
      ];
      if (refs.isNotEmpty) {
        throw JsonRpcException(
          JsonRpcErrorCode.invalidParams,
          'provider "$name" 被 ${refs.join("、")} 引用，不能删除'
          '（删掉会留下悬空的模板引用）',
        );
      }
    }

    final next = current.copyWith(providers: nextProviders, agentTypes: types);
    ConfigService.save(next, configPath: configPath);
    applyConfig(next);
    return {'config': _redactedConfig(next)};
  }

  /// `profile.save{avatarPath}`：写用户资料块（change `chat-bubbles-avatars` D3）。
  ///
  /// `avatarPath` **必填字符串**：`''` = 清除、非空 = 设为该路径；省略 / null / 其它
  /// 类型 ⇒ `-32602`（它是一次写操作，不允许"什么都没写"却返回成功）。
  ///
  /// **先 `_readLatestConfig()` 再 `copyWith(profile: …)` 最后整份写回**：即使内存里
  /// 有一份旧快照，也不能盖掉别人刚写进磁盘的 provider / 模板。它**不调** `applyConfig`
  /// —— 用户资料不参与 resolver / 模板注册，运行中的核心不读它（不变量判据见
  /// `test/integration/web_management_rpc_test.dart` 的「读盘不变量」）。
  Future<Map<String, dynamic>> _handleProfileSave(
      Map<String, dynamic> params) async {
    if (!params.containsKey('avatarPath')) {
      throw const JsonRpcException(
        JsonRpcErrorCode.invalidParams,
        'Invalid params: avatarPath 必填字符串（"" = 清除用户头像；省略/null 都不允许）',
      );
    }
    final rawAvatar = params['avatarPath'];
    if (rawAvatar is! String) {
      throw const JsonRpcException(
        JsonRpcErrorCode.invalidParams,
        'Invalid params: avatarPath 必须是字符串（"" = 清除用户头像）',
      );
    }
    final typed = rawAvatar.trim();
    final avatarPath = typed.isEmpty ? null : _requireAvatarPath(typed);
    final current = _readLatestConfig();
    final nextProfile = UserProfile(
      avatarPath: avatarPath,
      userId: current.profile?.userId,
    );
    final next = current.copyWith(
      profile: nextProfile,
      // 两项都没有值时整块不写出（旧配置不因清除头像产生空块）。
      clearProfile: nextProfile.isEmpty,
    );
    ConfigService.save(next, configPath: configPath);
    return {'profile': _profilePayload(next.profile)};
  }

  /// `provider.probe`：= `ModelDiscoveryService.discover`（要求 provider 已存在，
  /// 成功写回 catalog + discovered_at）。用**盘上最新配置**探测，避免内存旧快照
  /// 盖掉刚写的编辑（D1）。
  Future<Map<String, dynamic>> _handleProviderProbe(
      Map<String, dynamic> params) async {
    final providerName = _requireString(params, 'providerName');
    final latest = _readLatestConfig();
    if (!latest.providers.containsKey(providerName)) {
      throw JsonRpcException(JsonRpcErrorCode.invalidParams,
          'provider "$providerName" 不存在：探测被拒绝（先保存 provider）');
    }
    final discovery =
        ModelDiscoveryService(probe: probe, configPath: configPath);
    final report = await discovery.discover(latest, providerName);
    if (report.success) applyConfig(report.config);
    return {
      'ok': report.success,
      'providerName': report.providerName,
      'entries': [for (final model in report.entries) model.toJson()],
      'added': report.added,
      'updated': report.updated,
      'removed': report.removed,
      'dropped': report.dropped,
      'discoveredAt': report.discoveredAt,
      'error': report.error,
      'preview': report.preview,
      'totalChars': report.totalChars,
      'omittedChars': report.omittedChars,
      'errorFilePath': report.errorFilePath,
    };
  }

  /// `provider.probeFetch`：= `ModelCatalogProbe.fetch`，**只探测不写盘**（向导用，
  /// design D7 / D11）。Start 之前失败或放弃都不留半份配置。
  Future<Map<String, dynamic>> _handleProviderProbeFetch(
      Map<String, dynamic> params) async {
    final baseUrl = _requireString(params, 'baseUrl');
    final apiKey = _requireString(params, 'apiKey');
    final uri = Uri.tryParse(baseUrl.trim());
    if (uri == null ||
        !uri.hasScheme ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      throw JsonRpcException(
        JsonRpcErrorCode.invalidParams,
        '网关地址必须是以 http:// 或 https:// 开头的绝对地址（收到 "$baseUrl"）',
      );
    }
    final result = await probe.fetch(
      baseUrl: baseUrl.trim(),
      apiKey: apiKey.trim(),
      // 预览长度取产品既有配置（spill.preview_chars），不发明第二个数字。
      previewChars: config.spillPreviewChars,
    );
    return {
      'ok': result.ok,
      'providerName': params['providerName'] is String
          ? params['providerName'] as String
          : null,
      'entries': [for (final model in result.entries) model.toJson()],
      'dropped': result.dropped,
      'error': result.error,
      'preview': result.preview,
      'totalChars': result.totalChars,
      'omittedChars': result.omittedChars,
      'errorFilePath': result.errorFilePath,
    };
  }

  // ---------------------------------------------------------------------------
  // 模板（change `web-management-ui` 任务 3.2 / design D9 / D10）
  // ---------------------------------------------------------------------------

  /// `template.list`：模板表 + 工具目录 + provider 名 + 生效时机说明（同一句常量）。
  Future<Map<String, dynamic>> _handleTemplateList(
      Map<String, dynamic> params) async {
    final latest = _readLatestConfig();
    return {
      'templates': [
        for (final entry in latest.agentTypes.entries)
          {...entry.value.toJson(), 'name': entry.key},
      ],
      'tools': (ToolCatalog.instance.names.toList()..sort()),
      'providers': latest.providers.keys.toList(),
      // 新模板/向导要用的默认工具清单（产品数据，来源唯一：ToolCatalog）。
      'defaultTools': ToolCatalog.kBaseToolNames,
      // 编辑器下拉的选项来源（产品数据，来源唯一：执行层合法集合 / 模态白名单）。
      // 都是 Set ⇒ 显式转 List（JSON 编码不了 Set，会让整个响应编码失败）。
      'thinkingEfforts': AgentConfigResolver.kThinkingEfforts.toList(),
      'allowedModalities': AgentTypeConfig.kAllowedInputModalities.toList(),
      'effectiveNote': kAgentTemplateEffectiveNote,
    };
  }

  /// `template.save`：走 [AgentTemplateController.save]（同一套校验 + 完整配置写回）。
  ///
  /// 字段（design D9）：provider / model / tools / systemPrompt / thinkingEffort /
  /// maxContextTokens / inputModalities / 压缩与等待阈值；模板名创建后不可改。
  Future<Map<String, dynamic>> _handleTemplateSave(
      Map<String, dynamic> params) async {
    final name = _requireString(params, 'name');
    final rawOriginal = params['originalName'];
    if (rawOriginal != null && rawOriginal is! String) {
      throw const JsonRpcException(JsonRpcErrorCode.invalidParams,
          'Invalid params: originalName 必须是字符串或省略（省略 = 新增）');
    }
    final rawWindow = params['maxContextTokens'];
    String windowText;
    if (rawWindow == null) {
      windowText = '';
    } else if (rawWindow is int) {
      windowText = '$rawWindow';
    } else if (rawWindow is String) {
      windowText = rawWindow;
    } else {
      throw const JsonRpcException(JsonRpcErrorCode.invalidParams,
          'Invalid params: maxContextTokens 必须是整数或字符串（留空 = 用目录窗口）');
    }
    final tools = _optionalStringList(params, 'tools');
    final rawModalities = params['inputModalities'];
    List<String>? modalities;
    if (rawModalities != null) {
      if (rawModalities is! List ||
          rawModalities.any((item) => item is! String)) {
        throw const JsonRpcException(JsonRpcErrorCode.invalidParams,
            'Invalid params: inputModalities 必须是字符串数组');
      }
      modalities = rawModalities.cast<String>();
    }
    final rawCompaction = params['compactionThresholdPercent'];
    if (rawCompaction != null && rawCompaction is! int) {
      throw const JsonRpcException(JsonRpcErrorCode.invalidParams,
          'Invalid params: compactionThresholdPercent 必须是整数');
    }
    final rawWait = params['compactionWaitThresholdPercent'];
    if (rawWait != null && rawWait is! int) {
      throw const JsonRpcException(JsonRpcErrorCode.invalidParams,
          'Invalid params: compactionWaitThresholdPercent 必须是整数');
    }
    // 头像三态（change `chat-bubbles-avatars` D3）：省略 / 显式 null ⇒ 不改；'' ⇒ 清除；
    // 非空 ⇒ 设为该路径（必须在附件目录内且是存在的文件）；其它类型 ⇒ -32602。
    // 注意它与「配置读取侧」口径不同：读取侧的空串是手误、读作"没有覆盖"，不是清除。
    final rawAvatar = params['avatarPath'];
    String? avatarPathDraft;
    if (!params.containsKey('avatarPath') || rawAvatar == null) {
      avatarPathDraft = null;
    } else if (rawAvatar is! String) {
      throw const JsonRpcException(
        JsonRpcErrorCode.invalidParams,
        'Invalid params: avatarPath 必须是字符串或省略/null'
        '（省略/null = 不改，"" = 清除头像）',
      );
    } else {
      final typedAvatar = rawAvatar.trim();
      avatarPathDraft =
          typedAvatar.isEmpty ? '' : _requireAvatarPath(typedAvatar);
    }

    // 从盘上重读最新配置：不要拿内存旧快照盖掉用户刚写进去的 providers。
    templateController.replaceConfig(_readLatestConfig());
    final draft = AgentTemplateDraft(
      originalName: rawOriginal as String?,
      name: name,
      provider: (params['provider'] as String?) ?? '',
      model: (params['model'] as String?) ?? '',
      thinkingEffort: (params['thinkingEffort'] as String?) ?? '',
      systemPrompt: (params['systemPrompt'] as String?) ?? '',
      tools: tools,
      maxContextTokensText: windowText,
      inputModalities: modalities,
      compactionThresholdPercent: rawCompaction as int?,
      compactionWaitThresholdPercent: rawWait as int?,
      avatarPath: avatarPathDraft,
    );
    try {
      final result = templateController.save(draft);
      applyConfig(result.config);
      return {
        'template': {...result.template.toJson(), 'name': result.template.name},
        'created': result.created,
      };
    } on AgentTemplateValidationException catch (e) {
      throw JsonRpcException(JsonRpcErrorCode.invalidParams,
          '模板校验失败（${e.field}）：${e.message}');
    } on DuplicateAgentTypeException catch (e) {
      throw JsonRpcException(JsonRpcErrorCode.invalidParams, '$e');
    } on MissingAgentTypeException catch (e) {
      throw JsonRpcException(JsonRpcErrorCode.invalidParams, '$e');
    }
  }

  /// `template.delete`（design D10）：general 不可删；**被会话引用拒删并显示名单**；
  /// 成功则写回配置 + 组合根同步。
  Future<Map<String, dynamic>> _handleTemplateDelete(
      Map<String, dynamic> params) async {
    final name = _requireString(params, 'templateName');
    if (name == 'general') {
      throw const JsonRpcException(JsonRpcErrorCode.invalidParams,
          'general 模板不可删：SessionRepository.create 默认用它，删掉会让新会话失去模板');
    }
    final latest = _readLatestConfig();
    if (!latest.agentTypes.containsKey(name)) {
      throw JsonRpcException(JsonRpcErrorCode.invalidParams,
          '模板 "$name" 不存在：删除被拒绝（不静默 no-op）');
    }
    // 引用守卫：防 `sessions.agent_type` 悬空（删掉后那些会话再也建不出实例）。
    final sessions = await sessionRepo.list();
    final refs = <String>[
      for (final session in sessions)
        if (session.agentType == name) '${session.title}（${session.id}）',
    ];
    if (refs.isNotEmpty) {
      throw JsonRpcException(
        JsonRpcErrorCode.invalidParams,
        '模板 "$name" 被 ${refs.join("、")} 引用，不能删除'
        '（先删除这些会话，或把它们切换到别的模板）',
      );
    }
    final types = Map<String, AgentTypeConfig>.from(latest.agentTypes)
      ..remove(name);
    final next = latest.copyWith(agentTypes: types);
    ConfigService.save(next, configPath: configPath);
    applyConfig(next);
    return {'templateName': name, 'deleted': true};
  }

  // ---------------------------------------------------------------------------
  // 附件（change `web-management-ui` 任务 2.1 / design D12）
  // ---------------------------------------------------------------------------

  /// `attachment.upload{filename, base64}`：把一张图片写进注入的 `attachmentsDir`。
  ///
  /// 两道门都复用产品既有实现，不发明新口径：
  ///   - 大小上限 [kMaxImageBytes]（32 MiB，出处 `Docs/DeepSeekAPIDoc.md` §6.4.3）；
  ///   - 类型判定 [probeImageBytes]（**文件头魔数**，扩展名与 MIME 不作数）。
  /// 超限 / 非图片都**可归因拒绝且不落盘**（不静默截断、不写成坏文件）。
  Future<Map<String, dynamic>> _handleAttachmentUpload(
      Map<String, dynamic> params) async {
    final filename = _requireString(params, 'filename');
    final base64Text = _requireString(params, 'base64');
    List<int> decoded;
    try {
      decoded = base64Decode(base64Text);
    } on FormatException catch (e) {
      throw JsonRpcException(JsonRpcErrorCode.invalidParams,
          'Invalid params: base64 解码失败（$e）；上传已拒绝，未落盘');
    }
    if (decoded.length > kMaxImageBytes) {
      throw JsonRpcException(
        JsonRpcErrorCode.invalidParams,
        '图片 ${decoded.length} 字节超过单张上限 $kMaxImageBytes 字节（32 MiB，'
        '出处 Docs/DeepSeekAPIDoc.md §6.4.3）：上传已拒绝，不落盘、不截断',
      );
    }
    final bytes = Uint8List.fromList(decoded);
    final info = probeImageBytes(bytes);
    if (info.format == ImageFormat.unknown) {
      throw const JsonRpcException(
        JsonRpcErrorCode.invalidParams,
        '不是支持的图片格式：只认文件头魔数 PNG / JPEG / GIF / WebP，'
        '扩展名与声明的 MIME 不作数；上传已拒绝，未落盘',
      );
    }

    final dir = Directory(attachmentsDir);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    // 只保留文件名部分（防目录穿越），再把不安全字符换掉。
    final rawBase = p.basename(filename);
    final safeBase = rawBase.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final unique = '${DateTime.now().microsecondsSinceEpoch}_'
        '${safeBase.isEmpty || safeBase == '.' ? 'image' : safeBase}';
    final file = File(p.join(dir.path, unique));
    file.writeAsBytesSync(bytes, flush: true);
    return {
      'path': file.path,
      'bytes': bytes.length,
      'format': info.format.name,
      'mediaType': info.mediaType,
      'width': info.width,
      'height': info.height,
    };
  }

  /// `attachment.read{path}`：把附件字节读成 base64 给浏览器（design D12 现状 10）。
  ///
  /// 为什么不走静态服务：`_serveStatic` 明确拒绝 web 根之外的文件，而附件在
  /// `~/.aliasagent/attachments/`。这里只允许读**注入的 attachmentsDir 内**的文件。
  Future<Map<String, dynamic>> _handleAttachmentRead(
      Map<String, dynamic> params) async {
    final path = _requireString(params, 'path');
    final dirAbs = p.normalize(p.absolute(attachmentsDir));
    final fileAbs = p.normalize(p.absolute(path));
    if (fileAbs != dirAbs && !p.isWithin(dirAbs, fileAbs)) {
      throw JsonRpcException(
        JsonRpcErrorCode.invalidParams,
        '只允许读取附件目录（$dirAbs）内的文件：拒绝 "$path"',
      );
    }
    final file = File(fileAbs);
    if (!file.existsSync()) {
      // 可见提示（design D12）：历史消息还引用着路径，但文件已经不在了。
      throw JsonRpcException(JsonRpcErrorCode.invalidParams,
          '图片已丢失：附件文件不存在（$fileAbs）');
    }
    final bytes = file.readAsBytesSync();
    final info = probeImageBytes(bytes);
    return {
      'path': fileAbs,
      'bytes': bytes.length,
      'base64': base64Encode(bytes),
      'mediaType': info.format == ImageFormat.unknown
          ? 'application/octet-stream'
          : info.mediaType,
    };
  }

  // ---------------------------------------------------------------------------
  // 群聊（change `agent-group-chat` §7 / design D10、D16、D18）
  // ---------------------------------------------------------------------------

  /// 把组服务抛出的可归因错误转成 JSON-RPC 错误（带 code 与对象 id）。
  JsonRpcException _groupError(GroupException e) => JsonRpcException(
        JsonRpcErrorCode.invalidParams,
        '群聊请求失败（${e.code}）：${e.message}',
      );

  Future<Map<String, dynamic>> _handleGroupCreate(
      Map<String, dynamic> params) async {
    final rawTitle = params['title'];
    if (rawTitle != null && rawTitle is! String) {
      throw const JsonRpcException(
          JsonRpcErrorCode.invalidParams, 'Invalid params: title 必须是字符串或省略');
    }
    final rawWorkspace = params['workspace'];
    if (rawWorkspace != null && rawWorkspace is! String) {
      throw const JsonRpcException(JsonRpcErrorCode.invalidParams,
          'Invalid params: workspace 必须是字符串或省略');
    }
    // 组的自发反应开关（change `group-reactive-mode` D9）：布尔，省略 = 新建组默认
    // 开启（`true` 由 `GroupService.createGroup` 的缺省给出，不在 RPC 层写第二份）。
    final rawReactions = params['reactionsEnabled'];
    if (rawReactions != null && rawReactions is! bool) {
      throw const JsonRpcException(JsonRpcErrorCode.invalidParams,
          'Invalid params: reactionsEnabled 必须是布尔或省略');
    }
    // 组的反应轮数上限（R.3 / D13）：整数 1..50 或省略 / null（= 产品默认）。
    final rawMaxRounds = params['maxRounds'];
    if (rawMaxRounds != null && rawMaxRounds is! int) {
      throw const JsonRpcException(JsonRpcErrorCode.invalidParams,
          'Invalid params: maxRounds 必须是整数或省略（null = 用产品默认）');
    }
    final maxRounds = rawMaxRounds as int?;
    if (!isValidMaxReactionRounds(maxRounds)) {
      throw JsonRpcException(JsonRpcErrorCode.invalidParams,
          'Invalid params: maxRounds 必须是 $kMinMaxReactionRounds..$kMaxMaxReactionRounds '
              '的整数或省略（收到 $maxRounds）');
    }
    try {
      final session = await groups.createGroup(
        title: rawTitle as String?,
        workspace: rawWorkspace as String?,
        reactionsEnabled: rawReactions as bool?,
        maxRounds: maxRounds,
      );
      return {'group': serializeSession(session)};
    } on GroupException catch (e) {
      throw _groupError(e);
    }
  }

  /// `group.update`：改组的两个运行设置（自发反应开关 / 反应轮数上限）并返回更新后的
  /// 会话（change `group-reactive-mode` D1 / R.3）。
  ///
  /// 至少给一个字段；`reactionsEnabled` 必须布尔；`maxRounds` 必须是 1..50 的整数或
  /// **显式 null**（恢复默认；与字段缺席不同：缺席 = 不改）。类型不对 / 越界 /
  /// 空对象 ⇒ `-32602`；组不存在 / 链运行中 busy ⇒ 可归因错误。
  Future<Map<String, dynamic>> _handleGroupUpdate(
      Map<String, dynamic> params) async {
    final groupId = _requireString(params, 'groupId');
    final hasReactions = params.containsKey('reactionsEnabled');
    final rawReactions = params['reactionsEnabled'];
    if (hasReactions && rawReactions is! bool) {
      throw const JsonRpcException(JsonRpcErrorCode.invalidParams,
          'Invalid params: reactionsEnabled 必须是布尔');
    }
    final hasMaxRounds = params.containsKey('maxRounds');
    final rawMaxRounds = params['maxRounds'];
    if (hasMaxRounds && rawMaxRounds != null && rawMaxRounds is! int) {
      throw const JsonRpcException(JsonRpcErrorCode.invalidParams,
          'Invalid params: maxRounds 必须是整数或显式 null（恢复默认）');
    }
    if (!hasReactions && !hasMaxRounds) {
      throw const JsonRpcException(JsonRpcErrorCode.invalidParams,
          'Invalid params: group.update 至少要给一个字段（reactionsEnabled / maxRounds）');
    }
    try {
      final session = await groups.updateGroupSettings(
        groupId,
        reactionsEnabled: rawReactions as bool?,
        maxRounds: rawMaxRounds as int?,
        setMaxRounds: hasMaxRounds,
      );
      return {'group': serializeSession(session)};
    } on GroupException catch (e) {
      throw _groupError(e);
    }
  }

  /// `group.chain`：返回当前 / 最近一条链的只读状态（change `group-reactive-mode`
  /// R.3 / D9）。核心重启后为 `idle`（本进程内语义）。
  Future<Map<String, dynamic>> _handleGroupChain(
      Map<String, dynamic> params) async {
    final groupId = _requireString(params, 'groupId');
    try {
      await groups.requireGroup(groupId);
      return groups.chainOf(groupId).toJson();
    } on GroupException catch (e) {
      throw _groupError(e);
    }
  }

  Future<Map<String, dynamic>> _handleGroupList(
      Map<String, dynamic> params) async {
    final entries = await groups.listGroups();
    final out = <Map<String, dynamic>>[];
    for (final entry in entries) {
      out.add({
        ...serializeSession(entry.session),
        'members': await groups.describeMembers(entry.session.id),
        // 只读忙碌状态（change `group-reactive-mode` D7 / D9）：断线重连后的 web 靠
        // 它判断"链在跑/谁在跑"，从而启用取消按钮（不依赖本地 sending 状态）。
        'busy': groups.isGroupBusy(entry.session.id),
        'runningMemberId': groups.runningMemberIdOf(entry.session.id),
      });
    }
    return {'groups': out};
  }

  Future<Map<String, dynamic>> _handleGroupDelete(
      Map<String, dynamic> params) async {
    final groupId = _requireString(params, 'groupId');
    try {
      await groups.deleteGroup(groupId);
      return {'groupId': groupId, 'deleted': true};
    } on GroupException catch (e) {
      throw _groupError(e);
    }
  }

  /// 解析 `overrides` 参数（对象 / 省略）；显式 `null` 当作"没有覆盖"。
  AgentInstanceOverrides? _optionalOverrides(
      Map<String, dynamic> params, String key) {
    final raw = params[key];
    if (raw == null) return null;
    if (raw is! Map) {
      throw JsonRpcException(JsonRpcErrorCode.invalidParams,
          'Invalid params: $key 必须是对象或省略');
    }
    try {
      return AgentInstanceOverrides.fromJson(
          Map<String, dynamic>.from(raw));
    } on AgentOverridesException catch (e) {
      throw JsonRpcException(
          JsonRpcErrorCode.invalidParams, '覆盖层被拒绝：${e.message}');
    }
  }

  Future<Map<String, dynamic>> _describeSingleMember(
      String groupId, String memberId) async {
    final members = await groups.describeMembers(groupId);
    for (final member in members) {
      if (member['id'] == memberId) return member;
    }
    throw JsonRpcException(JsonRpcErrorCode.internalError,
        '成员 "$memberId" 写入了但读不回来（组 "$groupId"）');
  }

  Future<Map<String, dynamic>> _handleGroupMemberAdd(
      Map<String, dynamic> params) async {
    final groupId = _requireString(params, 'groupId');
    final name = _requireString(params, 'name');
    final templateName = _requireString(params, 'templateName');
    final overrides = _optionalOverrides(params, 'overrides');
    try {
      final member = await groups.addMember(
        groupId: groupId,
        name: name,
        templateName: templateName,
        overrides: overrides,
      );
      return {
        'groupId': groupId,
        'member': await _describeSingleMember(groupId, member.id),
      };
    } on GroupMemberNameConflictException catch (e) {
      throw JsonRpcException(
          JsonRpcErrorCode.invalidParams, '加入成员被拒绝：$e');
    } on GroupException catch (e) {
      throw _groupError(e);
    } on AgentConfigException catch (e) {
      throw JsonRpcException(
          JsonRpcErrorCode.invalidParams, '成员实例创建失败：$e');
    } on UnknownToolsException catch (e) {
      throw JsonRpcException(
          JsonRpcErrorCode.invalidParams, '成员实例创建失败：$e');
    }
  }

  Future<Map<String, dynamic>> _handleGroupMemberRemove(
      Map<String, dynamic> params) async {
    final groupId = _requireString(params, 'groupId');
    final memberId = _requireString(params, 'memberId');
    try {
      await groups.removeMember(groupId, memberId);
      return {'groupId': groupId, 'memberId': memberId, 'removed': true};
    } on GroupException catch (e) {
      throw _groupError(e);
    }
  }

  Future<Map<String, dynamic>> _handleGroupMemberUpdate(
      Map<String, dynamic> params) async {
    final groupId = _requireString(params, 'groupId');
    final memberId = _requireString(params, 'memberId');
    final rawName = params['name'];
    if (rawName != null && rawName is! String) {
      throw const JsonRpcException(
          JsonRpcErrorCode.invalidParams, 'Invalid params: name 必须是字符串或省略');
    }
    final rawTemplate = params['templateName'];
    if (rawTemplate != null && rawTemplate is! String) {
      throw const JsonRpcException(JsonRpcErrorCode.invalidParams,
          'Invalid params: templateName 必须是字符串或省略');
    }
    final rawClear = params['clearOverrides'];
    if (rawClear != null && rawClear is! bool) {
      throw const JsonRpcException(JsonRpcErrorCode.invalidParams,
          'Invalid params: clearOverrides 必须是布尔或省略');
    }
    final overrides = _optionalOverrides(params, 'overrides');
    try {
      final member = await groups.updateMember(
        groupId: groupId,
        memberId: memberId,
        name: rawName as String?,
        templateName: rawTemplate as String?,
        overrides: overrides,
        clearOverrides: rawClear == true,
      );
      return {
        'groupId': groupId,
        'member': await _describeSingleMember(groupId, member.id),
      };
    } on GroupMemberNameConflictException catch (e) {
      throw JsonRpcException(
          JsonRpcErrorCode.invalidParams, '修改成员被拒绝：$e');
    } on GroupException catch (e) {
      throw _groupError(e);
    }
  }

  Future<Map<String, dynamic>> _handleGroupSend(
      Map<String, dynamic> params) async {
    await _ready;
    final groupId = _requireString(params, 'groupId');
    // `speaker` **可选**（change `group-reactive-mode` D9）：出现时必须是非空字符串
    // （类型/空串不对 ⇒ -32602）；省略 = 由组服务按 reactionsEnabled 与 @mention
    // 决定响应者。模式相关的校验（no_speaker / no_trigger）交给组服务 ——
    // 那是它的语义，RPC 层不复制；`group.send` 永不 busy。
    final rawSpeaker = params['speaker'];
    if (rawSpeaker != null && rawSpeaker is! String) {
      throw const JsonRpcException(JsonRpcErrorCode.invalidParams,
          'Invalid params: speaker 必须是字符串或省略');
    }
    final speaker = rawSpeaker as String?;
    if (speaker != null && speaker.trim().isEmpty) {
      throw const JsonRpcException(JsonRpcErrorCode.invalidParams,
          'Invalid params: speaker 出现时必须是非空字符串（要"不点名"请省略该字段）');
    }
    final rawText = params['text'];
    if (rawText != null && rawText is! String) {
      throw const JsonRpcException(
          JsonRpcErrorCode.invalidParams, 'Invalid params: text 必须是字符串或省略');
    }
    try {
      final outcome = await groups.send(
        groupId: groupId,
        memberId: speaker,
        text: rawText as String?,
      );
      // 异步契约（change `group-reactive-mode` R.3/R.8 / D9）：只返回
      // `{groupId, sessionId, status: started, triggerSeq}`（永不 busy）；步骤、轮数、
      // 终态从 `group.chain` 与 `group.chain.completed` 读。`turn.failed` 由组服务在
      // 后台按**真实失败**的步骤发（`onTurnFailed`），这里不再看 outcome。
      return {
        'groupId': groupId,
        'sessionId': groupId,
        ...outcome.toJson(),
      };
    } on GroupException catch (e) {
      throw _groupError(e);
    }
  }

  /// `group.setWorkspace`：切换组的共享工作路径（change `custom-workspace` D6 / D7）。
  ///
  /// 走组服务的唯一实现（校验 → 组上下文生效 → 落库 → 传播到成员 → 重读）；可归因
  /// `GroupException`（含 busy / invalid_workspace / workspace_propagation_failed）统一经
  /// [_groupError] 变成 `-32602`。kind 不符在这里显式指向 `session.setWorkspace`。
  Future<Map<String, dynamic>> _handleGroupSetWorkspace(
      Map<String, dynamic> params) async {
    final groupId = _requireString(params, 'groupId');
    final rawWorkspace = params['workspace'];
    if (rawWorkspace is! String) {
      throw const JsonRpcException(JsonRpcErrorCode.invalidParams,
          'Invalid params: workspace 必填且必须是字符串（要回主目录请显式传主目录路径）');
    }
    final existing = await sessionRepo.get(groupId);
    if (existing != null && !existing.isGroup) {
      throw JsonRpcException(
        JsonRpcErrorCode.invalidParams,
        '会话 "$groupId" 是单聊会话（kind=${existing.kind}）：'
            '单聊的工作路径请用 session.setWorkspace（组才会传播到成员）',
      );
    }
    try {
      final session = await groups.setWorkspace(groupId, rawWorkspace);
      return {'group': serializeSession(session)};
    } on GroupException catch (e) {
      throw _groupError(e);
    }
  }

  Future<Map<String, dynamic>> _handleGroupView(
      Map<String, dynamic> params) async {
    final groupId = _requireString(params, 'groupId');
    final memberId = _requireString(params, 'memberId');
    try {
      await groups.requireGroup(groupId);
      await groups.requireMember(groupId, memberId);
      final snapshot = groups.snapshotOf(memberId);
      return {
        'groupId': groupId,
        'memberId': memberId,
        // 本次运行内没发过言（或已重启）⇒ null：界面显示占位，绝不用历史拼一份
        // "没发过的上下文"。
        'snapshot': snapshot == null ? null : serializeContextSnapshot(snapshot),
      };
    } on GroupException catch (e) {
      throw _groupError(e);
    }
  }

  String _requireString(Map<String, dynamic> params, String key) {    final value = params[key];
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

  /// 该会话的界面回调：把 `AgentCallbacks` 映射成 `agent.event` 通知（D9）。
  ///
  /// 公开（而不是私有）：`session.switchTemplate` / `session.delete` 必须把**当前**
  /// 回调交给新实例，组合根之外（测试）也要能核对"事件到底发往谁"。
  AgentCallbacks callbacksFor(String sessionId) =>
      _eventCallbacks(sessionId, sessionId, null, null);

  /// 成员事件回调：事件在既有 `sessionId` 之外带 `groupId` + `memberId`
  /// （spec「成员事件带身份」；事件类型与语义不新造）。
  AgentCallbacks callbacksForMember(GroupMember member) => _eventCallbacks(
        member.groupSessionId,
        member.handle,
        member.groupSessionId,
        member.id,
      );

  AgentCallbacks _eventCallbacks(
      String sessionId, String handle, String? groupId, String? memberId) {
    void event(String type, Map<String, dynamic> data) => _sendEvent(
          sessionId,
          type,
          data,
          groupId: groupId,
          memberId: memberId,
        );
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
            agents.lookup(handle)?.compactionStatus ?? CompactionStatus.idle;
        event('compaction.status', serializeCompactionStatus(status));
      },
      onTitleChanged: (title) => event('session.title', {'title': title}),
      onMeteringChanged: () {
        final metering = agents.lookup(handle)?.metering;
        event('agent.metering', metering?.toJson() ?? const {});
      },
    );
  }

  void _sendEvent(
      String sessionId, String type, Map<String, dynamic> data,
      {String? groupId, String? memberId}) {
    _broadcast('agent.event', {
      // `sessionId` 保留（既有消费者不受影响）；组事件另带 groupId/memberId。
      'sessionId': sessionId,
      'groupId': ?groupId,
      'memberId': ?memberId,
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
      // 客户端据此分流：组会话 → 组视图，单会话 → 聊天屏（agent-group-chat D16）。
      'kind': session.kind,
      // 组的自发反应开关（change `group-reactive-mode` D9）：组与单会话都写，客户端
      // 只对组使用（单会话的值无行为意义）。
      'reactionsEnabled': session.reactionsEnabled,
      // 反应轮数上限（R.3 / D13）：整数或 null（null = 用产品默认 8，客户端以默认值
      // 占位显示）。它是 `sessions` 列，不是 config.json 键。
      'maxRounds': session.maxRounds,
      // 会话级覆盖层：可空字段如实写出（没有覆盖时是 null，不是 {}）。
      'overrides': session.overrides?.toJson(),
      // 工作路径设置值（change `custom-workspace` D6）：null = 未设置（用缺省主目录）。
      // 每次序列化都写该键，客户端据此显示「缺省（应用主目录）」或实际路径。
      'workspace': session.workspace,
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
  String? configPath,
  String? attachmentsDir,
  // 文件夹选择对话框的缺省起点（返工任务 12.2）：省略 = `ConfigService.homeDir`。
  String? homeDir,
  ModelCatalogProbe? probe,
}) async {
  if (openDatabase != null) await openDatabase();

  final templates = AgentTypeRegistry();
  for (final template in config.agentTypes.values) {
    templates.register(template);
  }
  final providers = ProviderResolverRef(ProviderResolver(config));  final sessionRepo = sessionRepository ?? SessionRepository();
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
              providerResolver: () => providers.current,
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
    providerResolver: () => providers.current,
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

  // 会话模板切换 / 删除互斥的协调者（design D3）。组合根构造一次，RPC 层复用；
  // 注入 factory + sessionRepo，退役动作走 Agent.retire 的产品默认值。
  final sessionController = AgentSessionController(
    factory: factory,
    sessionRepo: sessionRepo,
  );

  // 模板编辑 / 删除的协调者（design D9 / D10）：写盘路径与校验规则与 Flutter 侧同一份。
  final templateController = AgentTemplateController(
    registry: templates,
    config: config,
    knownTools: () => ToolCatalog.instance.nameSet,
    configPath: configPath,
  );

  // 组服务（change `agent-group-chat` §5）。回调晚绑定到 core：成员事件的
  // groupId/memberId 由 core 的 `callbacksForMember` 组装。
  late final HeadlessCore core;
  final groups = GroupService(
    sidecar: sidecar,
    sessionRepo: sessionRepo,
    memberRepo: GroupMemberRepository(),
    messageRepo: messageRepo,
    summaryNodeRepo: summaryNodeRepo,
    agents: agents,
    factory: factory,
    templates: templates,
    callbacksForMember: (member) => core.callbacksForMember(member),
    // 组服务自己写入的用户消息**不带 memberId**（这条消息没有成员作者），标题变化
    // 同理由组服务发 `session.title`（change `group-reactive-mode` D9）。
    onUserMessage: (groupId, message) => core._sendEvent(
      groupId,
      'user.message',
      serializeMessage(message),
      groupId: groupId,
    ),
    onTitleChanged: (groupId, title) => core._sendEvent(
      groupId,
      'session.title',
      {'title': title},
      groupId: groupId,
    ),
    // 链进入终态 ⇒ 唯一新增的事件类型 `group.chain.completed`（payload 带
    // groupId/sessionId/status/stopReason/rounds/triggerSeq；**steps 不进事件**，
    // 需要时查 `group.chain`）。change `group-reactive-mode` R.2 / R.3 / D7。
    onChainCompleted: (chain) => core._sendEvent(
      chain.groupId,
      'group.chain.completed',
      {
        'status': chain.status,
        'stopReason': chain.stopReason,
        'rounds': chain.rounds,
        'triggerSeq': chain.triggerSeq,
      },
      groupId: chain.groupId,
    ),
    // `turn.failed` 只按**真实失败**步骤发（forced_pass / forced_empty 不是整轮失败，
    // 只在链状态的 steps 里可观察）。
    onTurnFailed: (groupId, step) => core._sendEvent(
      groupId,
      'turn.failed',
      {
        'error': step.error ?? '(整轮失败但没有错误文本)',
        'source': step.source,
        'status': step.status,
      },
      groupId: groupId,
      memberId: step.memberId,
    ),
  );

  core = HeadlessCore(
    config: config,
    sidecar: sidecar,
    sessionRepo: sessionRepo,
    messageRepo: messageRepo,
    summaryNodeRepo: summaryNodeRepo,
    templates: templates,
    agents: agents,
    factory: factory,
    subagentRunner: subagentRunner,
    providerResolverRef: providers,
    sessionController: sessionController,
    templateController: templateController,
    groups: groups,
    configPath: configPath ?? ConfigService.configPath,
    attachmentsDir: attachmentsDir ?? ConfigService.attachmentsDir,
    homeDir: homeDir,
    probe: probe ?? HttpModelCatalogProbe(),
    ready: toolsReady.future,
  );
  return core;
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
    String? attachmentsDir,
    ModelCatalogProbe? probe,
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
      String? startupNotice;
      if (configOverride != null) {
        config = configOverride;
      } else {
        final result = ConfigService.load(configPath: configPath);
        switch (result.status) {
          case ConfigStatus.ok:
            config = result.config!;
          case ConfigStatus.notFound:
            // design D2（change `web-management-ui`）：配置文件不存在时以**空配置**
            // 启动并 serve 首启向导，而不是拒启动。原「先运行一次 Flutter 应用完成
            // 首启配置」的门把 web 独立首启挡死了。
            config = const AppConfig(version: 1);
            startupNotice = '配置文件不存在：${configPath ?? ConfigService.configPath}\n'
                '以空配置启动：web 端会显示首启向导（填 provider 三要素 → 探测 → '
                '建 general 模板）。配置写回后运行中的核心会进程内同步。';
          case ConfigStatus.malformed:
            // 坏配置不静默当成空配置：那样会在用户不知情时用空表覆盖他的文件。
            throw HeadlessCoreStartupException(
                '配置文件无法解析：${result.error}\n'
                '（配置文件损坏不会静默当成空配置；先备份并修正它，或把它移走后'
                '重新启动以走首启向导。）');
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
        configPath: configPath,
        attachmentsDir: attachmentsDir,
        probe: probe,
      );
      core._lock = lock;
      core.startupNotice = startupNotice;
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
