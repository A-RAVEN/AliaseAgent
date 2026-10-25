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

