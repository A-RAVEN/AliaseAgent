## Why

项目的开发规范（`CLAUDE.md`「测试输出可观测性」）要求**所有测试的输出必须让运行者/审查者知道测试实际做了什么**。但两个 Dart 窗口版 live 套件违反该规范：

- `integration_test/live_file_tools_test.dart` 只输出 `[TEST N] OK` + 拒绝计数——**完全看不到**模型实际发起的工具调用（input/result）与文件最终状态。
- `integration_test/real_api_test.dart` 只打印助手回复摘录、文件校验行与 REALTIME-DELTA 观察记录（3.3 "Created test file"/"File edit verified"、3.4 REALTIME-DELTA 均非工具调用现场）——**看不到** web_fetch / edit_file 的工具调用 input/result。

真实 live 测试的失败因此**无法从输出归因**：例如 run-8 的 Test 3 模型偏离（countA 未改成 DONE），日志无法区分模型是改错目标、改成非 DONE 文本、还是重写了文件。C++ 的四个 live 测试均输出可观测结果、**不需改动**——`[searxng][live]`（打印结果数 + **最多前 3 条** title/url，search_provider_test.cpp L1840-1841）、`[zhipuai][live]`（打印 config + 结果数 + 每条 title/url **截断预览** + content 长度，L1880-1885）、`[kimi][live]`（打印合成回答摘要，L1933+）、`[rate-guard][live]`（打印每次调用 OK/ERROR + 成功计数，L1911）——缺口集中在 Dart 窗口版 live 套件。

## What Changes

- **统一可观测输出层**：为两个窗口版 live 套件补上"模型实际做了什么"的输出——
  - 每用例在**断言前** dump 该轮所有 `ToolCallCard` 的 `ToolCallActivity`（toolName、status、**完整 input**、result 预览）——经 UI 卡片读取（窗口版观察通道，规范第 3 条）；ListView 回收用 `find.descendant(of: ChatArea, matching: ListView)` 唯一锁定聊天列表后滚动/轮询（复用 add-file-tools-live-tests 的教训）。**dump 仅当该轮确有工具调用/文件修改**——无工具调用的用例（如 real_api_test 3.1 基础对话 / 3.4 扩展思考）如实输出"无工具调用"即可，不作空 dump。
  - **dump 覆盖全部失败路径（审查 HIGH finding）**：dump 不仅跑在断言前，也跑在每个 `on TimeoutException` 分支与错误状态检测处、在 `fail(...)` / `markTestSkipped(...)` **之前**——等待失败（如 edit_file 卡片到 error 而非 done 导致超时）是最主要的 live 失败类，失败时必须先 dump 现场再 fail/skip，否则该失败无法归因、违反规范第 2 条。**裸超时例外路径（round-2 HIGH F1）**：`_waitForTurnComplete`（live_file_tools_test L93）抛出的裸 `TimeoutException` 在其 4 个调用点（L302/393/515/630）均无 `on TimeoutException` 包裹、不在任何枚举站点内——"对话永不完成"这一等待失败必须在超时抛出**之前**获得现场（在 `_waitForTurnComplete` 内 dump 后 rethrow，或调用点 `try/on` 包裹先 dump 再 fail）。
  - **回合前断言豁免（round-2 MEDIUM F2）**：dump 站点覆盖**工具回合开始之后**的失败（等待超时 / 错误状态 / 断言 / fail/skip）；回合开始前的设置/交互断言（`setWorkspace` expect、Send 按钮 `findsOneWidget`、裸 tap `StateError`）失败时**尚无工具调用**，其自解释 reason 字符串即可归因——这些路径不要求 dump，但"覆盖全部失败路径"以此为界，不扩大到回合前。
  - 涉及文件修改的用例（edit_file / write_file）同时 dump **文件最终状态**。
  - dump 先于断言/失败判定 → 失败时现场可见（规范第 1 条）、失败可归因（规范第 2 条）。
- **共享 helper**：抽公共 `dumpToolCards` / `dumpFile` 于 `integration_test/` 共享文件，两套件复用，不复制两份。
- **文档**：`DEBUGGING.md` 的 live 测试章节补"输出内容说明"（运行者应看到什么）。
- **不改任何生产代码**（`lib/`、`sidecar/` C++ 不动）；**不弱化任何既有断言**；C++ live 测试不动（已达标）。

## Capabilities

### New Capabilities

（无）

### Modified Capabilities

- `live-ui-tests`: 增加"live 测试输出可观测性"要求——窗口版 live 测试（真实模型驱动）SHALL 在**断言前及所有失败路径（等待超时 / 错误状态检测）**输出该轮**实际工具调用**（toolName / 完整 input / status / result）与涉及文件的**最终状态**（如有工具调用/文件修改；无工具调用的用例如实报告"无工具调用"），使失败可归因；不输出测试内容即规范违规。约束 `real_api_test.dart`（**整文件套件级约束**——该套件 3.1/3.2 用例的需求在此 spec，3.3 write_file+edit_file 与 3.4 extended thinking 的需求分别归 file-edit-tools / extended-thinking 能力，可观测性要求不以单个能力为锚，对套件内全部用例统一生效）。
- `real-sidecar-tests`: 同一"live 测试输出可观测性"要求约束 `live_file_tools_test.dart`（该套件的需求容器——其窗口版 live 需求已由归档 change 同步至本 spec 的「Live tests are window-based integration tests（规范形态）」与「Live tests cover file search/edit tools end-to-end in the window」）。

## Impact

- `integration_test/live_file_tools_test.dart` — 补可观测输出（每用例 dump 工具调用 + 文件状态）
- `integration_test/real_api_test.dart` — 补可观测输出（dump web_fetch / edit_file / write_file 工具调用 + 文件状态）
- `integration_test/` — 新增共享 helper（如 `live_observability.dart`：`dumpToolCards` / `dumpFile` / 聊天列表滚动 finder）
- `openspec/specs/live-ui-tests/spec.md` 与 `openspec/specs/real-sidecar-tests/spec.md` — 同步"live 测试输出可观测性"delta 要求（两份 delta spec）
- `DEBUGGING.md` — live 测试章节补输出内容说明
- C++ `sidecar/test/search_provider_test.cpp` — **不动**（已可观测）
- **不改任何生产代码**（`lib/`、`sidecar/` C++ 不动）；不改既有测试的验收标准
- 依赖：真实 DeepSeek API key（运行 live 套件）
