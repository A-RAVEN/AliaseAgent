# handle-empty-assistant-reply

## 1. 测试侧轮询等待 + 诚实归因

- [x] 1.1 `integration_test/real_api_test.dart` 加 `import 'package:alias_agent/ui/chat_area.dart';`
- [x] 1.2 实现轮询等待 helper `pumpUntilReplyOrTurnDone`（定义在 real_api_test.dart，复用 `completedAssistant` finder）：pump 直到「completed assistant 气泡出现」或「流式已开始后变 false」；含**流式已开始守卫**（`sawStreaming`——必须先观察到 `isStreaming==true` 才接受"回合完成"）；`isStreaming` 变 false 后先 pump 500ms 宽限再查气泡（Error 路径竞态）；150s 仍在流式 → 抛 TimeoutException
- [x] 1.3 4 个测试（3.1/3.2/3.3/3.4）的 `completedAssistant` 等待替换为该 helper，分类：有气泡 → 正常路径（读 `latestAssistantText`、断言非空）；**静默完成（无气泡且流式已停）→ `fail` 诚实归因**（信息注明"模型空回复或内部异常，见 [OBS] dump 与 sidecar 日志"）；TimeoutException → `fail`（真挂起/死锁）
- [x] 1.4 3.3 的静默完成分支与 hang 分支在 fail 前**删除 `_aliasagent_live_test.txt`**（home 目录文件不在 tearDown 清理范围，匹配既有 ToolCallCard-timeout 分支的清理）
- [x] 1.5 保留既有 Error: 回复 skip 逻辑（`text.startsWith('Error:')` → markTestSkipped）

## 2. 指令硬化

- [x] 2.1 3.3 指令改为显式要求「修改完成后，必须用中文自然语言回复我：修改是否成功，以及修改后的文件内容」（design D2，降低空回复触发频率；概率性缓解，不替代 D1）

## 3. 修复 dump 滚动回归

- [x] 3.1 `integration_test/live_observability.dart` 的 `_scanToolCards`：收集循环结束后用相同次数反向 drag（`Offset(0, -400)`）恢复视口到底部（ListView 在 maxScrollExtent 钳制），使 `dumpToolCards`/`dumpNoTool` 非破坏性（design D3，08-22 实测回归）
- [x] 3.2 恢复循环**镜像收集循环的防御**：每个恢复 drag 包 try/catch，`chatList.evaluate().isEmpty` 时跳过恢复（design D3，审查 finding E）
- [x] 3.3 在 design.md 已文档化跨套件副作用（D3 使 `live_file_tools_test` 的 Error: skip 分支从死恢复活，fail→skip 属预期修复）；tasks 5.1 运行验证确认无回归
- [x] 3.4 D3 恢复机制修复（apply 5.1 实测修正）：`_scanToolCards` 恢复视口改 `ScrollController.jumpTo(maxScrollExtent)`（经 `tester.widget<ListView>(chatList).controller`），替代首版反向 drag。原因：首版反向 drag 在 Test 1 内正常但破坏整个套件（Test 2/3/4 全部 `did not complete [E]`；基线 pre-D3 4/4 通过）——手势 drag 在钳制边缘残留 ballistic 动画跨测试存活，破坏下一 testWidgets 的 binding；jumpTo 同步、无手势、无 ballistic、零跨测试残留。防御：`chatList.evaluate().isEmpty`/controller null/`hasClients` 检查 + try/catch best-effort（design D3 已同步更新）
- [x] 3.5 重新运行 5.1 验证：修复后 `live_file_tools_test` 4/4 全通过（`All tests passed!`，2026-08-22 实测），无回归；Error: skip 分支恢复为预期行为（design D3 已文档化）

## 4. spec 文档

- [x] 4.1 核对 `specs/live-ui-tests/spec.md` delta 格式合规（`## MODIFIED Requirements` + `### Requirement: Error classification and resilience` 整块替换 + `#### Scenario` 4 个 hashtag），内容：修改后「Test timeout」场景（isStreaming==true 才 fail 死锁）+ 新增「Silent completion」场景（静默完成 → **fail 诚实归因，不 skip**）

## 5. 运行验证（真实模型）

- [x] 5.1 跑 `flutter test --tags live --run-skipped integration_test/live_file_tools_test.dart -d windows`，确认 D3 后该套件无回归（Error: skip 分支恢复生效为预期行为）。实测 3 轮：首版 D3（反向 drag）→ Test 2/3/4 全部 `did not complete [E]`（失败）；基线 pre-D3 → 4/4 通过；jumpTo 修复版 → 4/4 通过。结论：D3 恢复机制修正后该套件无回归
- [x] 5.2 跑 `flutter test --tags live --run-skipped integration_test/real_api_test.dart -d windows`（2026-08-22 实测，+3 -1）：**3.1/3.2/3.4 通过**（各自 dump 之后 `latestAssistantText` 均正确读到，D3 修复在 real_api_test 验证生效，旧 null 误报消失）；**3.3 以"静默完成 → 诚实 fail"失败**（方案①预期行为，非回归）——D1 在 ~15s 内输出诚实归因信息 + [OBS] 证据 dump，取代旧 150s 误导性 deadlock。归因：sidecar 日志显示工具链全部成功（read_file→edit_file→read_file，文件已含 "LINE TWO MODIFIED"）后最终回合 Request #7 HTTP 200 正常完成但无文本 → **模型空回复首次直接复现**（08-18 间接证据、08-22 三次 TRACE 未抓到；D2 指令硬化本次未阻止空回复，符合"概率性缓解，D1 兜底"）。3.3 文件清理生效（`_aliasagent_live_test.txt` 已删除）。分类三分全部演示：正常→通过（3.1/3.2/3.4）、静默完成→诚实 fail（3.3）、挂起→deadlock fail（本次未触发）

## 6. 诚实性审查

- [x] 6.1 开 Workflow 做对抗验证（round 1，2026-08-22 实测：5 维 5 agents 0 错误）：审查 1.1-5.2 是否真实完成（**无生产代码改动**、helper 的流式守卫/宽限重检/静默完成 fail 归因正确、3.3 文件清理就位、D3 恢复防御就位、既有断言未弱化、C++ 未动、spec delta 与 proposal/design 一致、finding A-G 全部落实）。结果：核心实现全 CLEAN，4 条 LOW 文档/规格精确性发现 → 见 6.3-6.6
- [x] 6.2 审查结果无问题或修复完成（round-2 确认无问题，2026-08-22；若发现问题，追加为 6.x 任务并修复后，最后一项仍为审查任务，直至确认无问题）
- [x] 6.3 (round-1 finding 2, LOW) design.md 补 finding F 可追溯标签：D4 段与 Non-Goals 标 `(审查 finding F)`（A/B/C/D/E/G 均已标，独缺 F）
- [x] 6.4 (round-1 finding 3, LOW) spec「Test timeout」WHEN 扩为覆盖"150s 内从未观察到流式"子情形（isStreaming 全程 false 的 DB 前奏挂起）→ 同样 fail TimeoutException；design.md D4 同步
- [x] 6.5 (round-1 finding 4, LOW) design.md Migration Plan step 1 改为 jumpTo 恢复机制（消除与 D3 决策段"不能用反向 drag"的矛盾）
- [x] 6.6 (round-1 finding 1, LOW) design.md 注明透明性：本 apply 叠加在未提交 sibling change add-live-test-observability 之上（共享 real_api_test.dart / live_observability.dart），工作区为混合未提交状态，仅凭 git diff 无法隔离二者改动，归属需读 change artifacts
- [x] 6.7 round-2 Workflow 对抗验证（2026-08-22 实测：3 维 3 agents 0 错误，**全部 CLEAN，0 findings**）：核验 6.3-6.6 已修复、finding A-G 未回归、round-1 四条修复未破坏实现、tasks.md 验证记录仍诚实；无新问题，无需继续循环
