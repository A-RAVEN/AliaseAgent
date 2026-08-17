## Why

add-file-tools 引入的 `grep_file` / `glob_file` / 批量 `edit_file`（edits 数组）缺少**符合项目规范的窗口版 live 测试**。返工前的缺口与初版状态如下：

1. **"假 live" 已被初版关闭，但保护的是非规范形态** — 初版 headless 实施已为 `test/integration/live_file_tools_test.dart` 加 `@Tags(['live'])` + 根目录 `dart_test.yaml`（默认跳过、显式命令触发，隔离语义经本地 SDK 源码验证 + 端到端实测）。但这些隔离保护的是 **headless 套件（非规范形态）**，而非窗口版规范套件。
2. **拒绝路径窗口版无 live 覆盖** — `edit_file` 的多匹配无 `replace_all` 拒绝（模型自然会产生：old_text 匹配多处）在 headless 里**从未被真实模型触发**（6 次运行均 `rejections: 0`，属 finding 19/9 认可的概率性边界），窗口版同样无证据；模型能否读懂拒绝原因并自愈，无 live 证据。（空 old_text / 重叠 edits 不是正常模型会自然产生的输入，**经用户明确授权**，live 覆盖仅限多匹配无 replace_all 这一自然路径，其余维持 C++/mock/真实 sidecar 覆盖。）
3. **批量 edits 数组窗口版未验证** — headless 已实测批量（run2/run6 `edits_len=3 ok=true replacements=3`），但窗口版形态未验证（`real_api_test.dart` 只覆盖 write_file / edit_file / web_fetch，未覆盖批量 edits 数组 / glob_file / grep_file）。
4. **live 测试形态不符合项目规范（返工核心）** — 初版把 live 套件实现为 `test/integration/` 的 **headless flutter_tester**（真实模型+真实 sidecar+真实 ripgrep，但**无窗口、无 UI 渲染**）。项目 live 测试规范形态是**窗口版 integration_test**（`integration_test/`：`IntegrationTestWidgetsFlutterBinding` + `pumpWidget(MyApp)`，在真实桌面窗口运行完整应用，**能看到真实 AI 在窗口里回答**，如既有 `integration_test/real_api_test.dart`）。用户明确判定：live 测试应能看见真实 AI 回答的窗口画面，headless 套件不符合规范，proposal 打回返工。

**初版实施历史（诚实记录）**：headless 套件完整实施 + 5 轮 Workflow 对抗审查（共确认 59 条 findings 全部修复）+ 6 次 live 运行（**run1/run3 曾失败并已修复，run2/4/5/6 全绿**，详见 tasks 3.2）。其技术结论（fixture 单文件契约、line/comment-token 断言原则、指令文本）继承到窗口版。

## What Changes

- **新建窗口版 live 套件 `integration_test/live_file_tools_test.dart`**（规范形态，仿 `real_api_test.dart`）：
  - `IntegrationTestWidgetsFlutterBinding` + **环境初始化**（`sqfliteFfiInit()` + `databaseFactory = databaseFactoryFfi` + `DatabaseService.openAt(tempDir)`——`main()` 不运行，这些必须在测试自设，否则 ChatScreen 加载卡死或打开真实用户 DB）+ `pumpWidget(const MyApp())`，真实桌面窗口（`-d windows`）渲染完整应用
  - **fixture 时序**（关键）：`pumpWidget` 时 `AppShell.initState` 会把 workspace 重置到 `ConfigService.homeDir`，故必须 **pump 后重新 `SidecarBridge.instance.setWorkspace(tempPath)`** 再发指令，模型只读/写 fixture，绝不触碰真实用户文件
  - 在聊天输入框输入指令驱动真实模型使用工具，等 `ToolCallCard` 出现并完成，断言 UI 状态（`activity.toolName`/`input`/`status`）+ 文件最终状态
  - 4 个场景：自然多工具（grep_file+edit_file）、批量 edits 数组（断言 `ToolCallActivity.input['edits'].length >= 2`）、唯一匹配拒绝/自愈（`ToolCallCard` `error` → AI 自愈 → `done` + 文件恰好改一处）、glob_file 专项
  - 门控：无 config / API 不可用时 `markTestSkipped`（无条件，与 `real_api_test.dart` 一致）
- **隔离机制按 integration_test 形态重新设计**：验证 `dart_test.yaml` 的 `tags` 隔离对 `flutter test integration_test/... -d windows` 是否生效；生效则加 `@Tags(['live'])` + 窗口版规范命令 `flutter test --tags live --run-skipped integration_test/live_file_tools_test.dart -d windows`，否则以 `markTestSkipped` 门控 + 显式命令记录（如实记录实际形态）；**同步更新 `dart_test.yaml` 的 skip 消息**（当前仍指向 headless 命令）。
- **既有 headless 套件 `test/integration/live_file_tools_test.dart` 不采用为 live 规范**（初版返工遗留：已实现但形态不符合规范）。**已按用户确认删除**（D6 选项 a，task 12.6）；其 fixture / 指令文本 / 断言原则继承到窗口版套件。
- **文档与 spec 同步**：`DEBUGGING.md` 更新为窗口版运行方法；delta spec 记入 `real-sidecar-tests`。

## Capabilities

### New Capabilities

（无）

### Modified Capabilities

- `real-sidecar-tests`: 增加"文件工具 live 测试"要求——live 测试 SHALL 为**窗口版 integration_test**（`IntegrationTestWidgetsFlutterBinding` + `pumpWidget(MyApp)`，真实桌面窗口可见 AI 回答），覆盖 `glob_file` / `grep_file` / 批量 `edit_file`（断言 `ToolCallActivity.input['edits']` 长度）/ 唯一匹配拒绝路径（`ToolCallCard` error → 自愈 → done）。headless flutter_tester 套件不视为 live 规范形态。

## Impact

- `integration_test/live_file_tools_test.dart` — 新建窗口版 4 场景 live 套件（含 sqflite/DatabaseService 初始化、pump 后 setWorkspace 时序）
- `integration_test/real_api_test.dart` — 只读参照（不修改）
- `test/integration/live_file_tools_test.dart` — **删除**（用户确认 D6 选项 a；初版返工遗留，形态不符合 live 规范）
- `dart_test.yaml` — 隔离配置按 integration_test 适用性验证后调整（含 skip 消息更新为窗口版命令）
- `DEBUGGING.md` — 更新为窗口版运行方法
- `openspec/specs/real-sidecar-tests/spec.md` — 同步 delta
- **不改任何生产代码**（`lib/`、`sidecar/` C++ 均不动）；不改 C++/Dart 既有测试的验收标准
- 注：`sidecar/src/tools.h:47` 存在既有文档漂移（edit_file 请求文档仍是旧单对 schema，实现已是 edits 数组）——**非本 change 引入**，本 change 不改 C++；如需修复需另行单独提交（用户未授权，本 change 不动）
- 依赖：真实 DeepSeek API key + base_url + model（`%USERPROFILE%\.aliasagent\config.json`）+ `tools/rg.exe` + 桌面设备（Windows）
