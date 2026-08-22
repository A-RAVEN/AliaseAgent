# add-live-test-observability

## 1. 共享 helper

- [x] 1.1 新建 `integration_test/live_observability.dart`：`dumpToolCards(WidgetTester, {required String phase})` 遍历聊天列表内 `ToolCallCard` 输出 toolName / status / 完整 input / result 预览；**按 `ToolCallActivity.id` 去重**（ListView.builder 滚动回收会重复挂载同一卡片）+ 拖拽次数上限（复用 `_scanErrorCardsWithScroll` 的 12 次）；ListView 回收用 `find.descendant(of: find.byType(ChatArea), matching: find.byType(ListView))` 唯一锁定后滚动/轮询
- [x] 1.2 在 `live_observability.dart` 实现 `dumpFile(String path, {required String label})`：`File.readAsStringSync` 输出文件最终内容
- [x] 1.3 在 `live_observability.dart` 实现 `dumpNoTool(WidgetTester, String phase)`：**先扫描确认聊天列表内确无任何 `ToolCallCard` 才输出"无工具调用"**（防模型偏离发出工具调用却谎报无工具）；若实际有卡片则 dump 真实卡片
- [x] 1.4 `flutter analyze` 通过（新 helper 无未用 import、无类型错误）

## 2. live_file_tools_test 可观测输出

- [x] 2.1 import `live_observability.dart`；Test 1-4 断言前调用 `dumpToolCards(tester, phase: 'Test N pre-assertion')`（复用已有滚动逻辑）
- [x] 2.2 `_waitForTurnComplete` 4 个调用点（L302/393/515/630）包 `try/on TimeoutException`：先 `dumpToolCards` + `dumpFile`（如涉及）再 fail/rethrow（裸超时覆盖，F1 修复）
- [x] 2.3 **既有 pumpUntilAll/pumpUntilFound 的 `on TimeoutException` 分支（L289/377/483/498/615）在 `fail(...)` / `markTestSkipped(...)` 之前调用 `dumpToolCards`**（工具未到/done 未至失败类，D2 全覆盖要求）
- [x] 2.4 Test 1/2/3（涉及 edit_file）断言前同时 `dumpFile` 输出 fixture 文件最终内容；Test 4（glob_file）dump 卡片结果即可
- [x] 2.5 保留全部既有断言（不弱化），dump 为纯增量 debugPrint；`flutter analyze` 通过

## 3. real_api_test 可观测输出

- [x] 3.1 import `live_observability.dart`；3.2/3.3 断言前 `dumpToolCards(tester, phase: ...)`
- [x] 3.2 3.1/3.2/3.3/3.4 **全部 `on TimeoutException` 分支（L117/182/199/214/278/296/310/392/454）+ 错误状态检测处，在 `fail(...)` / `markTestSkipped(...)` 之前调用 dump**（含 3.1/3.4 无工具用例的失败路径——等待超时后仍有现场）
- [x] 3.3 3.3（edit_file 改文件）断言前 `dumpFile` 输出测试文件最终内容
- [x] 3.4 3.1 基础对话 / 3.4 扩展思考（无工具调用）经 `dumpNoTool` **先确认无 ToolCallCard 再输出"无工具调用"**；若实际有卡片则 dump 真实卡片
- [x] 3.5 保留全部既有断言（不弱化）；`flutter analyze` 通过

## 4. 文档

- [x] 4.1 `DEBUGGING.md` live 测试章节补"输出内容说明"：运行者应看到每用例 `[OBS]` 前缀的 dump（工具名 / input / result / 文件状态 / 无工具调用），失败路径同样有现场

## 5. 运行验证

- [x] 5.1 运行 `flutter test --tags live --run-skipped integration_test/live_file_tools_test.dart -d windows`，确认每用例输出 `[OBS]` 工具调用 dump + 文件状态（真实模型，逐用例观察输出）
- [x] 5.2 运行 `flutter test --tags live --run-skipped integration_test/real_api_test.dart -d windows`，确认 3.2/3.3 输出工具调用 dump、3.1/3.4 输出"无工具调用"（真实模型）

## 6. 诚实性审查

- [x] 6.1 开 Workflow 做对抗验证：审查 1.1-5.2 是否真实完成（每用例断言前 dump 是否就位、全部失败路径/裸超时是否覆盖、文件状态是否 dump、dumpNoTool 是否先查无卡片、既有断言是否未弱化、C++ 与 lib/ 是否未动），并验证与 proposal/design/spec 的一致性（wf_df69cc61-8da，8 agents，2 confirmed）
- [x] 6.2 审查结果无问题或修复完成（若发现问题，追加为 6.x 任务并修复后，最后一项仍为审查任务，直至确认无问题）（Round-3 确认无问题，循环收敛）
- [x] 6.3 [Round-1 FIX，wf_df69cc61-8da finding 1] `real_api_test.dart` 顶部补 `@Tags(['live'])` + `library;`（与 `live_file_tools_test.dart:1` 一致）——当前无 tag 导致 5.2 的命令 `flutter test --tags live --run-skipped integration_test/real_api_test.dart -d windows` 选出 0 个测试（test_core runner.dart:307 tag 硬过滤）；补 tag 后**用文档命令重跑 5.2**，确认 3.2/3.3 输出工具调用 dump、3.1/3.4 输出"无工具调用"，且 `flutter analyze` 通过（已实测：文档命令现可选出 4 用例；3.1/3.4 输出无工具调用、3.2 web_fetch dump、3.3 失败路径 dump read_file/edit_file/read_file 完整现场；analyze 通过。3.3 用例本身仍偶发既有 streaming 失败——sidecar Request #8 最终回复 HTTP 200 但 UI 气泡未完成，属应用侧既有问题、非本 change 引入，不在本 change 范围）。**副作用（Round-2，6.7）**：补 tag 后 plain `flutter test integration_test/real_api_test.dart` 现会因 `tags.live.skip` 全部跳过，只经 `--tags live --run-skipped` 运行——已文档化于 design.md D2，与本 change 5.2 命令一致
- [x] 6.4 [Round-1 决议，wf_df69cc61-8da finding 2] CLAUDE.md 的修改（`/opsx:propose` 完整 change 规则 + 「openspec 下禁止存在只有 proposal 的活跃 change」规则）是**上一阶段用户明确要求记录到 CLAUDE.md 的**（用户原话「记到CLAUDE.md里」「你在CLAUDE.md里记一下…」），属用户授权的流程规则沉淀，非本 change 范围；经审查确认不涉及 lib/ 与 sidecar/、不弱化任何断言，按用户指示**保留**。本任务记录该决议并核对 diff 内容与用户要求一致（已核对：diff 恰为两条规则及精确边界），不撤销用户明确要求的修改
- [x] 6.5 开 Workflow 做对抗验证（Round-2）：审查 6.3/6.4 是否真实完成 + **回归检查** Round-1 修复（1.1-5.2 全部任务 + 前一轮已确认项——id 去重、drag cap、check-first dumpNoTool、file-state scenario、无 vacuous bare-timeout、5 个 live_file_tools 分支 + 9 个 real_api 分支覆盖——是否仍成立、未被 6.3 的 tag 改动破坏），验证与 proposal/design/spec 一致性（wf_dee5a6b6-eca，9 agents，2 confirmed LOW）
- [x] 6.6 [Round-2 FIX，wf_dee5a6b6-eca finding 1] **刷新 design/proposal/tasks 中过期行号引用**（实现新增 dump + try/on 包裹使行号漂移，无覆盖缺口）——已核实当前真实行号：`real_api_test.dart` 9 个 `on TimeoutException` 分支在 L117/182/199/214/278/296/310/392/454；`live_file_tools_test.dart` 的 `_waitForTurnComplete` 定义在 L85（原 L84-93）、4 个调用点在 L302/393/515/630、5 个既有等待 `on TimeoutException` 分支在 L289/377/483/498/615。逐一更新 design.md（D3/Migration 2/3）、proposal.md（F1）、tasks.md（2.2/2.3/3.2）
- [x] 6.7 [Round-2 FIX，wf_dee5a6b6-eca finding 2] **文档化 tag 的默认运行副作用**：6.3 补 tag 后，plain `flutter test integration_test/real_api_test.dart` 会因 `dart_test.yaml` 的 `tags.live.skip` 全部跳过，套件只经 `--tags live --run-skipped` 运行——逆转了归档运行方式（archive/2026-07-29-add-live-ui-tests proposal.md:26「运行方式: flutter test integration_test/real_api_test.dart」）；与本 change 5.2 命令一致、无 CI 依赖（无 .github workflows；run.bat 只跑单元测试；05_visual_regression.sh 只针对 screenshot_test）。在 design.md D2 补一行副作用说明 + 6.3 任务文本补注
- [x] 6.8 开 Workflow 做对抗验证（Round-3）：审查 6.6/6.7 是否真实完成（行号已刷新、副作用已文档化）+ **回归检查** 前两轮全部已确认修复项（1.1-5.2 + 6.3/6.4 + id 去重/drag cap/check-first/file-state/分支覆盖）是否仍成立，验证与 proposal/design/spec 一致性（wf_e4f10206-68e，7 agents，0 confirmed——1 条发现为 prompt 表述失误经复核驳回，tasks.md 实际状态诚实正确）
