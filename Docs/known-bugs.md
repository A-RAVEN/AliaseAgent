# Known Bugs

## model_gateway: SSE dispatch overwrites HTTP error on_done code

**来源**: `add-cpp-sidecar-tests` proposal（已归档）
**发现日期**: 2026-07-19
**相关文件**: `sidecar/src/model_gateway.cpp`, `sidecar/test/http_client_test.cpp`

### 症状

`http_client_test.cpp:274` 测试失败：
```
HTTP: 400 error body captured and logged
  REQUIRE( s_done_code == -1 )
  with expansion: 0 == -1
```

### 根因

`model_gateway.cpp` 在 HTTP 状态码检查之前先 dispatch SSE 事件：

```
curl_easy_perform() 完成
  ↓
dispatch_events()  ← SSE body 里有合法事件 → 触发 on_done(0, ...), done_dispatched = true
  ↓
http_code >= 400?  ← 检测到 400，想调 on_done(-1, ...)，但 done_dispatched 已经是 true，被跳过
```

HTTP 400 响应的 body 如果包含合法的 Anthropic SSE 事件（如测试用的 `text_delta.txt` fixture），`dispatch_events` 会先解析到 `message_stop` 事件并调用 `on_done(0, ...)`（成功码），后续 HTTP 错误处理想调 `on_done(-1, ...)` 时被 `done_dispatched` 标记阻止。

### 修复思路

将 HTTP 状态码检查移到 `dispatch_events` 之前。HTTP >= 400 时应直接报错，不解析 SSE body。

---

## debug-infra: task 6.7 未完成但标记为 done

**来源**: `debug-infra` proposal（已归档）
**发现日期**: 2026-07-19
**相关文件**: `sidecar/test/ffi_tracing_test.cpp`

### 症状

tasks.md 中 6.7 标记 `[x]`（已完成），描述为"写入 300 事件 → 验证环形缓冲区回绕 + dump 输出格式"。实际代码只有 3 个基本 ring buffer 测试，未覆盖回绕和 dump 格式验证。

### 修复

`ffi_tracing_test.cpp` 补写回绕和 dump 格式测试。环形缓冲区大小 256，写入 300 事件后可验证回绕行为。

---

## add-widget-interaction-tests: ChatScreen 场景不足

**来源**: `add-widget-interaction-tests` proposal（已归档）
**发现日期**: 2026-07-19
**相关文件**: `test/widget/chat_screen_test.dart`

### 症状

checkpoint C 要求 ChatScreen 至少 3 个测试场景，实际只写了 2 个（DI 注入 + 构造函数默认值）。

### 修复

`chat_screen_test.dart` 补至少 1 个场景。---

## sidecar_api: ensure_search_infra 无限递归

**来源**: `add-web-search` proposal
**发现日期**: 2026-07-19
**已修复**: 是 (2026-07-20 永久修复)
**相关文件**: `sidecar/src/sidecar_api.cpp:123`

### 根因

C API 包装函数 `ensure_search_infra` 和 C++ 实现函数 `ensure_search_infra` 都在全局命名空间。`::ensure_search_infra(const char*)` 被编译器解析为 C API 自身而非 C++ 实现 `ensure_search_infra(const std::string&)`。栈溢出 → ACCESS_VIOLATION。

同一 bug 也影响了 `web_fetch`（sidecar_api.cpp:174），但直到 2026-07-20 AI 首次调用 web_fetch tool 才触发。

### 修复

- **临时** (2026-07-19): `::ensure_search_infra(std::string(...))` 强制重载选择。
- **永久** (2026-07-20): C++ 实现函数重命名为 `ensure_search_infra_impl` 和 `web_fetch_impl`，彻底消除命名冲突。

---

## subprocess: 起进程失败时只回一个不说明原因的空结果

**来源**: `add-command-tool`（活跃 change，任务 1.7 记下的既有问题）
**发现日期**: 2026-10-04
**相关文件**: `sidecar/src/subprocess.cpp`（`start_process_wide` 与它的 Windows 调用点）

### 症状

`subprocess::run` 起不来子进程时，`Result` 里只有 `started=false`、`exit_code=-1`，**既没有 `GetLastError()` 也没有任何文字说明**。调用方无法区分"可执行文件不存在"、"工作目录不存在/名字非法"、"命令行太长"这几种完全不同的原因。

实测现场（2026-10-04，把 `cwd` 指到一个已存在的中文目录、但用错了字符串形态时）：返回 `started=0 exit=-1`，而真实原因是 `GetLastError=267`（`ERROR_DIRECTORY`，目录名无效）——这个数字只有单独插桩才看得到，工具返回给模型的那一层什么也看不到。

### 修复思路

`Options` 增一个"失败原因"出口（或让 `run` 在 `started=false` 时把 `GetLastError()` 与格式化后的文字放进 `stderr_data`/新字段），让上层能把它拼进给模型的说明里。改它会把变更的验收范围扩成"执行器的错误报告"，所以 `add-command-tool` 只记账不修。

---

## sidecar_test: TempDir 清理在含非 ASCII 名的目录上失效

**来源**: `add-command-tool`（活跃 change，任务 1.7 记下的既有问题）
**发现日期**: 2026-10-04
**相关文件**: `sidecar/test/temp_dir.h`（`TempDir` 的析构与 `remove_all`）

### 症状

`TempDir` 析构时用 **ANSI 版**的 `FindFirstFileA` 遍历自己的目录。当目录里存在名字含非 ASCII 字符的子目录（例如用例里建的 `中文目录`）时，遍历失败 → 走兜底 `rmdir` → **非空目录删不掉，静默失败**，于是系统临时目录里会留下一个 `st_XXXX.tmp` 空壳。

复现：跑一次含"在临时目录下建中文子目录"用例的 `sidecar_tests.exe`，然后数 `%TEMP%\st_*.tmp` 的个数；实测一次会话能留下 10 个。

### 修复思路

`remove_all` 改走宽字符接口（`FindFirstFileW` / `DeleteFileW` / `RemoveDirectoryW`），其余逻辑不变。同类的 ANSI 接口在本仓库还有几处（`browser.cpp` 的 `start_worker` 自起进程），一并由"宽字符改造"这个方向处理，但都不在 `add-command-tool` 的范围内。

---

## agent-config: `tools` 白名单被解析但从未用于过滤工具定义

**来源**: `add-command-tool`（活跃 change，任务 8.5 记下的既有问题）
**发现日期**: 2026-10-04
**相关文件**: `lib/models/agent_type_config.dart`（字段与序列化）、`lib/main.dart`（`_toolDefs` 的组装）

### 症状

配置里 `agent_types.<名字>.tools` 这个列表**看起来**是"这个 Agent 能用哪些工具"的白名单，写它却**不产生任何效果**：模型仍然能看到全部工具（`read_file`、`write_file`、`edit_file`、`list_dir`、`get_current_time`、`glob_file`、`grep_file`、`run_command`，以及条件注册的 `web_search` / `web_fetch` / 四个 `browser_*`）。

核实方式：全 `lib/` 范围内搜 `\.tools\b`，只命中 `AgentTypeConfig` 自己的字段声明与 `toJson`/`fromJson` —— **没有任何一处读它来过滤 `_toolDefs`**。第一次启动写出的配置里默认写着 `"tools": ["read_file", "list_dir"]`，这个默认值同样不生效。

### 修复思路

在 `_initSearchAndTools` 组装完 `_toolDefs` 之后，按当前 Agent 的 `tools` 列表做一次过滤（空列表是"全给"还是"什么都不给"要当场定死并写进规范）。这是一处独立的行为改动（会改变模型看到的工具集合，也会影响 `test/unit/user_docs_test.dart` 的"注册的工具都在文档里"那条检查），所以不在 `add-command-tool` 里顺手改。

## sidecar_test: `Rate guard` 用例依赖真实网络，离线必红

**来源**: `add-image-input` 第二轮编译验证（tasks 17.2）
**发现日期**: 2026-10-24
**相关文件**: `sidecar/test/search_provider_test.cpp`（用例 `Rate guard: rapid-fire 5 consecutive ZhipuAI searches`）

### 症状

跑 `sidecar/build/windows/Debug/sidecar_tests.exe`（或 `ctest --test-dir sidecar/build/windows -C Debug`）时整包失败：

```
[rate-guard live] 0/5 succeeded, 5 errors, 11176ms total
ZhipuAI: connection error — Could not connect to server
search_provider_test.cpp(1956): FAILED:
  REQUIRE( success_count == N )
with expansion:  0 == 5
test cases: 343 | 342 passed | 1 failed
```

`ctest` 把整包当一个 test 跑、默认不带失败明细，所以外部只看到 `exit=8`；要看是哪条必须直接跑 `sidecar_tests.exe`。

### 根因

这条用例要连真实的 ZhipuAI 搜索接口。无外网（或该服务不可达）时 5 次全失败 ⇒ 断言必红。与代码好坏无关，是"联网用例没有离线开关"的设计问题。

### 现状与规避

第二轮验证的判据写成"失败数不得超过基线（也是这 1 条）"，所以没有卡住。要它变绿得让它能按环境变量或 Catch2 tag 排除 `[live]`，属于独立改动，尚未立项。

## widget_test: `browser_worker_test` 偶发 `worker response timeout`

**来源**: `add-image-input` 第二轮编译验证（tasks 17.5）
**发现日期**: 2026-10-24
**相关文件**: `test/integration/browser_worker_test.dart`（失败点约在 396 行的 `expect(r0['ok'], isTrue)`）、sidecar 的浏览器 worker

### 症状

全量 `flutter test` 偶发 1 红：

```
[OBS] navigate -> {"ok":false,"error":"worker response timeout"}
test\integration\browser_worker_test.dart 396:7
  Expected: true
    Actual: <false>
```

### 已核实的性质

- 该文件里 `MessageBubble` / `ChatScreen` / `pumpWidget` 命中 **0** 处，与聊天界面无关；
- **同一份代码**重复跑：第一次 `+17 -1`，第二次 `+18 All tests passed!`；
- 把当时正在改的 `lib/ui/message_bubble.dart` 临时 stash 掉跑同一用例，也是全绿。

⇒ 判断为真实浏览器子进程的响应超时抖动，不是某次改动的回归。

### 修复思路

把 worker 的等待上限做成可配置项，或在该用例里放宽等待并写明依据；数字来源必须指出现有常量在哪个文件，不许再凭空发明一个毫秒数。

## sidecar: `web_search` 被进程级互斥锁整体串行，同一轮多个搜索没有时间收益

**来源**: `parallelize-readonly-tool-calls`（任务 1.3，本 change 只披露不改锁）
**发现日期**: 2026-11-04
**相关文件**: `sidecar/src/search_provider.cpp`（`dispatch_web_search` 里的 `static std::mutex g_dispatch_mutex`）

### 症状

`dispatch_web_search` 一进函数就取进程级互斥锁，函数体全程持锁。因此即便 Agent 把同一轮里的多个 `web_search` 并发启动，它们在 sidecar 内部仍会一个接一个执行：并行化对 `web_search` 不产生时间收益（`web_fetch` 与其余只读工具不受影响，收益照常兑现）。

### 根因

函数里的注释原文（`dispatch_web_search` 开头）：

> 进程级互斥（change add-context-handles 任务 1.7）：provider 实例、凭据、限流计数与探测结果都是应用级共享状态，两个上下文同时搜索会并发改写它们。串行执行，每次的请求与结果各自封装，不会有半个结果混进来。

即：provider 实例、凭据、限流计数与探测结果都挂在进程级静态量上，没有按上下文隔离，只能靠一把全局锁串起来。

### 期望方向

把 provider 实例、凭据与限流状态下沉到上下文（与 `add-context-handles` 对工作区/文件版本表/spill 序号做过的处理同形），之后 `dispatch_web_search` 才能按上下文并发。

### 重新考虑时机

另立 change 时。`sidecar/test/context_ownership_test.cpp` 的既有用例（"两个上下文并发 web_search 时假 provider 一次只看到一个在跑"）把当前串行钉成了受保护行为，改锁必须同时改那条用例并说明依据；本 change 不动它，只在用户文档如实披露。

---

## 窗口版 live 用例在发消息前调 `setCurrentWorkspace`，自上下文句柄化起必报 `no current session`

### 症状

2026-11-04 `parallelize-readonly-tool-calls` 的 live 用例（`integration_test/tool_parallelism_live_test.dart`）首跑 3 秒即失败：`Expected: null / Actual: 'no current session'`（断言消息"setWorkspace(仓库根) 必须成功"）。既有窗口版 live 用例（`browser_live_test.dart`、`live_file_tools_test.dart` 四处、`live_image_read_tool_test.dart`、`live_image_capability_gate_test.dart`）用的是同一调用形态（`pumpWidget` 后立刻 `chatState.setCurrentWorkspace(...)`），自句柄化后无一实际跑过，预计同样会挂。

### 根因

`setCurrentWorkspace` 自提交 `778b933`（2026-11-01，feat: 为工具与模型请求引入独立上下文句柄）起带守卫：`_currentId == null` 时直接返回 `'no current session'`（工作区归上下文所有，必须先有会话句柄）。而启动路径 `_loadSessions` 只在"库里已有会话"时才设 `_currentId`；live 用例的 `setUp` 用 `DatabaseService.openAt(tempDir)` 开**空库**，空库下真正的建会话兜底挂在发消息路径（`_sendMessage` 开头 `_currentId == null → _newChat()`）——所以真实产品首次发消息不受影响，纯用例时序踩坑：它们都必须在**发消息之前**设工作区。

### 期望方向

已受影响用例统一补一步"点界面上真实的 New Chat 按钮建会话再 setWorkspace"（`tool_parallelism_live_test.dart` 已按此修复并实测）；更彻底的做法是给 `integration_test` 加共享的启动助手（确保当前会话），由后续 change 统一处理各用例的重复样板。

### 重新考虑时机

下一个动 `integration_test` 窗口版用例的 change 顺手收敛；或任一上述用例下次真跑到 `no current session` 时即为本条复现。

## load_skill / read_file：附属文件的非 ASCII 文件名在 C++ 窄字符路径 API 下可能取不到

**来源**: `add-skill-mechanism`（任务 10.1 登记；design Risks 项如实落账）
**发现日期**: 2026-11-07
**相关文件**: `sidecar/src/skill_tool.cpp`、`sidecar/src/tools.cpp`（既有同源面）

### 症状

技能附属文件（`load_skill(file=…)`）的名字若含非 ASCII 字符（如中文），C++ 侧可能报"文件不存在"类可见错误而取不到内容；不是静默返回空，模型与用户能看到原因。

### 根因方向

与本仓库 `read_file` 的现状同源、非本 change 新增缺陷：C++ 文件路径走窄字符 API（`GetFullPathNameA`/A 系函数），非 ASCII 路径的解析依赖 ANSI 码页，UTF-8 字节在部分系统码页下解析不到真实文件。技能目录名本身受规范约束（`name` 仅小写字母/数字/连字符）不受影响，受影响的只有附属文件与正文文件名。

### 证据

`sidecar/test/skill_tool_test.cpp`（tag `[skills]`，2026-11-07 实测 97 assertions/15 cases 全绿）的夹具文件名全部 ASCII；没有任何用例证明中文附属文件名能取回。

### 重新考虑时机

出现统一把 sidecar 文件 API 改宽字符（`GetFullPathNameW`/`_wfopen`）的 change 时一并修复并补非 ASCII 用例；在那之前 `Docs/user-guide/skills.md` 的已知限制节已如实写明"附属文件的名字目前建议只用 ASCII"。

## sidecar_worker 集成测试：并发 grep_file 与串行结果"逐字节一致"断言是顺序竞态

**来源**: `refresh-skill-catalog-each-turn` apply 阶段全量测试暴露（2026-11-08，两次全量 + 多次单跑复现）
**发现日期**: 2026-11-08
**相关文件**: `test/integration/sidecar_worker_test.dart`（「同一上下文并发 3 个 grep_file」用例的断言②）、`sidecar/src/tools.cpp`（`grep_file` 的 rg argv 无 `--sort`）

### 症状

`flutter test` 全量偶发 −1：并发版与串行版 `grep_file` 的 JSON 结果"逐字节一致"断言失败，但两者的命中集完全相同，只差**文件块的先后顺序**——且每次失败时交换的位置都不一样（有时 `tool_catalog`/`tool_group_planner` 互换，有时 `agent.dart`/`setup_dialog` 互换）。单跑同一用例有时绿有时红（2026-11-08 实测：1 次绿、其后 9 次全红）。

### 根因

`grep_file` 透传 ripgrep 的多线程 walker 输出顺序，argv 里没有 `--sort`。直接对 `lib/` 连跑 5 次 `tools\rg.exe --json -n --no-require-git -e kBaseToolNames lib`，5 次文件顺序全不同（实测留档）。用例把两次**相互独立**的 rg 调用结果做逐字节相等比较，等于在赌两个随机顺序恰好一致——是测试自身的过强断言，不是产品行为错误（命中内容、计数都正确），也与触发它的 change 无关（本 change 的 diff 不含任何 C++/grep/worker 代码；错序位置逐次不同亦证明非确定性而非回归）。此前多个 change 全量绿只是竞态未发作。

### 期望方向

二选一，需独立 change（本 change tasks 无此任务，按"代码必须对应 tasks.md"未顺手改）：① 产品侧给 `grep_file` 的 rg argv 加 `--sort path`，输出顺序确定后并发/串行自然逐字节一致（用户可见的 grep 结果顺序从"随机"变"按路径排序"，属行为变化，需 spec 同步）；② 测试侧改为无序比较（同一路径+行号集合相等即可），"结果不串"的本意（三次并发请求的结果互不混淆）不受影响。

### 重新考虑时机

下一个动 sidecar 工具或该测试文件的 change 顺手收敛；或全量测试再因此条 −1 时即为本条复现。

> **2026-11-18 更新**：web-ui-core-shim §6 期间此条稳定复现（单跑 3/3 红），用户拍板取方向②——测试②改为 `canonicalMatches`（按 path+line 排序后比集合），保留"结果不串"本意，未动产品代码。改后 3/3 绿。方向①（产品加 --sort path）仍未做。

## web 验证页：工具轮助手消息渲染成空气泡，真回复被淹没

**来源**: 用户实测反馈（2026-11-21，web-ui-core-shim 最小验证页）
**发现日期**: 2026-11-21
**相关文件**: `web/src/App.tsx`（`assistant.message` 事件处理 + `messages.map` 渲染）、`lib/core/event_serialization.dart`（`serializeMessage`）

### 症状

web 验证页里"很多 agent 回复直接不显示"，并出现大量空的 ASSISTANT 气泡。

### 根因

实测（WS 探针查运行中核心）：会话「你是谁」62 条助手消息中 56 条正文为空（只带 tool_calls 的工具轮）、仅 6 条有正文；回复文本核心都发了、库里也存着（如有 contentLen=2847 的新闻简报）。最小页把**每条持久化助手消息都渲染成气泡**（`messages.map` 不区分空正文），56 个工具轮空气泡把 6 条真回复淹没。两个具体缺陷：① 空正文工具轮消息渲染成独立空气泡；② 助手消息上的 `toolCalls`/`thinking` 未被渲染（只渲染 `content`），工具活动仅靠独立 `tool.call` 卡片。且 live 与 history 不一致：live 的 `assistant.message` 处理有 `content.length>0` 守卫会丢弃空正文消息，history 加载却全渲染成空气泡。

### 期望方向

属 F-002（工具/思考卡片默认折叠单行）那一层，完整聊天屏 change 解决：空正文工具轮消息不渲染成独立空气泡，其 toolCalls/thinking 折叠成工具卡；助手消息的 toolCalls 内联渲染；live 与 history 处理一致。

### 重新考虑时机

完整聊天屏 change（TODO.md 已登记）；或用户要求先给最小页打补丁时。

