## 1. 核心 foundation 解耦（前置，行为必须不变）

- [x] 1.1 把核心 services 六文件（agent / agent_config_resolver / compaction/model_summary_provider / sidecar_bridge / subagent_runner / skills/skill_catalog_service）**及传递依赖的 models 五文件（agent_type_config / app_config / provider_config / model_catalog_entry / message）**的 `package:flutter/foundation.dart` 解耦：`@visibleForTesting` 改从 `package:meta/meta.dart`；新增纯 Dart debugPrint shim——**必须是与 foundation 同签名 `(String?, {int? wrapWidth})` 的可重赋值全局函数变量**（保住既有 9 处 `debugPrint =` 日志捕获测试）。`Isolate` 不动。只换 import 与打印实现，不改业务逻辑。
- [x] 1.2 解耦后跑既有全量 `flutter test`（先 `scripts\sync_sidecar_dll.ps1`）必须原样全绿、`flutter analyze` 改动文件零新增；贴 `+N All tests passed!` 与 analyze 读数（基线以本轮实测为准，不沿用旧数字）。任何行为漂移立即回退本组。
- [x] 1.3 新增 `test/unit/core_headless_load_test.dart`：在纯 Dart 上下文 import 并实例化核心 services+models，断言可加载、shim 可重赋值且输出可观察。**红态运行器点名**：用 `dart test`（纯 VM，package:flutter 不可用）跑出先红，解耦后绿；贴红→绿与运行命令。

## 2. 无头组合根 + RPC/静态服务

- [x] 2.1 新增无头入口（`bin/alias_agent_core.dart`）与组合根：建图（ConfigService/DatabaseService/SidecarBridge/repositories/AgentTypeRegistry/ProviderResolver/AgentFactory/AgentSessionController）**并搬迁三段 UI 层启动逻辑**——① `sqfliteFfiInit(); databaseFactory = databaseFactoryFfi;`；② 工具目录播种与条件注册（把 main.dart `_initSearchAndTools` 的基础工具+load_skill schema、browser_available 探测、ensureSearchInfra/getSearchProviders 门控**抽取为共享函数**供两侧调用，不改 Flutter 行为）；③ `_toolsReadyCompleter` 发送门禁与 AgentFactory.summaryStoreOpen 真实谓词（开库后传真实谓词，不用 _neverOpen）。`HttpServer.bind(InternetAddress.loopbackIPv4, 0)` 取 OS 端口回显 URL。**单实例守卫**：启动取锁文件，已占用则显式失败退出提示"已有核心在运行"。DLL 裸名加载的 CWD 约定写进文档。
- [x] 2.2 实现 WebSocket 升级 + JSON-RPC 2.0 分发：带 id 请求/响应、无 id notification；非法 JSON/缺字段返回规范错误码（-32700/-32600/-32601/-32602/-32603）不崩溃。新增 `test/integration/web_core_rpc_test.dart`（假 sidecar，DB 用 openAt 注入隔离不污染用户库）：合法请求回响应、非法输入回错误、进程不崩。先写先红再实现，贴红→绿。
- [x] 2.3 实现 `AgentCallbacks`→`agent.event` notification 映射，暴露 `agent.send`/`agent.cancel`（复用 Agent.send / AgentFactory.ensure）。**序列化分类**：ToolCallActivity/AgentMetering 用现成 toJson；Message/ContextSnapshot/CompactionStatus 写显式适配函数（快照含窗口/拆分/breakdown，不得静默丢）；onCompactionStatusChanged/onMeteringChanged 回读 agent getter；技能失败明细随快照推送（逐条名+原因）；ensure 复用实例后把 callbacks 指向当前 WS 订阅者。**整轮 failed（如超工具轮次）推送可归因失败事件**。`test/integration/web_core_rpc_test.dart` 增用例：发送→流式+最终消息、工具轮、快照完整字段+技能提示、重连回调改向、取消收尾、失败轮事件；断言前打印实际事件序列。先红后绿。
- [x] 2.4 实现静态服务 serve `web/` 构建产物（生产）；开发期 Vite proxy 关系写文档。错误路径：sidecar 加载失败输出可归因信息不假装就绪（`test/integration` 用例，先红后绿）。

## 3. 消息分页查询（不复制全量载入反模式）

- [x] 3.1 在 `MessageRepository` 以**可选扩展/新接口**新增分页查询方法（游标+页大小，按 seq 稳定序），**不改既有接口签名**（保住 FakeMessageRepository/_RecordingMessageRepo 两个 implements 夹具编译）；保留 queryBySession 全量方法（Flutter 与 Agent.restore 仍用）。页大小请求方必填，核心不发明默认魔数。
- [x] 3.2 暴露 `session.list`/`message.query` RPC。`test/integration/web_core_rpc_test.dart` 增用例：分页只返回该页+下一页游标、**读路径不载入整条历史（SQL limit 或 repo 间谍计数可证，非仅断言返回页大小）**、缺 pageSize 回 -32602、会话列表只返回顶层按最近更新倒序。先红后绿贴现场。

## 4. web 最小聊天验证页（React+Vite+TS）

- [x] 4.1 新建 `web/` 子项目（React+Vite+TS，react-markdown、Tailwind，独立 lockfile）：连接核心 WS、发送消息、渲染流式 Markdown、显示工具卡片。仅最小验证页，不做完整聊天屏/F-002~F-004/虚拟滚动。
- [x] 4.2 `integration_test/web_core_shim_live_test.dart`（--tags live，真实模型）：启动无头核心→驱动 web 验证页发一条消息→断言流式回复与工具事件；断言前输出实际工具调用与事件序列。**视觉验收通道点名**：web 页在浏览器里，captureLiveShot 截不到——用 OS 全屏截图（CopyFromScreen，TESTING.md §4.4）或无头浏览器+页面内截图；跑完 `read_image` 读截图做视觉验收。拉起浏览器给用户看须用户当场许可，否则走无头浏览器通道。贴 live 输出与截图路径。

## 5. 用户文档 + 能失败的守卫

- [x] 5.1 新增 `Docs/user-guide/web-core-shim.md`：无头核心是什么、怎么启动（dart run + CWD 须含仓库根 DLL）、回显 URL 怎么用、"同一时刻只跑一个核心"约定与单实例守卫行为、回退方式、开发期 Vite proxy、已知限制（最小验证页非完整体验、本机回环无鉴权、发送路径仍全量载入历史属现状、存量缺陷 50 轮静默/摘要 xN/技能提示见 known-bugs）。README.md 加索引。
- [x] 5.2 新增文档守卫（`test/unit`）：**关键字符串取自代码常量/入口源码**（启动命令、端口回显格式、单实例提示文案、错误码），非手写副本——参照 parallel_tools_docs_test 解析常量的强先例，而非仅 contains 子串；核 README 索引存在。改文案不改文档就红。先红后绿贴证据。
- [x] 5.3 在 `TODO.md` 登记后继条目使语言收敛可追踪：① 完整聊天屏 change（含 F-002~F-004、虚拟滚动、分页落地）；② 核心 Dart→TS 迁移 change（终态 C+++TS）；③ 规模优化（restore/_history 内存边界）。RoadMap 阶段顺序同步。本任务只登记不实施。

## 6. 全量验证 + 变异 + validate（主循环批次）

- [x] 6.1 `scripts\sync_sidecar_dll.ps1` 后 `flutter analyze`（基线以本轮实测留档为准，改动文件零新增）+ `flutter test` 全量贴 `+N All tests passed!`；web 子项目构建无窗口通过。**冒烟接线**：run.bat / test/smoke/run_all.sh 新增 web 构建步（无窗口，起窗步仍按禁令跳过）。

**实测**：DLL already current；analyze `161 issues found` = 基线、改动文件零新增（Select-String 无命中）；干净全量 `+885 ~1 All tests passed! exit 0`（~1=live tag 跳过）；`npm --prefix web run build` 绿（188 modules，dist 产出）。冒烟接线已落：run.bat Step4 追加 `npm --prefix web ci`+`run build`+`:web_build_failed` 分支；test/smoke/01_build.sh 追加 web 构建段。
**期间处置（用户授权）**：sidecar_worker_test「并发与串行逐字节一致」稳定红（单独 3/3 红），根因 rg 默认并行跨文件序非确定（产品 grep_file 未加 --sort path，ripgrepDoc「并行性能断言—未验证」）。2026-11-18 用户拍板改测试②为「按 path+line 排序后比集合」（canonicalMatches），保留内容不串语义；改后 3/3 绿。未动产品代码。

- [x] 6.2 两个变异（各贴红证据后恢复、复跑全绿、改动文件哈希与变异前逐位相同）：① 把 JSON-RPC 非法输入的错误分支删掉（改为崩溃/无响应）→ 2.2 非法输入用例必须红；② 把 message.query 分页改成全量载入 → 3.2 "读路径不载入整条历史"的 SQL limit/repo 计数断言必须红。

**实测**：① json_rpc.dart parseError 分支改 return null → `非法 JSON → -32700` 用例红（Expected: not null, Actual: <null>）；恢复后哈希逐位 = 84EE8D45…190E27。② headless_core.dart message.query 改 queryBySession 全量+切片 → `读路径不调用全量` 用例红（fullLoadCount Expected:<1> Actual:<4>）；恢复后哈希逐位 = 975777E0…C5A2BF。恢复后 RPC 20 例全绿、干净全量 +885 ~1 全绿。

- [x] 6.3 `openspec validate web-ui-core-shim` 通过贴输出。

**实测**：`Change 'web-ui-core-shim' is valid`