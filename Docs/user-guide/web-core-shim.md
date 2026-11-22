# 无头核心与 web 客户端（完整聊天屏）

> 对应 change：`web-ui-core-shim`（基石）+ `web-chat-screen`（把验证页扩成完整聊天屏：
> 卡片折叠、贴底跟随、跳底按钮、会话虚拟滚动、消息分页、WS 自动重连与心跳）。
> 核心仍是"无头 Dart 进程 + C++ sidecar"，浏览器只是它的前端。

## 这是什么

- **无头 Dart 核心**：复用现有 `lib/services` 业务层与 `dart:ffi` 加载的 C++ `sidecar.dll`，
  不依赖 Flutter 渲染，独立进程运行。
- 同一个回环 HTTP 服务上：
  - `/`：serve `web/` 的构建产物（**完整聊天屏**）；
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

## 打开聊天屏

1. 用浏览器打开启动输出里的 `http://127.0.0.1:<port>`。
2. 页面左上角显示「已连接」后，左侧会话列表里选择会话（**会话来自与 Flutter 共用的数据库**）。
3. 在底部输入一句话，按 `Enter`（或点「发送」）。页面会显示：
   - 你发的消息；
   - 流式回复（Markdown 渲染）；
   - 工具卡片（**每个工具一张**，默认折叠成单行；点一下展开看完整输入/结果）；
   - 思考卡片（默认折叠成单行，展开看全文）；
   - 上下文窗口、token 计量；整轮失败/技能未生效会有明确提示条。
4. 当前版本**没有新建会话入口**：数据库里没有任何会话时页面会提示先用 Flutter 应用建一个。

## 完整聊天屏怎么用

- **工具/思考卡片折叠**：默认折叠，折叠态严格只占一行（工具名 + 状态 + 输入摘要；
  多工具消息就是多张单行卡）。点卡片展开完整输入与结果（结果区域可滚），折叠不等于丢弃。
- **空气泡已修**：工具轮里「正文为空、只有工具调用」的助手消息不再渲染成空气泡，
  它的每个工具调用各自占一张折叠卡；最终文字回复单独成气泡。
- **贴底跟随**：列表在底部时，新消息/流式增量/工具卡到达会自动滚到底；
  自己上翻阅读历史时不打扰（不会把你拽回底部）。
- **跳底按钮**：非贴底时，输入框上方右侧出现圆形 `chevron-down` 按钮；点它滚到底并恢复
  贴底跟随；回到底部后按钮自动隐藏。首版不做未读标记（deliberate 简化）。
- **会话列表虚拟滚动**：几百~几千个会话只渲染可视区，滚动不卡。
- **消息分页**：打开会话**直接停在最新一页**（锚定最新，不是从最旧开始）；上翻到顶会
  自动加载更早一页并**保持在原阅读位置**（不会跳）。页大小由界面给定（`30` 条/页）。
- **自动重连 + 心跳**：WebSocket 断开后按指数退避自动重连（顶部显示「重连中…」）；
  空闲时周期性 ping 核心，超时未回判死并重连。重连成功后重拉当前页消息，断线期间
  核心的后续事件仍会广播到新连接（核心没有"重新订阅"接口）。
- **流式语义**：每条助手消息（含工具轮中间消息）落定自己那一轮的文本；「正在生成」
  指示以 `agent.streaming` 事件为准，工具执行期间不会闪断。

## 完整聊天屏参数

以下参数在构建期（Vite 环境变量）覆盖，默认值即代码里的常量
（`web/src/tokens.ts`，由 `test/unit/web_chat_docs_test.dart` 与本表绑定，改代码不改文档会红）。
取值一律是**正数**（毫秒 / 像素）；配错（非正数）时回退默认值并在浏览器控制台告警。

| 环境变量 | 默认值 | 单位 | 说明 |
|---|---|---|---|
| `VITE_BOTTOM_THRESHOLD_PX` | 24 | px | 贴底判定阈值；默认 = 正文行高 16×1.5，也是间距 scale 的 24 步长 |
| `VITE_RECONNECT_BASE_MS` | 1000 | ms | 重连退避基数（产品先例：kimi_search 的 429 重试 1s 起步） |
| `VITE_RECONNECT_CAP_MS` | 30000 | ms | 重连退避上限；小于基数时抬到基数并告警 |
| `VITE_HEARTBEAT_PERIOD_MS` | 15000 | ms | 心跳发送周期（每周期发一次 `core.ping`） |
| `VITE_HEARTBEAT_TIMEOUT_MS` | 5000 | ms | 心跳等待回应上限，超时判死并触发重连 |

用法示例（PowerShell，构建前设置）：

```powershell
cd web
$env:VITE_HEARTBEAT_PERIOD_MS = "10000"
npm run build
```

## 同一时刻只跑一个核心

无头核心启动时会在 `~/.aliasagent/core.lock` 上取**排他锁文件**。已有一个核心在运行时，
第二个进程会直接失败退出并打印：

```text
已有核心在运行：单实例锁已被占用，本次启动已退出。请先关闭那个无头核心进程，再重新启动。
```

失败发生在打开数据库、创建 sidecar context 之前，不会触碰 DB / spill 目录。

为什么必须是机器守卫而不是只写约定：双开的后果包含数据破坏——dispose_context 会删除
另一进程正在使用的 spill 目录，SQLite 又没有跨进程锁，不止「双写」。Flutter 侧本 change
未加同样的锁，所以**请勿同时运行两个无头核心**；Flutter 应用与一个无头核心同时运行属于
本 change 的灰度共存形态。

## 回退

不启动无头核心即可回到纯 Flutter：不用迁移数据、不用改配置、sidecar 与数据库都是同一份。
浏览器页面只是核心进程的前端，关掉核心进程它就失效——没有任何后台常驻组件。
web 客户端本身是独立子项目，回退到最少形态就是恢复 `web/src/App.tsx` 的上一版（git）。

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
| `message.query` | `{sessionId, pageSize, anchor?, cursor?, before?}` | `{sessionId,pageSize,messages,nextCursor,prevCursor}`。`pageSize` **请求方必填且为正整数**，缺参/非法返回 `-32602`；核心不提供默认页大小，也不发明上限。`anchor`：`tail`（缺省，取**最新一页**）或 `head`（从最旧开始）；`cursor` = 上一页的 `nextCursor`（前向，seq 升序）；`before` = 上一页的 `prevCursor`（反向，取更早一页）；`cursor` 与 `before` 不能同时出现。`prevCursor` 是本页首条 seq（没有更早页时为 null）。 |
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
- `agent.streaming`、`turn.completed`、`turn.failed`（整轮失败时带可归因 error）。
  **注意**：`turn.completed` 是"本次模型请求结束"（工具轮后面还会再发），
  判"整轮还在生成"要用 `agent.streaming`，不要用 `turn.completed`。
- `context.snapshot`（含窗口、占用拆分 breakdown、**逐条技能失败明细** `skillFailures`）
- `compaction.status`、`session.title`、`agent.metering`

## 测试

```powershell
# 核心侧：通道 / 组合根 / 分页（含尾锚与反向游标）/ 静态服务（假 sidecar + 临时数据库）
flutter test test/integration/web_core_rpc_test.dart

# 文档守卫（参数表与 web/src/tokens.ts 绑定、RPC 表、feedback 状态）
flutter test test/unit/web_chat_docs_test.dart

# web 客户端：纯逻辑 vitest + 布局/滚动 puppeteer 真实渲染
cd web
npm run test:all

# 真实模型 + 无头 Edge 的端到端（无窗口；截图在 test/live_visual/web_core_shim_live.png）
flutter test --tags live --run-skipped test/live/web_core_shim_live_test.dart
```

`integration_test/web_core_shim_live_test.dart` 是规范的 live 入口；但 `flutter test` 会把
`integration_test/` 下的文件一律当设备测试（要求 `-d` 并会起应用窗口），所以本机无窗口
跑法用 `test/live/` 下的镜像入口跑同一个 suite（测试本体只有一份）。

`npm run test:all` = `vitest run`（纯逻辑：渲染归一/去重、流式语义、分页请求形状、
重连状态机、tokens 一致性）→ `vite build --config vite.harness.config.ts`（测试 harness）
→ `node e2e/layout.mjs`（puppeteer + 本机 headless Edge：折叠单行 24px、贴底跟随、
上翻不打扰、跳底三态、会话/消息虚拟化、上翻加载位置不跳）。

## 已知限制

- **未读标记首版不做**：跳底按钮不显示未读数（deliberate 简化，待拍板可加）。
- **断线期间的事件没有重放缓冲**：重连只重拉当前页消息；断线瞬间正在流式的事件不补发
  （核心无事件重放/订阅游标）。已落库的消息会补上。
- **本机回环、无鉴权**：只绑 `127.0.0.1`，本机信任边界内可接受；不要把它暴露到网络。
- **页面不能新建会话**：要在 Flutter 应用里先建一个（同库可见）。
- **发送路径仍全量载入历史**：`Agent.restore` 现有行为不变；分页只落在
  `message.query` 读路径（SQL 层 `limit`），「核心进程内存只留活跃投影」是后续规模优化
  的目标，不是本 change 的承诺。
- **粘贴网址缺陷（F-001）不在本入口**：那是 Flutter 输入框的问题，web 客户端不受影响，
  Flutter 侧另立项。
- **存量缺陷随入口继承**（本 change 不修）：50 轮工具上限触发时静默、摘要标记 `xN` 从不
  替换真实条数、L2 容量丢弃无日志；已确认缺陷见 `Docs/known-bugs.md`。本入口至少不更盲：
  技能失败明细随快照逐条推送，整轮 failed 会推 `turn.failed`。
- **sidecar 依赖 CWD**：裸名字加载，必须在仓库根启动（或把 DLL 放到加载路径）。
- **Flutter 侧未取同一把锁**：双开由「只启动一个核心」的约定约束，见上文。
