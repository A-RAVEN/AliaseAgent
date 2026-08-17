## Context

add-file-tools 已交付：`grep_file` / `glob_file`（ripgrep 子进程）+ 批量 `edit_file`（edits 数组）。测试分层现状：

| 层 | 覆盖 | 状态 |
| --- | --- | --- |
| C++ 单测（sidecar/test/*.cpp） | 全部功能 + 边界 + rg 实测 | 228 用例（227 通过 + 1 `[zhipuai][live][rate-guard]` 环境性失败） |
| Dart mock/unit（fake_sidecar） | 符号、dispatch、schema | 153 全绿 |
| **窗口版 live（integration_test）** | `real_api_test.dart` | 覆盖 web_fetch / write_file / edit_file，**未覆盖 glob_file / grep_file / 批量 edits** |

**项目 live 测试的两种形态（用户明确判定规范）：**

```
形态 1：headless live（test/integration/）—— 不视为 live 规范
  跑法: flutter test（flutter_tester，无窗口）
  特点: 直接调 SidecarBridge + 真实模型 + 真实 rg；无 UI 渲染

形态 2：窗口版 live（integration_test/）—— 项目规范形态
  跑法: flutter test integration_test/... -d windows（真实桌面窗口）
  特点: IntegrationTestWidgetsFlutterBinding + pumpWidget(MyApp)，
        完整应用 UI 渲染，能看到真实 AI 在窗口里回答
        （消息气泡 / thinking card / tool call card）
```

**返工背景（诚实记录）**：本 change 初版把 live 套件实现为形态 1（`test/integration/live_file_tools_test.dart`，headless），完整走完实施 + 5 轮 Workflow 诚实性审查（共确认 59 条 findings 全部修复）+ 6 次 live 运行（**run1/run3 曾失败并已修复，run2/4/5/6 全绿**——详见 tasks 3.2 运行清单）。但用户判定：**live 测试应能看见真实 AI 回答的窗口画面，形态 1 不符合规范**，proposal 打回返工。本 design 据此重写为形态 2（窗口版 integration_test）；初版 headless 套件的代码**保持不动**，去留作为待确认决策点（见 D6）。

**审查历史**：初版方案经 5 轮 Workflow 对抗审查（22 提案 + 9 首轮 + 7 二轮 + 12 三轮 + 9 收尾 = 59 条 findings），其技术结论仍有效并继承到本设计：
- Test 2 批量 fixture 必须按 edit_file 单文件契约（单 `path` + edits 数组）设计
- gap-2 经用户授权仅 live 覆盖自然路径（多匹配无 replace_all）
- 断言原则：不做全局子串计数，用 line/comment-token 锚定
- flutter_test tag 语义已从本地 SDK 源码验证（见 D5）

## Goals / Non-Goals

**Goals:**
- 以**窗口版 integration_test** 为 live 规范形态，新建 `integration_test/live_file_tools_test.dart`，真实窗口可见 AI 回答。
- live 套件覆盖文件搜索/编辑的**全部新功能 + 关键拒绝路径**：glob_file、grep_file、批量 edits 数组、唯一匹配拒绝（多匹配无 replace_all）、模型自愈。
- 断言通过 UI 状态（`ToolCallCard` done/error）+ `ToolCallActivity.input`（工具参数）+ 文件最终状态。
- gap-2 经用户授权仅 live 覆盖"多匹配无 replace_all"拒绝（自然路径）。
- 不改任何生产代码与既有测试验收标准。

**Non-Goals:**
- 不覆盖 `read_file` / `write_file` / `list_dir`（既有工具，非 add-file-tools 范围；`real_api_test.dart` 已覆盖 write/edit）。
- 不引入 CI（项目无 CI，超范围）。
- 不 mock 模型；live 测试就是真实模型端到端。
- 不 live 覆盖空 old_text / 重叠 edits 拒绝（用户已授权收窄）。
- **不重建初版 headless 套件**（`test/integration/live_file_tools_test.dart` 已按用户确认删除——D6 选项 a；非 live 规范形态）。

## Decisions

### D1. live 形态：窗口版 integration_test 为规范

**做法：** 新建 `integration_test/live_file_tools_test.dart`，仿既有 `integration_test/real_api_test.dart`：
- `IntegrationTestWidgetsFlutterBinding.ensureInitialized()` + **环境初始化**（D2）：`sqfliteFfiInit()` + `databaseFactory = databaseFactoryFfi`（`main()` 不运行，这两行只在 `lib/main.dart:25-26` 执行，测试必须自设，否则 ChatScreen 加载 session 时抛未捕获异步错误或打开真实用户 DB）
- `pumpWidget(const MyApp())`（`MyApp` 无参 const 构造，`main.dart:30-31`）
- 运行命令：**统一规范命令** `flutter test --tags live --run-skipped integration_test/live_file_tools_test.dart -d windows`（真实桌面窗口；`--tags live --run-skipped` 已由 D5 实测确认必需且生效——tags 隔离对 integration_test 适用，见 D5）
- 驱动方式：在聊天输入框（`find.byType(TextField)`）输入指令 → 点 Send → 真实模型调用工具 → 等 `ToolCallCard` 出现并完成
- 门控：**严格字段完备性门控**（round-3 findings 7/8）——`hasCompleteConfig` 要求 `general` agent 存在、其 provider 的 `api_key` + `base_url` 均非空、`general.model` 非空（`ConfigStatus.ok` 仅保底 parse：`ProviderConfig.fromJson` 缺失 base_url 默认 `''` 不抛错，应用会 fallback 到 `api.anthropic.com`）；任一缺失 → 每测试顶部 `markTestSkipped`（任何 pumpWidget / API 调用之前，不发错误端点请求）；API 不可用时经 `Error:` 回复 → `markTestSkipped`（与 `real_api_test.dart` 一致）
- 超时：每个 `testWidgets` 设 **300s timeout**（real_api_test 先例），`pumpUntilFound` 每阶段 150s 等待循环（非 testWidgets 总超时）

**备选（放弃理由）：** 维持 headless 形态——用户已明确判定不符合规范（无窗口，看不到 AI 回答）。

### D2. 套件结构与断言机制

**环境初始化（每文件 main 顶部，仿 real_api_test.dart:55-57）：**
```dart
IntegrationTestWidgetsFlutterBinding.ensureInitialized();
sqfliteFfiInit();
databaseFactory = databaseFactoryFfi;
```
**每测试 setUp/tearDown（仿 real_api_test.dart:68-82）：**
```dart
setUp(() async { tempDir = Directory.systemTemp.createTempSync('aliasagent_live_');
  await DatabaseService.openAt(tempDir.path); });
tearDown(() async { await DatabaseService.close();
  if (tempDir.existsSync()) { try { tempDir.deleteSync(recursive: true); } catch (_) {} } });
```
> **关键（审查 finding 9/16 修复）**：`pumpWidget(const MyApp())` 时 `_AppShellState.initState`（`lib/main.dart:175-177`）执行 `_sidecar.setWorkspace(ConfigService.homeDir)`，**会把全局 sidecar workspace 重置到用户真实 home 目录**，覆盖测试此前设的 tmp。因此 fixture 时序必须是：
> 1. 创建 temp fixture 目录 + 写入文件（纯文件系统）
> 2. `pumpWidget(const MyApp())` + pump 2s（此时 initState 已把 workspace reset 到 homeDir）
> 3. **pump 之后**再调用 `SidecarBridge.instance.setWorkspace(tempPath)`（每次 pump 重建 MyApp 后都要重设）
> 4. 输入框发指令（模型经全局 workspace 读/写 fixture，绝不触碰真实用户文件）
> 5. `pumpUntilFound` 等 `ToolCallCard` 出现 → `done`（或捕获 `error`）
> 6. 断言（见下）
> 备选：完全仿 real_api_test——以 `ConfigService.homeDir` 为 workspace，fixture 用唯一前缀文件名（如 `_aliasagent_live_*.dart`）写进 homeDir。**不推荐**：grep_file/glob_file 会搜索整个 homeDir（含真实用户文件），增加不确定性；仅当重新 setWorkspace 不可行时退用。
> 此 initState reset 是最可能的 apply 失败点，已列入 Risks。

**断言机制（审查 finding 8/13/14 修复）：**
- **UI 层**：`ToolCallCard` 的 `activity.toolName`（**字段名是 `toolName`，非 `name`**——`ToolCallActivity` 定义于 `tool_call_activity.dart:55-61`，`name` 仅作 fromJson 回退键）、`activity.input`（完整工具参数，`main.dart:732-736` 从 `tc['input']` 填充）、`activity.status`（done/error）
- **卡片查找**：`find.byWidgetPredicate((w) => w is ToolCallCard && w.activity.toolName == 'edit_file' && (w.activity.input['edits'] as List).length >= 2)`。**注意**：聊天项经 `ListView.builder` 渲染（`chat_area.dart`），流式滚动时视口外卡片被回收不构建——须在该 turn 进行中轮询捕获，或完成后 `tester.scrollUntilVisible` 扫到顶部找早期卡片（real_api_test.dart:438-443 已记录同类回收 caveat）
- **文件层**：直接读文件断言最终状态（line/comment-token 锚定，不做全局子串计数）
- **拒绝软记录**：套件完成后用固定轮询窗口扫 `find.byWidgetPredicate((w) => w is ToolCallCard && w.activity.status == ToolCallStatus.error)` 并滚动到顶，`debugPrint('rejections observed: N')`——不靠单次时序命中（ListView 回收会让 error 卡片移出视口）

**可行性依据**：`ToolCallActivity.input` 保存完整工具输入（`tool_call_activity.dart:57`，`main.dart:732-736`），故窗口版**能**断言 `input['edits'].length >= 2`（批量）与拒绝/自愈路径（`error` → AI 自愈 → `done`）。`real_api_test.dart` 已示范 `ToolCallCard` 状态断言与 `markTestSkipped` 门控。**实现时须验证 `input` 字段在真实流程中正确填充**（Open Question）。

### D3. 四个场景设计

**Test 1 — 自然多工具（基线）**
fixture：两文件各一条 TODO。指令："用 grep_file 找到所有 TODO 并用 edit_file 替换成 DONE"。断言：出现过 `toolName` 为 `grep_file` 和 `edit_file` 的 `ToolCallCard` 且均 `done`；文件最终含 `DONE`。

**Test 2 — 批量 edits 数组**
fixture：`tasks.dart` 三条互不相同 TODO + `notes.dart` 一条（按 edit_file 单文件契约）。指令："对 tasks.dart 用**一次** edit_file 调用、三条替换放一个 edits 数组，不用 replace_all"。断言：存在 `ToolCallActivity.input['edits'].length >= 2` 且该卡片 `done`；两文件按行锚定（有 `// DONE` 开头行、无 `// TODO` 开头行）。

**Test 3 — 唯一匹配拒绝/自愈**
fixture：`countA()`/`countB()` 函数体**全同**（各含 `// TODO: implement`，仅函数名可区分）。指令："只改 countA 那个 TODO 为 DONE，countB 必须保留，两函数体文本相同，单行 old_text 会双匹配被拒，不要重写整个文件"。断言：文件按区域 + comment-token 锚定（countA 区域有 `DONE` token 无 `TODO` token、countB 区域有 `TODO` token 无 `DONE` token）；出现过 `edit_file` 工具卡片；软记录是否出现过 `error` 状态卡片（拒绝触发与否——fixture 最大化歧义但指令前置披露，拒绝期望低频，如实披露）。

**Test 4 — glob_file 专项**
fixture：`src/a.dart`、`src/b.dart`、`src/data.json`、`README.md`。指令："用 glob_file 找 `src/*.dart`、不用 grep_file、read a.dart 报告第一行"。断言：出现过 `toolName` 为 `glob_file` 的 `ToolCallCard` 且 `done`；glob 返回路径含 `src/a.dart` 与 `src/b.dart`（从 `ToolCallActivity` 结果或文件系统核验）。

### D4. 断言原则（继承初版审查结论）

- **硬断言只针对确定性结果**：文件最终状态（line/comment-token 锚定，不做全局子串计数）、`input['edits'].length>=2` 是否出现、工具卡片是否出现且 `done`。
- **模型过程只软记录**：是否触发拒绝（error 卡片）用 `debugPrint` 输出，不硬断言——模型可能走唯一 old_text 路径而无需拒绝（finding 19/9 边界，历次实测均 `rejections: 0`）。
- **指令要具体**：复用初版打磨过的指令文本（明确"用 grep_file / 一次调用 / 不要 replace_all / 替换为 DONE"），模型遵循率高。
- **真实窗口代价**：integration_test 慢（每次真实模型多轮）、需桌面设备、运行需人看窗口——这正是本 change 的诉求（用户可见 AI 回答），文档注明。

### D5. 隔离机制（integration_test 下重新验证）

初版 headless 的隔离（`dart_test.yaml` `tags.live.skip` + `@Tags(['live'])` + `flutter test --tags live --run-skipped`）对 `flutter test test/integration/` 已验证生效。**integration_test 适用性已实测确认（task 12.1）**：
- 验证点 A（**确认生效**）：临时探针 `integration_test/live_tags_probe_test.dart`（`@Tags(['live'])`）+ 默认命令 `flutter test integration_test/live_tags_probe_test.dart -d windows` → 输出 `Skip: Live test requires a real model API key...` + `All tests skipped`（集成测试同样受 `dart_test.yaml` `tags.live.skip` 约束，不发真实请求）
- 验证点 B（**确认生效**）：`flutter test --tags live --run-skipped integration_test/live_tags_probe_test.dart -d windows` → 真实构建 Windows 应用、运行探针用例、`All tests passed!`。故采用 `@Tags(['live'])` + 规范命令 `flutter test --tags live --run-skipped integration_test/live_file_tools_test.dart -d windows`；探针已删除
- 既有 `real_api_test.dart` 无 `@Tags`，仅 `markTestSkipped` 门控——隔离改造仅限本 change 新建的套件，不触碰既有文件

### D6. 初版 headless 套件去留（用户已确认：删除）

`test/integration/live_file_tools_test.dart`（headless，初版交付，5 轮审查 + 6 次运行（run1/run3 曾失败并已修复，run2/4/5/6 全绿）但形态不符合规范）：
- 选项 a：**删除**——不采用为 live 规范，代码移除
- 选项 b：**降级为快速回归冒烟层**——保留文件但明确标注"非 live 规范，仅工具层契约冒烟"，从 `@Tags(['live'])` 移除
- **已按用户确认执行选项 a（删除）**（task 12.6）：`test/integration/live_file_tools_test.dart` 已移除；其打磨的 fixture / 指令文本 / 断言原则已继承到窗口版套件。`dart_test.yaml` skip 消息在 task 12.1 已更新为窗口版命令（不受删除影响）。

## Risks / Trade-offs

- [integration_test tag 隔离] → D5 验证点 A/B **已实测确认生效**（task 12.1 探针），采用 `@Tags(['live'])` + `--tags live --run-skipped`；`markTestSkipped` 门控仍保留作为 config 缺失时的无条件兜底。
- [`ToolCallActivity.input` 在真实流程填充未验证] → 实现时先验证；不填充则断言退化为仅 UI 卡片 + 文件层（批量断言降级为软记录，如实披露）。
- [integration_test 慢/需桌面设备] → 每个 testWidgets 设 **300s timeout**（`real_api_test.dart` 先例），`pumpUntilFound` 每阶段 150s 等待循环（**非 testWidgets 总超时**——审查 finding 17 修正）；按需运行。
- [**AppShell.initState 重置 workspace 到 homeDir**（审查 finding 9/16，最高失败风险）] → D2 已规定 fixture 时序（pump 后重新 `setWorkspace(tempPath)`），并声明"绝不触碰真实用户文件"；实现须严格照此，若模型工具操作意外落在 homeDir 即视为实现缺陷。
- [Test 3 拒绝路径仍概率性] → 窗口版通过 error→done 观察；历次 headless 实测均 `rejections: 0`，如实披露（finding 19/9 边界）。
- [复杂指令遵循性：headless harness 与窗口 app 环境不同（审查 finding 11）] → headless 用自定义工具导向 systemPrompt + 强制 thinking，窗口 app 用 `agentTypes.general.systemPrompt`（`main.dart:706`）且 thinking 仅当 config 有 `thinking_effort` 才启用（否则 `disabled`），工具集含 web_search/web_fetch（若配置）。实现时须：a) 用真实 config 核对 `thinking_effort` 是否启用并如实记录；b) 复验 4 条指令在窗口 systemPrompt 下模型仍遵循（Test 2 单次批量、Test 3 只改 countA）；c) 若不遵循，软记录实际工具调用 + 文件状态，Test 2/3 硬断言只锁确定性文件结果，场景标注 flaky-with-reason，不静默硬失败。
- [返工后初版资产可能浪费] → 初版打磨的指令文本、fixture、断言原则、审查结论全部继承到窗口版；headless 套件去留由 D6 用户确认，不擅自处置。

## Migration Plan

1. 验证 D5 隔离机制对 integration_test 的适用性（验证点 A/B）；据此定窗口版规范命令并**更新 `dart_test.yaml` 的 skip 消息**（当前消息仍指向 headless 命令，审查 finding 4/12）。
2. 验证 `ToolCallActivity.input` 真实流程填充（D2）。
3. 新建 `integration_test/live_file_tools_test.dart`（4 场景，D3），仿 `real_api_test.dart`：含 sqfliteFfiInit + databaseFactory + `DatabaseService.openAt(tempDir)` 环境初始化（D2）。
4. 真实窗口运行（`-d windows`），用户可见 AI 回答；如实记录每场景结果、拒绝触发与否、耗时；用真实 config 核对 `thinking_effort` 并记录（finding 11）。
5. 更新 `DEBUGGING.md`（窗口版运行方法）、delta spec、tasks.md；跨 artifacts 统一窗口版规范命令（含 dart_test.yaml/proposal/design/tasks/spec/DEBUGGING.md 六处一致性核对）。
6. 按用户确认执行 D6（headless 去留）。

回滚：删除 `integration_test/live_file_tools_test.dart` + 还原 `dart_test.yaml` skip 消息即可，无生产代码风险；headless 套件未动。

## Open Questions

- `dart_test.yaml` 的 `tags` 隔离对 `flutter test integration_test/... -d windows` 是否生效？—— **已实测确认生效**（task 12.1 探针：默认跳过 + `--run-skipped` 运行），采用 `@Tags(['live'])` + `--tags live --run-skipped` 规范命令。
- `ToolCallActivity.input` 是否在真实模型工具调用流程中正确填充完整参数？—— **已确认填充**（task 12.2 静态验证 C++ `model_gateway.cpp:301-317` 完整重建 `input` + `main.dart:732-736`；task 12.4 run2 窗口实证 `input['edits'].length>=2` 断言通过）。
- 初版 headless 套件 `test/integration/live_file_tools_test.dart` 去留？—— **已确认删除**（task 12.6，用户选 D6 选项 a）。
- 窗口 app 环境下模型对复杂指令（Test 2 单次批量、Test 3 只改 countA）的遵循性，受 `thinking_effort` 与 web 工具注册影响？—— **已确认**（task 12.4：真实 config `thinking_effort = "max"` → adaptive 启用；run2 中 4 条指令均被遵循，Test 2 单次批量、Test 3 只改 countA 均达标，无静默降级）。
