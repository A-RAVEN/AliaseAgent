## Context

两个 Dart 窗口版 live 套件违反 `CLAUDE.md`「测试输出可观测性」规范：

- `integration_test/live_file_tools_test.dart` — 每用例只打印 `[TEST N] OK` + 错误卡片计数，不输出任何 `ToolCallActivity`（工具名 / input / result）或文件最终状态。失败（如 run-8 Test 3 模型偏离）无法从输出归因。
- `integration_test/real_api_test.dart` — 只打印助手回复摘录、文件校验行、REALTIME-DELTA 观察记录，不输出 web_fetch / edit_file 工具调用的 input/result。

C++ sidecar 的 4 个 `[live]` 测试已可观测（std::cout 输出实际结果），**不在本 change 范围**。`lib/` 生产代码与 C++ **一律不动**。约束已由 2 轮 Workflow 对抗验证压到 4 处修复（见 proposal「What Changes」），本 design 承接这些修复给出实现形态。

## Goals / Non-Goals

**Goals:**
- 两个窗口版 live 套件每用例在**断言前**与**所有失败路径**输出该轮实际工具调用（toolName / 完整 input / status / result）与涉及文件的最终状态
- 通过共享 helper 实现（`integration_test/live_observability.dart`），两套件复用，不复制两份
- 覆盖裸超时路径（`_waitForTurnComplete` 4 个调用点）——"对话永不完成"失败也有现场
- `DEBUGGING.md` live 章节补输出内容说明

**Non-Goals:**
- 不改生产代码（`lib/`、`sidecar/` C++ 不动）
- 不改 C++ 4 个 `[live]` 测试（已达标）
- 不弱化任何既有断言、不改既有验收标准
- 不做 headless 形态（窗口版是项目 live 规范形态）
- 不新增/删除测试用例，只在既有用例内补输出

## Decisions

### D1: 共享 helper 文件 `integration_test/live_observability.dart`

抽公共 helper，两套件 `import 'live_observability.dart'` 复用：

- `dumpToolCards(WidgetTester tester, {required String phase})` — 读取当前聊天列表内所有 `ToolCallCard`，逐个输出 `toolName`、`status`、完整 `input`（JSON）、`result` 预览；经 UI 卡片读取（窗口版观察通道，规范第 3 条）。**必须按 `ToolCallActivity.id` 去重**（ListView.builder 滚动回收会把同一卡片在多个 offset 重新挂载，`ToolCallActivity.id` 在 tool_call_activity.dart:55 存在）并设拖拽上限（复用 `_scanErrorCardsWithScroll` 的 12 次），防同一卡片重复 dump、防无界滚动。
- `dumpFile(String path, {required String label})` — 读取文件并输出内容（供 edit_file/write_file 用例 dump 文件最终状态）。
- `dumpNoTool(WidgetTester tester, String phase)` — **先扫描确认聊天列表内确无任何 `ToolCallCard`，才输出"无工具调用"**（防止模型偏离实际发出了工具调用却谎报"无工具"——本 change 的目的就是如实、可归因的输出）；若实际存在卡片，dump 真实卡片而非断言"无工具"。
- ChatArea 聊天列表滚动 finder（复用 add-file-tools-live-tests 教训：`find.descendant(of: find.byType(ChatArea), matching: find.byType(ListView))` 唯一锁定，防 ListView 二义性）+ 滚动/轮询逻辑（仿 `_scanErrorCardsWithScroll`，含拖拽次数上限）。

**替代方案：** 每套件各自写 dump 函数（复制两份）→ 拒绝，维护两套、易漂移。共享文件 + 参数化 phase 标注是更优解。

### D2: 可观测输出层是纯增量（零验收风险）

- dump 只做 `debugPrint`，**不参与断言逻辑**、不改变任何 `expect` / `fail` / `markTestSkipped` 行为
- 失败路径（`on TimeoutException` / 错误状态检测）在 `fail(...)` / `markTestSkipped(...)` **之前**调用 dump
- 回合前断言（`setWorkspace` expect、Send 按钮 `findsOneWidget`、裸 tap `StateError`）**豁免**——尚无工具调用，reason 自解释，不要求 dump（proposal F2 修复）
- **tag 副作用（Round-2 审查确认，6.7）**：6.3 为修正 5.2 命令给 `real_api_test.dart` 补 `@Tags(['live'])` + `library;` 后，plain `flutter test integration_test/real_api_test.dart` 会因 `dart_test.yaml` 的 `tags.live.skip` 全部跳过，套件只经 `--tags live --run-skipped` 运行——逆转归档运行方式（archive/2026-07-29-add-live-ui-tests proposal.md:26「运行方式: flutter test integration_test/real_api_test.dart」），与本 change 5.2 命令一致；无 CI/脚本依赖默认运行（无 .github workflows；run.bat 只跑单元测试；05_visual_regression.sh 只针对 screenshot_test）

### D3: 裸超时路径覆盖（proposal F1 HIGH 修复）

`_waitForTurnComplete`（live_file_tools_test L85-94）抛裸 `TimeoutException`，4 个调用点（L302/393/515/630）均无 `on TimeoutException` 包裹。实现方式：**调用点包 `try/on TimeoutException`，先 `dumpToolCards` + `dumpFile`（如涉及）再 `fail`/rethrow**。helper 本身保持抛裸异常（不吞，保留框架超时语义）。

**替代方案：** 在 `_waitForTurnComplete` 内部 dump 后 rethrow → 拒绝，helper 不应耦合测试的 dump 细节，且 real_api_test 无此 helper。调用点包裹更显式、可归因（失败路径可见于测试代码）。

### D4: 文件状态 dump 锚定最终状态

- edit_file / write_file 用例：断言前 `dumpFile` 输出**最终文件内容**（`File.readAsStringSync`），使"模型改了什么"可归因
- 与 `_waitForTurnComplete` 的先后顺序：dump 在回合完成后、文件断言前（文件状态已最终化）
- 无工具调用用例（real_api 3.1 基础对话 / 3.4 扩展思考）：经 `dumpNoTool` **先查无任何 `ToolCallCard` 再输出"无工具调用"**（见 D1），不做空 dump、不谎报

### D5: DEBUGGING.md 输出说明

live 测试章节补"输出内容说明"：运行者应看到每用例的 `[OBS]` 前缀 dump（工具名 / input / result / 文件状态 / 无工具调用），失败时同样有现场。

## Risks / Trade-offs

- [ToolCallCard 的 `input`/`result` 字段较大时 dump 冗长] → dump 截断 result 预览（如前 500 字符），input 完整输出（要可归因）
- [ListView.builder 回收导致部分卡片不在树内] → dump 用滚动/轮询（复用 `_scanErrorCardsWithScroll` 的滚动逻辑），扫全列表而非单次扫描
- [dump 增加测试运行耗时] → 每用例最多多一次滚动扫描（~秒级），相对 live 测试 5 分钟 timeout 可忽略
- [回合前断言不 dump 可能被认为"不够完整"] → 属设计边界：尚无工具调用，reason 自解释即可归因；范围已在 proposal 明确（F2）
- [`_waitForTurnComplete` 调用点包裹 try/on 改测试结构] → 只加包裹与 dump，不改 helper 抛异常语义、不改断言

## Migration Plan

1. 建 `integration_test/live_observability.dart`（helper：`dumpToolCards` 含 id 去重 + 拖拽上限、`dumpFile`、`dumpNoTool` 先查无卡片再断言、ChatArea 滚动 finder）
2. `live_file_tools_test.dart`：4 用例断言前 dump + `_waitForTurnComplete` 4 调用点 try/on dump + **既有 pumpUntilAll/pumpUntilFound 的 `on TimeoutException` 分支（L289/377/483/498/615）在 fail/markTestSkipped 前 dump** + 文件状态 dump
3. `real_api_test.dart`：3.2/3.3 断言前 dump + **3.1/3.2/3.3/3.4 所有 `on TimeoutException` 分支（L117/182/199/214/278/296/310/392/454）在 fail/markTestSkipped 前 dump** + 3.3 文件状态 dump；3.1/3.4 经 `dumpNoTool` 先查无卡片再输出"无工具调用"
4. `DEBUGGING.md` 补输出说明
5. 运行两套件验证输出可观测（作为明确任务落进 tasks.md，非仅设计文档描述）

## Open Questions

无（2 轮对抗审查已收敛，proposal 定稿）。
