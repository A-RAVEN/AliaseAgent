## Why

项目的开发规范（`CLAUDE.md`「测试输出可观测性」）要求**所有测试的输出必须让运行者/审查者知道测试实际做了什么**。但两个 Dart 窗口版 live 套件违反该规范：

- `integration_test/live_file_tools_test.dart` 只输出 `[TEST N] OK` + 拒绝计数——**完全看不到**模型实际发起的工具调用（input/result）与文件最终状态。
- `integration_test/real_api_test.dart` 只打印助手回复与文件校验行——**看不到** web_fetch / edit_file 的工具调用 input/result。

真实 live 测试的失败因此**无法从输出归因**：例如 run-8 的 Test 3 模型偏离（countA 未改成 DONE），日志无法区分模型是改错目标、改成非 DONE 文本、还是重写了文件。C++ 的 `[zhipuai][live]` / `[searxng][live]` / `[rate-guard]` 测试本就可观测（`std::cout` 打印 config、结果数、每条 title/url/content），**不需改动**——缺口集中在 Dart 窗口版 live 套件。

## What Changes

- **统一可观测输出层**：为两个窗口版 live 套件补上"模型实际做了什么"的输出——
  - 每用例在**断言前** dump 该轮所有 `ToolCallCard` 的 `ToolCallActivity`（toolName、status、**完整 input**、result 预览）——经 UI 卡片读取（窗口版观察通道，规范第 3 条）；ListView 回收用 `find.descendant(of: ChatArea, matching: ListView)` 唯一锁定聊天列表后滚动/轮询（复用 add-file-tools-live-tests 的教训）。
  - 涉及文件修改的用例（edit_file / write_file）同时 dump **文件最终状态**。
  - dump 先于断言 → 失败时现场可见（规范第 1 条）、失败可归因（规范第 2 条）。
- **共享 helper**：抽公共 `dumpToolCards` / `dumpFile` 于 `integration_test/` 共享文件，两套件复用，不复制两份。
- **文档**：`DEBUGGING.md` 的 live 测试章节补"输出内容说明"（运行者应看到什么）。
- **不改任何生产代码**（`lib/`、`sidecar/` C++ 不动）；**不弱化任何既有断言**；C++ live 测试不动（已达标）。

## Capabilities

### New Capabilities

（无）

### Modified Capabilities

- `live-ui-tests`: 增加"live 测试输出可观测性"要求——窗口版 live 测试（真实模型驱动）SHALL 在断言前输出该轮**实际工具调用**（toolName / 完整 input / status / result）与涉及文件的**最终状态**，使失败可归因；不输出测试内容即规范违规。该要求同时约束 `real_api_test.dart` 与 `live_file_tools_test.dart`（同属窗口版 live 形态，观察通道为 UI 卡片 `ToolCallActivity`）。

## Impact

- `integration_test/live_file_tools_test.dart` — 补可观测输出（每用例 dump 工具调用 + 文件状态）
- `integration_test/real_api_test.dart` — 补可观测输出（dump web_fetch / edit_file / write_file 工具调用 + 文件状态）
- `integration_test/` — 新增共享 helper（如 `live_observability.dart`：`dumpToolCards` / `dumpFile` / 聊天列表滚动 finder）
- `DEBUGGING.md` — live 测试章节补输出内容说明
- C++ `sidecar/test/search_provider_test.cpp` — **不动**（已可观测）
- **不改任何生产代码**（`lib/`、`sidecar/` C++ 不动）；不改既有测试的验收标准
- 依赖：真实 DeepSeek API key（运行 live 套件）
