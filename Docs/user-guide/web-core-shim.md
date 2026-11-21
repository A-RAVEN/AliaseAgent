# 无头核心与 web 验证页

> 对应 change：`web-ui-core-shim`。这是 **web 化路线的第一块基石**，不是完整体验：
> 它证明「无头 Dart 核心 + WebSocket JSON-RPC + 浏览器页面」这条架构能端到端跑通。
> 完整聊天屏、卡片折叠、自动贴底、跳底按钮、虚拟滚动、核心迁 TS 都是后续 change。

## 这是什么

- **无头 Dart 核心**：复用现有 `lib/services` 业务层与 `dart:ffi` 加载的 C++ `sidecar.dll`，
  不依赖 Flutter 渲染，独立进程运行。
- 同一个回环 HTTP 服务上：
  - `/`：serve `web/` 的构建产物（最小聊天验证页）；
  - `/ws`：WebSocket + JSON-RPC 2.0 通道（发消息、流式事件、工具事件、会话/消息查询）；
  - 监听端口由 OS 分配（port 0），启动时回显实际 URL，不写死端口。
- 与 Flutter 应用**灰度共存**：同一份配置（`~/.aliasagent/config.json`）、同一个 SQLite
  数据库、同一个 sidecar。回退 = 不启动无头核心进程。

## 前置条件

1. 至少运行过一次 Flutter 应用，让 `~/.aliasagent/config.json` 有可用的 general 模板与
   provider（本入口不提供首启配置界面）。
2. **进程 CWD 必须是仓库根**：sidecar 以裸名字 `DynamicLibrary.open('sidecar.dll')` 加载，
   DLL 就在仓库根。CWD 不对会在启动时报「sidecar 加载失败 … CWD=…」。
3. web 构建产物存在：

   ```powershell
   cd web
   npm install
   npm run build
   ```

   （产物在 `web/dist/`，默认由核心 serve；也可用 `--web-root` 指到别处。）

## 启动

```powershell
cd <仓库根>
dart run bin/alias_agent_core.dart
```

启动输出回显两类地址：

```
AliasAgent 无头核心已启动
  URL:       http://127.0.0.1:<port>
  WebSocket: ws://127.0.0.1:<port>/ws
```

其中 `http://127.0.0.1:<port>` 的 `<port>` 是 **OS 实际分配**给这次进程的端口，不是配置值。

可选参数：

```text
--config <path>    指定配置文件（默认 ~/.aliasagent/config.json）
--lock <path>      指定单实例锁文件（默认 ~/.aliasagent/core.lock）
--web-root <path>  web 客户端构建产物目录（默认 <CWD>/web/dist）
-h, --help         显示帮助
```

## 打开验证页

1. 用浏览器打开启动输出里的 `http://127.0.0.1:<port>`。
2. 页面左上角显示「已连接」后，在左侧选择已有会话（**会话来自与 Flutter 共用的数据库**）。
3. 在底部输入一句话，按 `Enter`（或点「发送」）。页面会显示：
   - 你发的消息；
   - 流式回复（Markdown 渲染）；
   - 工具卡片（工具名、输入、状态、结果预览）；
   - 上下文窗口与占用拆分、token 计量。
4. 当前版本**没有新建会话入口**：数据库里没有任何会话时页面会提示先用 Flutter 应用建一个。
5. 页面只用于验证架构，没有卡片折叠 / 自动贴底 / 跳底按钮 / 会话管理。

## 同一时刻只跑一个核心

无头核心启动时会在 `~/.aliasagent/core.lock` 上取**排他锁文件**。已有一个核心在运行时，
第二个进程会直接失败退出并打印：

```text
已有核心在运行：单实例锁已被占用，本次启动已退出。请先关闭那个无头核心进程，再重新启动。
```

失败发生在打开数据库、创建 sidecar 上下文之前，不会触碰 DB / spill 目录。

为什么必须是机器守卫而不是只写约定：双开的后果包含数据破坏——dispose_context 会删除
另一进程正在使用的 spill 目录，SQLite 又没有跨进程锁，不止「双写」。Flutter 侧本 change
未加同样的锁，所以**请勿同时运行两个无头核心**；Flutter 应用与一个无头核心同时运行属于
本 change 的灰度共存形态。

## 回退

不启动无头核心即可回到纯 Flutter：不用迁移数据、不用改配置、sidecar 与数据库都是同一份。
浏览器页面只是核心进程的前端，关掉核心进程它就失效——没有任何后台常驻组件。

## 开发期（Vite）与生产的关系

- **生产**：核心 serve `web/dist`，页面与 WebSocket 同源（`/ws`），不需要额外进程。
- **开发**：要热更新时起 Vite：

  ```powershell
  cd web
  $env:VITE_CORE_ORIGIN = "http://127.0.0.1:<port>"   # 用核心启动时回显的实际 URL
  npm run dev
  ```

  Vite 把 `/ws` 代理到 `VITE_CORE_ORIGIN`；没有设置该环境变量时**不启用代理**，
  也不使用任何默认端口（端口是 OS 分配的，写死默认值就是魔数）。

## RPC 方法

所有方法走 `ws://127.0.0.1:<port>/ws`，请求/响应为 JSON-RPC 2.0。
错误码只用规范值：`-32700`（Parse error）、`-32600`（Invalid Request）、
`-32601`（Method not found）、`-32602`（Invalid params）、`-32603`（Internal error）；
非法输入返回错误响应而不是崩溃。

| 方法 | 参数 | 返回 |
|---|---|---|
| `core.ping` | 无 | `{ok, service, protocolVersion, pid}` |
| `session.list` | 无 | `{sessions: [{id,title,agentType,parentSessionId,createdAt,updatedAt}]}`（只含顶层会话，按最近更新倒序） |
| `message.query` | `{sessionId, pageSize, cursor?}` | `{sessionId,pageSize,messages,nextCursor}`。`pageSize` **请求方必填且为正整数**，缺参/非法返回 `-32602`；核心不提供默认页大小，也不发明上限。cursor 是上一页的 `nextCursor`（按 seq 升序分页）。 |
| `agent.send` | `{sessionId, text, attachments?}` | `{sessionId,status,finalText,error,metering}`；复用 `Agent.send` / `AgentFactory.ensure`。 |
| `agent.cancel` | `{sessionId}` | `{sessionId,cancelled,reason?}`。 |

## 事件（服务端 → 客户端 notification）

事件统一是 `agent.event` 通知，参数形状：

```json
{"sessionId": "…", "type": "assistant.chunk", "data": {"text": "…"}}
```

每个事件的 payload 都带 `sessionId` 与 `type`。事件类型与语义复用现有模型，不新造：

- `user.message` / `assistant.message`（`data.isFinal`）
- `assistant.chunk`
- `thinking.delta` / `thinking.block`
- `tool.call` / `tool.result`（`ToolCallActivity.toJson()`：工具名、输入、状态、结果）
- `agent.streaming`、`turn.completed`、`turn.failed`（整轮失败时带可归因 error）
- `context.snapshot`（含窗口、占用拆分 breakdown、**逐条技能失败明细** `skillFailures`）
- `compaction.status`、`session.title`、`agent.metering`

## 测试

```powershell
# 通道 / 组合根 / 分页 / 静态服务（假 sidecar + 临时数据库）
flutter test test/integration/web_core_rpc_test.dart

# 真实模型 + 无头 Edge 的端到端（无窗口；截图在 test/live_visual/web_core_shim_live.png）
flutter test --tags live --run-skipped test/live/web_core_shim_live_test.dart
```

`integration_test/web_core_shim_live_test.dart` 是规范的 live 入口；但 `flutter test` 会把
`integration_test/` 下的文件一律当设备测试（要求 `-d` 并会起应用窗口），所以本机无窗口
跑法用 `test/live/` 下的镜像入口跑同一个 suite（测试本体只有一份）。

## 已知限制

- **最小验证页不是完整体验**：没有卡片折叠、自动贴底、跳底按钮、会话管理、虚拟滚动；
  完整聊天屏是后续 change。
- **本机回环、无鉴权**：只绑 `127.0.0.1`，本机信任边界内可接受；不要把它暴露到网络。
- **页面不能新建会话**：要在 Flutter 应用里先建一个（同库可见）。
- **发送路径仍全量载入历史**：`Agent.restore` 现有行为不变；本 change 的分页只落在
  `message.query` 读路径（SQL 层 `limit`），「核心进程内存只留活跃投影」是后续规模优化
  的目标，不是本 change 的承诺。
- **存量缺陷随入口继承**（本 change 不修）：50 轮工具上限触发时静默、摘要标记 `xN` 从不
  替换真实条数、L2 容量丢弃无日志；已确认缺陷见 `Docs/known-bugs.md`。本入口至少不更盲：
  技能失败明细随快照逐条推送，整轮 failed 会推 `turn.failed`。
- **sidecar 依赖 CWD**：裸名字加载，必须在仓库根启动（或把 DLL 放到加载路径）。
- **Flutter 侧未取同一把锁**：双开由「只启动一个核心」的约定约束，见上文。
