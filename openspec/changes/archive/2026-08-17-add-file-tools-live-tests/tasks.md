## 1. Live 隔离机制

- [x] 1.1 新建项目根 `dart_test.yaml`，配置 `tags: live: skip: "Live test requires a real model API key. Run with: flutter test --tags live --run-skipped test/integration/live_file_tools_test.dart"`（skip 消息内嵌**规范命令**，与 design D1 / proposal / DEBUGGING.md 完全一致）
- [x] 1.2 端到端验证隔离语义（第 2 轮 finding 6 后重跑留存输出）：a) 默认 `flutter test` → `b420ydy83.output` 显示 `Skip: Live test requires a real model API key...` + `All tests skipped`（带原因、不发请求）✓；b) 规范命令 `flutter test --tags live --run-skipped test/integration/live_file_tools_test.dart` 真正运行 4 用例 ✓（见 3.2 运行清单）；c) 无完整 config（USERPROFILE 指向无 config 路径）+ `--run-skipped` → `bn3gy1f06.output` 显示 `live file tools suite skipped` 通过、4 真实用例未注册、不发请求 ✓。实测与本地源码确认的语义一致
- [x] 1.3 给 `live_file_tools_test.dart` 加 `@Tags(['live'])` 注解（**实测**：`@Tags(['live'])` + `library;` 置于文件顶部，flutter analyze 通过、`flutter test` 识别并跳过——注解在该 SDK 版本可用，无需 test(tags:) 回退）

## 2. Live 套件重构（4 用例）

- [x] 2.1 文件顶部 key 门控：api_key、base_url、model 三字段全非空才注册套件，任一缺失则注册单个 skip test 并 return（**单一门控机制**，无 per-test markTestSkipped）；无 fallback 默认值（base_url/model 均从 config 读取）
- [x] 2.2 Test 1 基线自然多工具（6.4 语义保留）：两文件多 TODO，指示"用 grep_file 找到所有 TODO 并用 edit_file 修复"；断言 `usedTools` 含 `edit_file` **且含 `grep_file`**、文件最终含 DONE、success 为真
- [x] 2.3 Test 2 批量 edits 数组（**fixture 按 edit_file 单文件契约设计**）：`src/tasks.dart` 三条互不相同 TODO、`src/notes.dart` 一条 TODO；指示"对 tasks.dart 一次 edit_file 调用、三条替换放一个 edits 数组，notes.dart 单独处理，不用 replace_all"；断言存在 `edits.length >= 2` 且 `ok:true` 且 `replacements >= 2` 的调用、两文件按行锚定断言（有 `// DONE` 开头行、无 `// TODO` 开头行——design D4）
- [x] 2.4 Test 3 唯一匹配拒绝/自愈（**区域断言**，design D3）：单文件两处相同 `// TODO: implement` 分属 countA/countB；指示"只改 countA、countB 必须保留，两行文本相同"；断言 countA 区域含 DONE 不含 TODO、countB 区域含 TODO 不含 DONE（区域切分按函数签名，对模型替换文本风格鲁棒）；print 输出触发过的 `ok:false` edit_file 调用数（软记录可见）
- [x] 2.5 Test 4 glob_file 专用：fixture 含 `src/a.dart`、`src/b.dart`、`src/data.json`、`README.md`；指示"用 glob_file 找 `src/*.dart`、不用 grep_file、read a.dart 报告第一行"；断言 `usedTools` 含 `glob_file`、glob 调用返回路径含 src/a.dart 与 src/b.dart
- [x] 2.6 共享 harness 与 workspace 隔离：`buildTools()`/`executeTool()` 保持；`_runModelLoop` 收集器记录每轮 name/input/result；**每个 test 独立 temp workspace**（`_useWorkspace`：createTempSync → addTearDown → setWorkspace），防单例 g_workspace 跨测试串扰；保持 5 分钟 timeout

## 3. 验证与回归

- [x] 3.1 全量非 live Dart 套件：`flutter test` **153 通过 + 1 跳过**（live 套件显示 skip 原因，非静默非失败），All tests passed!（最终代码状态复跑 `b0z0b5gox.output`，第 3 轮 finding 12 后钉住证据）
- [x] 3.2 用真实 key 跑 live 套件：**全部 live 运行清单（第 2 轮审查 finding 5 补齐，含失败运行）**：
  - run1 `baj30azo2.output`：Test 2 **失败**（模型把 TODO 注释删除而非替换 DONE——根因是 Test 2 指令未显式说明替换文本；修复指令后通过）。此为 live 测试抓到测试指令歧义的真实案例
  - run2 `be0fdi63i.output`：**4/4 通过（40s）**（Test 1 grep_file+edit_file；Test 2 `edits_len=3 ok=true replacements=3` 批量真发；Test 3 走唯一 old_text、`rejections:0`；Test 4 glob_file）
  - run3 `b09x3p7hx.output`：**Test 3 失败**（round-1 fixture 强化为函数体全同后，模型在 countA 内成功替换一次（`edits_len=1 ok=true replacements=1`）但替换结果未以 `// DONE` 开头，`startsWith('// DONE')` 断言假失败——模型行为正确、断言不适用行内注释（收尾轮 finding 9：替换文本细节为实测后的一致推断，保留输出仅记录 edits_len/ok/replacements）；改用 comment-token 锚定修复）
  - run4 `bqvnx3ymn.output`：**4/4 通过（26s）**（Test 3 仍走唯一 old_text、`rejections:0`）
  - run5 `b8xn5i2dj.output`：**4/4 通过（31s）**（第 2 轮 finding 3 修复后——Test 3 新增 `usedTools contains edit_file` 断言，仍通过且 `rejections:0`）
  - run6 `bgebhy04h.output`：**4/4 通过（28s）**（归档前用户复跑：Test 1 grep_file+edit_file；Test 2 `edits_len=3 ok=true replacements=3`；Test 3 走唯一 old_text、`rejections:0`；Test 4 glob_file）
  - 六次到达 Test 3 的运行均 `rejections: 0`——拒绝路径未被 live 触发，已如实披露（finding 9/19 边界）
- [x] 3.3 C++ sidecar 套件回归：sidecar_tests **228 用例中 227 通过**，唯一失败为既有 `search_provider_test.cpp:1892` ZhipuAI live 测试（`REQUIRE(success_count == N)` → `0 == 5`，rate-guard 测试读取真实 ZhipuAI config key，`[zhipuai][live][rate-guard]`，需真实 ZhipuAI API 的 live/网络环境性失败——第 1 轮审查 finding 8 修正归因：单独复跑 ZhipuAI 过滤时 `1853` 处测试 WARN+return 实为 **PASS**，真正失败在 `1892` 处 rate-guard 测试，因 ZhipuAI API 不可达/401 致 0 次成功；归档已注明此类 `[zhipuai][live][rate-guard]` 属环境性失败，本 change 零 C++ 改动，非回归；收尾轮 finding 4/7：不引用无法本地验证的 `key=test_key` 输出细节）
- [x] 3.4 更新 `DEBUGGING.md`：新增"Running Live Tests"章节（规范命令、前置条件 api_key+base_url+model + tools/rg.exe、成本提示、跳过原因说明、套件内容）

## 4. 归档前收尾

- [x] 4.1 跨 artifacts 一致性核对：规范命令 `flutter test --tags live --run-skipped test/integration/live_file_tools_test.dart` 在 dart_test.yaml/proposal/design/tasks/spec/DEBUGGING.md 六处一致（design 中裸 `--tags live` 仅出现在语义论述与已否决方案处——D1 做法、备选方案、Open Questions，均非规范命令，收尾轮 finding 8）；spec 4 场景 ↔ design D3 ↔ 实际代码断言一一对应；Test 1 grep_file 强化为指令要求的合理升级非降级；Test 2 fixture 与 edit_file 单文件契约一致
- [x] 4.2 诚实性审查（第 1 轮，Workflow 对抗验证）：**9/9 findings 确认（全 low）**。核心结论：a) 22 条历史 findings 修复全部保持，**无回归**；b) 隔离机制、断言对照、6.4 基线强化均核实无降级；c) 发现 9 个新问题（见下节 5.x），最重要的：**gap-2 的拒绝路径在两次 recorded live 运行中均未触发（rejections: 0/2）**，已如实披露但 live 拒绝证据仍缺失

## 5. 第 1 轮审查 findings 修复

- [x] 5.1 finding 1：Test 2 断言改为**行锚定**（无 `// TODO` 开头行、有 `// DONE` 开头行），analyze 干净
- [x] 5.2 finding 2：system prompt 日期改为 `DateTime.now().toString().substring(0,10)` 动态日期
- [x] 5.3 finding 3：Test 4 改为 `globCalls.any(...)`（任意成功 glob 调用返回目标路径即可）
- [x] 5.4 finding 4/6：Test 3 改为**防御式切分**（length 检查）+ **comment-token 锚定断言**（`_commentToken`：`return 1; // DONE: fix` → `DONE`，兼容行内注释、对 `// DONE (was TODO)` 自述式文本正确）+ 指令加"不要重写整个文件"。**实测修正**：fixture 强化后模型产出 `return 1; // DONE`（行内注释），`startsWith('// DONE')` 断言假失败——改用 token 锚定后通过（analyze 干净 + 全量 live 4/4）
- [x] 5.5 finding 5：回归确认（22 条修复全部保持）→ 已记录，无代码改动
- [x] 5.6 finding 7：design D1 标注 `LIVE_TESTS=1` 兜底"未触发、无需实现"
- [x] 5.7 finding 8：重跑 C++ 确认真实失败在 `search_provider_test.cpp:1892`（`success_count 0 == 5`，ZhipuAI rate-guard live），1853 处实为 PASS → tasks.md 3.3 已如实修正
- [x] 5.8 finding 9：Test 3 fixture 强化为**函数体全同**（`return 1; // TODO: implement` 均同），单行 old_text 必然双匹配。重跑 live（run4 `bqvnx3ymn.output`）：**4/4 通过（26s）**，Test 3 仍走唯一 old_text 路径、`rejections: 0`（第 3 轮 finding 1/4/8 修正计数 + 归档前复跑 run6 更新：**实际 6 次到达 Test 3 的运行（run1-run6）全部未触发**，见 3.2 清单——确认 finding 9/19 边界：拒绝概率性，此模型一贯避免，已如实披露）

## 6. 诚实性审查（第 2 轮）

- [x] 6.1 第 2 轮诚实性审查（Workflow 对抗验证）：**7/7 findings 确认（全 low/medium）**。核心结论：a) 22 条历史 + 第 1 轮 9 条 findings 修复全部保持，**无回归**；b) 发现 7 个新问题（见下节 7.x）：Test 3 缺 edit_file 断言（假绿风险）、spec 场景 (b)(c) 措辞与 line/token 锚定实现不一致、design Risk 对指令描述与实际相反、live 运行清单缺 run3 失败、1.2a/1.2c 断言无留存输出、4.1"一一对应"措辞过强

## 7. 第 2 轮审查 findings 修复

- [x] 7.1 finding 1：回归确认（22 历史 + 9 round-1 修复全部保持）→ 无代码改动，已记录
- [x] 7.2 finding 2：spec 场景 (b) 措辞改为**行锚定**（"replaced TODO lines reading `// DONE` and no line beginning with `// TODO`"，标注 per design D4 非全局子串）
- [x] 7.3 finding 3：Test 3 新增 `expect(out.usedTools, contains('edit_file'))` 断言（write_file 重写无法满足），重跑 run5 `b8xn5i2dj.output` 4/4 通过
- [x] 7.4 finding 4：design Risk 对齐实际指令——fixture 最大化裸匹配歧义但指令已前置披露拒绝条件，拒绝期望低频触发，不虚假声称
- [x] 7.5 finding 5：tasks.md 3.2 枚举全部 live 运行清单（run1-run5，含 run3 Test 3 失败），5.8 计数修正为"5 次到达 Test 3 全未触发"
- [x] 7.6 finding 6：重跑 1.2a `b420ydy83.output`（默认 skip 显示原因 + All tests skipped）、1.2c `bn3gy1f06.output`（no-config + --run-skipped 优雅跳过），留存证据并引用
- [x] 7.7 finding 7：spec 场景 (c) 措辞改为 **comment-token 锚定区域断言**（countA 区域 DONE token 无 TODO token、countB 区域 TODO token 无 DONE token）

## 8. 诚实性审查（第 3 轮，收尾前）

- [x] 8.1 第 3 轮诚实性审查（Workflow 对抗验证）：**12/12 findings 确认（全 low/medium）**。核心结论：a) 历轮修复无功能性回归（回归检查通过）；b) 问题全部为**计数/措辞过期**：tasks.md 5.8 说"4 次"而 3.2 已枚举 5 次、design Risk 说"三次"、proposal L15 的 Test 3 断言描述仍是旧 line 形式且漏 edit_file 断言、design D3 漏 edit_file 断言记录、3.1 全量证据早于最终 live 文件编辑。修复见下节 9.x

## 9. 第 3 轮审查 findings 修复

- [x] 9.1 finding 1/4/8：tasks.md 5.8 计数修正为"**实际 5 次到达 Test 3 的运行（run1-run5）全部未触发**"（此前误写 4 次，与 3.2 的 run1-run5 清单和 7.5 修正声明矛盾）
- [x] 9.2 finding 2/5/7/9：design Risk 计数修正为"**五次 recorded 运行 run1-run5 均 rejections:0（见 tasks 3.2 清单）**"（此前误写三次）
- [x] 9.3 finding 3/6/10：proposal.md L15 Test 3 描述改为**区域 + comment-token 锚定**（countA 区域含 DONE token 无 TODO token、countB 区域含 TODO token 无 DONE token，非"恰好一行"）+ `usedTools` 含 `edit_file`，与 spec/design/代码一致
- [x] 9.4 finding 11：design D3 Test 3 断言列表补 `usedTools` 含 `edit_file`（write_file 全文件重写不得满足唯一匹配/拒绝覆盖——第 2 轮 finding 3）
- [x] 9.5 finding 12：重跑全量非 live `flutter test` 对最终代码状态：`b0z0b5gox.output` **153 通过 + 1 跳过，All tests passed!**（3.1 已引用）

## 10. 诚实性审查（收尾轮，3 轮上限已达）

- [x] 10.1 收尾轮诚实性审查（Workflow 对抗验证，3 轮上限后强制收尾）：**9/9 findings 确认（全 low）**。核心结论：a) 全部 50 条历轮 findings（22+9+7+12）修复在当前代码中仍成立，**零回归**；b) 5 条 round-3 修复（9.1-9.5）全部正确落地；c) 跨 artifacts 计数/措辞一致（5 次运行、token 锚定、edit_file 断言、规范命令六处一致）；d) **无伪造、无隐藏失败**：run1/run3 真实失败均如实披露，9 份留存输出逐一核对，零生产代码改动。发现 9 个 low 级措辞/计数精确性问题（见下节 11.x），已全部修复

## 11. 收尾轮审查 findings 修复

- [x] 11.1 finding 1/5：收尾验证通过（50 条修复保持、无回归、无伪造）→ 无代码改动，已记录
- [x] 11.2 finding 2：design Context 表 C++ 计数更新为"228 用例（227 通过 + 1 `[zhipuai][live][rate-guard]` 环境性失败）"（此前"220 用例全绿"为提案时基线快照）
- [x] 11.3 finding 3：spec 场景 (b) 措辞改为"at least one TODO line replaced to read `// DONE`"（消除复数过强，与 at-least-one 实现一致）
- [x] 11.4 finding 4/7：tasks 3.3 移除不可本地验证的 `key=test_key` 输出引用，改为"rate-guard 测试读取真实 ZhipuAI config key"机制描述
- [x] 11.5 finding 6：tasks 2.3 措辞改为"按行锚定断言（有 `// DONE` 开头行、无 `// TODO` 开头行——design D4）"
- [x] 11.6 finding 8：tasks 4.1 括号修正为"design 中裸 `--tags live` 仅出现在语义论述与已否决方案处（D1 做法、备选方案、Open Questions），均非规范命令"
- [x] 11.7 finding 9：tasks 3.2 run3 机制描述软化至留存证据范围（`edits_len=1 ok=true replacements=1` 但结果未以 `// DONE` 开头），注明替换文本细节为一致推断

## 12. 返工：窗口版 live（用户判定 headless 形态不符合规范）

**返工背景**：本 change 初版把 live 套件实现为 headless（`test/integration/live_file_tools_test.dart`，flutter_tester 无窗口），完整实施 + 5 轮审查（59 findings 全部修复）+ 6 次运行（**run1/run3 曾失败并已修复，run2/4/5/6 全绿**——审查 finding 1/6/15 修正"全绿"措辞），但用户明确判定 live 测试规范形态是**窗口版 integration_test**（真实桌面窗口可见 AI 回答，如 `integration_test/real_api_test.dart`）。proposal/design/spec 已返工为窗口版方向；本节为窗口版实施任务，**初版 headless 代码保持不动**（去留见 12.6，用户确认前不处置）。

> **reconciliation（审查 finding 3）**：本节之前所有历史 `[x]` 任务中出现的"规范命令" `flutter test --tags live --run-skipped test/integration/live_file_tools_test.dart` 均指**初版 headless 命令**，已由窗口版命令 `flutter test --tags live --run-skipped integration_test/live_file_tools_test.dart -d windows` 取代（若 D5 验证 tags 生效；否则为 `flutter test integration_test/live_file_tools_test.dart -d windows` + markTestSkipped）。跨 artifacts 一致性核对以窗口版命令为准。

- [x] 12.1 验证 D5：`dart_test.yaml` 的 `tags.live.skip` 对 `flutter test integration_test/... -d windows` 是否生效（生效 → `@Tags(['live'])` + 窗口版规范命令 `flutter test --tags live --run-skipped integration_test/live_file_tools_test.dart -d windows`；不生效 → 退化 `markTestSkipped` 门控，如实记录）；**同步更新 `dart_test.yaml` 的 `tags.live.skip` 消息**为窗口版命令（当前仍指向 headless 命令——审查 finding 4/12），并做跨 artifacts（dart_test.yaml/proposal/design/tasks/spec/DEBUGGING.md）六处命令一致性核对。**实测确认生效**：临时探针 `integration_test/live_tags_probe_test.dart`（`@Tags(['live'])`）默认命令 → `Skip: Live test requires...` + `All tests skipped`；`--tags live --run-skipped -d windows` → 构建 Windows 应用并运行探针用例（All tests passed!）。探针已删除。**探针证据留存**（审查 finding F4 后补）：`evidence/live_tags_probe_default.log`（默认命令 → `Skip: Live test requires...` + `All tests skipped`）、`evidence/live_tags_probe_run.log`（`--tags live --run-skipped -d windows` → 构建 + 运行探针 + `All tests passed!`）。`dart_test.yaml` skip 消息已更新为窗口版命令；design D5/D1/Open Questions/Risks 与 spec Requirement 1 已记录实测结论并去除"以实测为准"条件措辞；六处命令一致性核对通过（DEBUGGING.md 待 12.5 更新）。
- [x] 12.2 验证 D2：`ToolCallActivity.input` 在真实模型工具调用流程中是否正确填充完整参数（`edits` 数组等）——以实测为准；不填充则批量断言降级为软记录并披露。**静态验证通过**：C++ `model_gateway.cpp:301-317` 由 `input_json_delta` 累积重建**完整** `input`（`tool["input"] = json::parse(pj_it->second)`）后整体 emit `on_tool_call`（不裁剪）；Dart `main.dart:732-736` 构造 `ToolCallActivity.input = tc['input']`（完整参数）；`input` 为 final 字段经 `copyWith` 保留（`tool_call_activity.dart:73-91`）；`ToolCallCard.activity` 公开可读。初版 headless 同源 `onToolCall` 实测已见 `edits_len=3`。**窗口实证**由 12.4 运行的 `input['edits'].length >= 2` 断言确认（若不填充则按设计降级为软记录并披露）。
- [x] 12.3 新建 `integration_test/live_file_tools_test.dart`（窗口版 4 场景，design D2/D3）：**环境初始化**（`IntegrationTestWidgetsFlutterBinding` + `sqfliteFfiInit()` + `databaseFactory = databaseFactoryFfi` + `DatabaseService.openAt(tempDir)` in setUp + close/delete in tearDown——审查 finding 10）；**fixture 时序**（`pumpWidget(MyApp)` 后 `AppShell.initState` 重置 workspace 到 homeDir，故必须 pump 后重新 `SidecarBridge.instance.setWorkspace(tempPath)` 再发指令——审查 finding 9/16）；断言用 `activity.toolName`（非 `name`——finding 8）+ `find.byWidgetPredicate` 谓词 + ListView 回收应对（滚动/轮询——finding 13/14）；每 testWidgets 设 300s timeout + `pumpUntilFound` 每阶段 150s（finding 17）；场景为自然多工具 / 批量 edits（断言 `input['edits'].length >= 2`）/ 唯一匹配拒绝自愈（error→done + 区域 comment-token 断言）/ glob_file 专项。**已实现并 `flutter analyze` 干净**：`integration_test/live_file_tools_test.dart` 顶部 `@Tags(['live'])` + `library;`；`setUp` 建 tempDir + `DatabaseService.openAt`、`tearDown` close+delete；每测试 pump 后 `expect(setWorkspace(ws), isNull)`（非空即失败——防模型落到 homeDir 的安全保证）；`toolCard(name,{status})` / `batchEditCard()` / `_countErrorCards` 谓词（`activity.toolName`，input 防御式 `is List` 检查）；API 不可用时 `markTestSkipped` + `apiAvailable=false` 优雅降级（仿 real_api_test，spec Requirement 1）；4 场景复用初版打磨的 fixture 与指令文本。
- [x] 12.4 真实窗口运行验证：**统一规范命令**（按 12.1 验证结果选一）`flutter test --tags live --run-skipped integration_test/live_file_tools_test.dart -d windows` 或 `flutter test integration_test/live_file_tools_test.dart -d windows`，用户可见真实 AI 回答；如实记录每场景结果、拒绝触发与否、耗时；**用真实 config 核对 `agent_types.general.thinking_effort` 是否启用**（thinking disabled 会改变指令遵循性——审查 finding 11）并如实记录。**运行记录（窗口真实可见 AI 回答）**：
  - **run1**：**3/4** —— Test 1/3/4 通过；Test 2 失败（`notes.dart TODO should be replaced with DONE` 断言假失败）。根因是**测试竞态非工具缺陷**：批量断言 `input['edits'].length>=2` 已通过（模型确实发了批量），但指令"Handle src/notes.dart separately"使模型在**后续独立 turn** 编辑 notes.dart，测试只等 tasks.dart 批量卡片即断言文件、notes.dart 尚未应用；`DatabaseException(database_closed)` 噪音来自失败测试 teardown 关闭 DB 而 `_callModel` 仍在跑（应用侧 catch，无碍）。**修复**：新增 `_waitForTurnComplete`（轮询 `ChatArea.isStreaming==false`——`_isStreaming` 跨 turn 保持 true、仅全部结束时清除，main.dart `_endStreaming`），文件断言前等全部 turn 应用。
  - **run2**：**4/4 通过（42s）** —— Test 1 grep_file+edit_file 均 done + 文件含 DONE；Test 2 批量 `edits.length>=2` + 两文件行锚定 `// DONE` 无 `// TODO`；Test 3 countA DONE / countB 保留（区域+comment-token 锚定）、`error-status tool cards observed: 0`；Test 4 glob_file 卡片结果含 `src/a.dart` + `src/b.dart`。窗口版套件真实通过。
  - **run3**（round-1 审查 14.2/14.3 修复后复跑）：**4/4 通过（44s）** —— Test 4 补 `_waitForTurnComplete`、Test 3 改滚动+轮询软记录后无回归；`error-status tool cards observed: 0`。证据 `evidence/live_window_run3.log`。
  - **run4**（round-2 审查 14.6 修复后复跑）：**4/4 通过（46s）** —— `_scanErrorCardsWithScroll` 改为 `find.descendant(of: ChatArea, matching: ListView)` 唯一锁定聊天列表后，滚动缓解**代码层面生效**（ChatArea 后代 ListView 唯一匹配、Test 3 在 `_waitForTurnComplete` 后调用）；`error-status tool cards observed: 0`。**不做时序证据**（wrap-up finding：Test 3 的 13s 主要是模型延迟，滚动窗口至多 ~2.4s，跨 run 2/3/6 该 gap 9-13s 属模型延迟噪声）。证据 `evidence/live_window_run4.log`。
  - **run5**（round-3 审查 14.7/14.8 严格门控修复后复跑）：**Test 1 通过后 Test 2 于 00:24（进入 11s）「did not complete」硬性中止**，后续 Test 3/4/tearDownAll 级联中止，无异常详情（`evidence/live_window_run5.log`）。门控为纯前置检查（真实 config 三字段完备 → hasCompleteConfig=true，happy path 与 run4 逐字一致），不可能是运行时中止诱因；Test 1 通过时序 00:13（与 run6 相同；**run4 实为 00:11**——时间归因修正，wrap-up finding），疑为**瞬时原生/模型崩溃 flake**（初始 headless 亦曾 run1/run3 失败）。
  - **run6**（run5 判定复跑）：**4/4 通过（48s）** —— 确认 run5 为瞬时 flake（非门控回归）；Test 2 批量 `edits.length>=2` + 两文件行锚定 DONE、Test 3 countA/countB 区域断言 + `error-status tool cards observed: 0`、Test 4 glob_file 返回 `src/a.dart`+`src/b.dart`、Test 1 grep+edit done。证据 `evidence/live_window_run6.log`。
  - **run7**（收尾轮审查 14.12 修复后复跑）：**4/4 通过（48s）** —— Test 3 第二个等待补 `Error:` 优雅降级后无回归。证据 `evidence/live_window_run7.log`。
  - **run8**（用户观测试运行）：**3/4** —— Test 3 失败（`countA TODO should have been changed to DONE`，line 511）：模型 edit_file 达 done 且 0 error 卡，但 countA 区域未得 DONE token——**实时模型行为偏离**（改错目标或改成非 DONE token），套件正确捕获；非套件缺陷。证据 `evidence/live_window_run8.log`。
  - **run9**（run8 判定复跑）：**4/4 通过（48s）** —— 确认 run8 为实时模型 flake。证据 `evidence/live_window_run9.log`。
  - **thinking_effort 核对（finding 11）**：真实 config `agent_types.general.thinking_effort = "max"` → `_callModel` 判定 `adaptive` 启用（非 disabled）；在此配置下 4 条指令均被遵循（Test 2 单次批量、Test 3 只改 countA），无静默降级。
  - **实证 12.2**：`input['edits'].length>=2` 断言在窗口真实流程通过 → `ToolCallActivity.input` 完整填充工具参数。
  - **实证 12.3**：pump 后 `setWorkspace` 时序生效——模型只读写 fixture，未触碰 homeDir（`setWorkspace` 返回 null 断言通过）。
  - **运行证据留存**（审查 finding F4 后补）：`evidence/live_window_run1.log`、`evidence/live_window_run2.log`、`evidence/live_window_run3.log`、`evidence/live_window_run4.log`、`evidence/live_window_run5.log`（瞬时 flake）、`evidence/live_window_run6.log`、`evidence/live_window_run7.log`、`evidence/live_window_run8.log`（实时模型偏离 flake）、`evidence/live_window_run9.log`（各轮修复后复跑，见 14.3/14.4/14.6/14.7/14.12）。
- [x] 12.5 更新 `DEBUGGING.md` 为窗口版运行方法（统一命令、前置条件、成本提示）；核对 spec 场景与实现一致。**已完成**：DEBUGGING.md "Running Live Tests" 章节改为窗口版——规范命令 `flutter test --tags live --run-skipped integration_test/live_file_tools_test.dart -d windows`、默认排除语义、前置条件（config 三字段 / rg.exe / thinking_effort 影响遵循性 finding 11）、成本提示、4 场景内容、fixture 时序（pump 后重设 setWorkspace）说明、headless 套件去留提示。spec 场景逐一核对一致（Req 1 三场景 + Req 2 四场景 ↔ Test 1-4 实现，含 markTestSkipped 门控与 API-error 优雅降级）。
- [x] 12.6 headless 去留（D6，用户确认后执行）：删除或降级为快速回归冒烟层——**用户确认前不处置**；处置时同步调整 `dart_test.yaml` skip 消息（finding 4）。**用户确认选项 a（删除）**：`test/integration/live_file_tools_test.dart` 已删除（其 fixture/指令文本/断言原则已继承到窗口版套件）。`dart_test.yaml` skip 消息无需调整——task 12.1 已改为窗口版命令，指向保留的 `integration_test/live_file_tools_test.dart`。同步更新：proposal.md（Why/What Changes/Impact 三处）、design.md（D6、Non-Goals）、DEBUGGING.md（headless 段落改为"已按用户确认删除"）。
- [x] 12.7 诚实性审查（最后一项）：开 Workflow 做对抗验证（CLAUDE.md 规则 7），审查输入必须携带：返工前后全部任务清单、初版 59 条 findings + 修复状态、返工审查 17 条 findings + 修复状态（见 13.x）、窗口版设计 D1-D6 与 spec 场景、实测记录（隔离适用性 / ToolCallActivity.input / 窗口运行）。对抗验证 agent 逐一核对：窗口版套件是否真实窗口形态、断言是否与 spec 一致且无降级、初版 headless 是否未被擅动、fixture 时序是否规避 initState reset、是否有隐藏失败或伪造结果、**回归检查**：历轮 findings 修复仍成立且返工未破坏。发现的问题追加为新任务并修复，循环至审查确认无问题或达 3 轮上限+收尾轮。**已完成（3 轮 + 强制收尾轮，全部 findings 修复）**：第 1 轮 4 条（14.1-14.5，全 low）、第 2 轮 1 条回归（14.6，scroll 修复无效→修正为 ChatArea 后代 finder）、第 3 轮 2 条（14.7/14.8，严格门控）、收尾轮 4 条（14.9-14.12，时间归因/过度声明/Test 3 第二个等待优雅降级）；每轮修复后窗口复跑（run2-run7 全绿，run5 为瞬时 flake 已如实披露）；**回归检查通过**：历轮修复在最终代码/artifacts 中全部成立，无 [x]→[ ] 逆转，无验收标准篡改。审查详情见 section 14。

## 13. 返工审查 findings 修复

**背景**：返工 artifacts 经 Workflow 对抗审查确认 17 条 findings（19 条中 17 条，2 high 设计缺陷 + 诚实性/一致性措辞），全部修复：

- [x] 13.1 finding 1/6/15：design.md/tasks.md 返工背景的"6 次 live 运行全绿"修正为"run1/run3 曾失败并已修复，run2/4/5/6 全绿"（3 处，含 D6 段落）
- [x] 13.2 finding 2/7：proposal.md Why items 1-3 重构——反映初版已关闭"假 live"与批量验证缺口（带 live 证据），item 4 为返工核心；补初版 5 轮审查 + 59 findings + 6 次运行历史记录
- [x] 13.3 finding 3：tasks.md section 12 加 reconciliation 说明——历史 `[x]` 的"规范命令"指初版 headless 命令，由窗口版命令取代
- [x] 13.4 finding 4/12：tasks 12.1 加"更新 dart_test.yaml skip 消息为窗口版命令 + 六处一致性核对"；D1/12.4 统一窗口版规范命令
- [x] 13.5 finding 5：spec Requirement 1 的 `markTestSkipped` 门控改为**无条件**（tags 生效分支同样需要）
- [x] 13.6 finding 8：design D2 的 `activity.name` 修正为 `activity.toolName`（字段名以 `tool_call_activity.dart:55-61` 为准）
- [x] 13.7 finding 9/16（HIGH）：design D2 fixture 时序重写——`pumpWidget(MyApp)` 后 `AppShell.initState` 重置 workspace 到 homeDir，故 pump 后重新 `setWorkspace(tempPath)`；列入 Risks（最高失败风险）
- [x] 13.8 finding 10（HIGH）：design D1/D2 + tasks 12.3 补 sqfliteFfiInit + databaseFactory + `DatabaseService.openAt(tempDir)` 环境初始化（`main()` 不运行）
- [x] 13.9 finding 11：design Risks 加"复杂指令遵循性：headless harness vs 窗口 app 环境差异"（thinking_effort、web 工具注册、fallback/flakiness 披露策略）；tasks 12.4 加 thinking_effort 核对
- [x] 13.10 finding 13/14：design D2 断言机制写清 `find.byWidgetPredicate` 谓词 + ListView 回收应对（滚动/轮询）+ 拒绝软记录轮询方式
- [x] 13.11 finding 17：design Risks 超时修正——testWidgets 300s timeout + `pumpUntilFound` 每阶段 150s（real_api_test 先例）

## 14. 窗口版诚实性审查（第 1 轮，Workflow 对抗验证）

**审查结果**：Workflow（wf_dc47ee94-236，4 个对抗 lens + 逐 finding 验证）确认 **4 条 low 级问题**（全部经对抗验证 CONFIRMED；无 HIGH/medium；spec/design/代码三方一致性与外部真实性经核对无降级）。发现的问题已全部修复：

- [x] 14.1 finding 1（consistency, low）：design.md `## Open Questions` 仍列三条**已解决**问题（ToolCallActivity.input / headless 去留 / thinking_effort 遵循性）而未标注结论。**修复**：三条均补标注（12.2 静态+实证 / 12.6 用户删除 / 12.4 thinking_effort=max 且指令被遵循）。
- [x] 14.2 finding 2（race, low）：Test 4 结束未 `_waitForTurnComplete`——指令要求 glob 后 read_file，后续 turn 未结束即 teardown，属 run-1 Test 2 同类竞态。**修复**：Test 4 补 `_waitForTurnComplete(tester)`（注释说明与 run-1 竞态同类）。
- [x] 14.3 finding 3（race, low）：Test 3 拒绝软记录 `_countErrorCards` 仅**单次非滚动扫描**，ListView 回收可能假零，未落实 design D2"固定轮询窗口扫 + 滚动到顶"。**修复**：新增 `_scanErrorCardsWithScroll`（30s 窗口 + 最多 12 次向上 drag 重渲染 + try-catch 兜底），Test 3 改用之。
- [x] 14.4 finding 4（honesty/evidence, low）：窗口阶段实测记录（12.1 探针、12.4 run1/run2）**未留存可核查证据文件**。**修复**：新建 `evidence/` 并留存 `live_tags_probe_default.log`（默认跳过）、`live_tags_probe_run.log`（--run-skipped 运行）、`live_window_run1.log`、`live_window_run2.log`；12.1/12.4 已引用；**run3 复跑验证 14.2/14.3 无回归**（见 12.4 运行证据）。
- [x] 14.5 finding 5（记录性质）：lens「spec/design/代码映射 + edit_file 批量契约外部真实性」结论为**无更弱覆盖**（正向核验，非缺陷），无修复动作。

**第 2 轮审查（Workflow wf_8680688a-4f3，回归检查 + 新问题）**：确认 **1 条回归缺陷**（14.6，两 agent 独立确认）+ 其余全部核验干净（fixture 时序、`_waitForTurnComplete` 语义、每测试隔离、run2/run3 日志诚实、14.1/14.4 修复成立、无 homeDir 触碰路径、历史 findings 无回归）。第 2 轮同时确认：唯一 setWorkspace 生产调用是 `main.dart:176`（initState→homeDir，pump 期间运行），sidecar `is_within_workspace`（tools.cpp:139-148）拒绝逃逸；`_isStreaming` 仅在 `_endStreaming`（main.dart:1426-1446）清除、跨工具 turn 保持 true——`_waitForTurnComplete` 是正确完成信号，四个测试均在文件断言/teardown 前调用。

- [x] 14.6 finding 6（回归，race，low/medium）：**14.3 修复无效**——`_scanErrorCardsWithScroll` 用 `find.byType(ListView)` 匹配到 **两个** ListView（`session_sidebar.dart:52` 会话列表 + `chat_area.dart:93` 消息列表，AppShell `Row(SessionSidebar, ChatArea)`，main.dart:1472-1490），`tester.drag` 的 `getCenter` 在 finder 匹配 >1 时抛「ambiguously found multiple matching widgets」（本地 SDK `controller.dart:2094-2098`），被 `catch(_) { break; }` 吞掉 → 退化回**单次非滚动扫描**（正是 F3 要消除的假零风险），且 run2/run3 的 `error-status tool cards observed: 0` 未在滚动缓解下产生。**修复**：改为 `find.descendant(of: find.byType(ChatArea), matching: find.byType(ListView))` 唯一锁定聊天列表（ChatArea 是消息列表的唯一直系祖先，内部恰一个 ListView）；滚动在 `_waitForTurnComplete` 之后进行，不影响 live turn。**run4 复跑验证**（见 12.4 运行证据）。

**第 3 轮审查（Workflow wf_355f42d5-3fb，回归检查 + 新问题）**：确认 **2 条问题（同根因）** —— config 门控只查 `ConfigStatus.ok`（parse 级），未查**字段完备性**。14.6 修复经核对**真正生效**（ChatArea 后代 ListView 唯一匹配、run4 滚动缓解执行、14.1-14.6 全部成立、run4 日志诚实、无历史回归）。

- [x] 14.7 finding 7（spec-vs-code，medium）：**门控不校验 base_url**——`ProviderConfig.fromJson`（provider_config.dart:13）缺失 base_url 默认 `''` 不抛错、`AppConfig` parse 通过；套件放行后应用在 `main.dart:660-662` fallback 到 `https://api.anthropic.com`，把 DeepSeek key **发往错误默认端点**（一次真实请求）后才经 `Error:` → markTestSkipped。违反 spec Req-1(c)「rather than ... firing calls against a wrong default endpoint」与「无 fallback 默认值」声明；也是对被删 headless 套件 2.1 严格门控（三字段全非空才注册）的降级。**修复**：门控改为 `hasCompleteConfig`——`general` agent 存在且其 `provider` 的 `api_key` + `base_url` 均非空 + `general.model` 非空（`ConfigStatus.ok` 仅保底 parse）；任一缺失 → 每测试顶部 `markTestSkipped`（**在任何 pumpWidget/API 调用之前**），杜绝错误端点请求。
- [x] 14.8 finding 8（isolation-gate，low）：门控只查 parse 级配置存在、未查字段完备性——缺失 base_url / 空 api_key 时套件仍运行并发真实请求后才跳过，违反 spec Req-1「无完整 config（api_key、base_url、model 任一缺失）→ SHALL 无条件 markTestSkipped」。**修复**：同 14.7（`hasCompleteConfig` 严格门控）。注：缺失 api_key/model 因 `as String` 抛 TypeError → malformed → 本就被 gate 拦住；缺口仅在 base_url，已被 14.7 修复。**run5 复跑验证**（见 12.4 运行证据）。

**收尾轮审查（Workflow wf_b3809f6a-ef7，3 轮上限后强制收尾）**：确认 **4 条 low 级问题**（2 条运行记录时间归因不精确、1 条 Test 3 第二个等待缺 API-error 优雅降级、1 条 run4 时序证据过度声明）；其余全部核验干净——14.1-14.8 全部成立、fixture 时序 / `_waitForTurnComplete` / 严格门控 / 隔离 / 六处命令一致性 / spec 三方映射 / 外部真实性均无问题、run1-6 日志逐一对得上且 run5 flake 判定诚实。

- [x] 14.9 finding 9（run-record-precision，low）：run5 叙事「Test 1 通过时序与 run4 相同 00:13」**归因错误**——run4 实为 00:11（`evidence/live_window_run4.log` `00:11 +1: Test 2`），00:13 是 run5/run6 自身的时序。**修复**：run5 记录改为「Test 1 通过时序 00:13（与 run6 相同；run4 实为 00:11）」。
- [x] 14.10 finding 10（run-record-precision，low）：run4 叙事「Test 3 耗时 13s 反映滚动+轮询窗口执行」**过度声明**——滚动窗口至多 12 次 drag×~200ms ≈ 2.4s，Test 3 的 13s gap 主要由模型延迟（pumpUntilFound 等 done 卡）构成；跨 run 2/3/6 该 gap 9-13s 属模型延迟噪声。滚动缓解**代码层面**已确认真实生效（ChatArea 后代 ListView 唯一匹配、Test 3 于 `_waitForTurnComplete` 后调用），但不以时序为证据。**修复**：run4 记录去除时序证据措辞。
- [x] 14.11 finding 11（run-record-accuracy，low）：同 14.9（run5 对 run4 时间归因错误）。**修复**：同 14.9 一并修正。
- [x] 14.12 finding 12（gating-robustness，low）：Test 3 **第二个**等待（等 edit_file DONE 卡）在 TimeoutException 时无条件 `fail`，缺其它所有等待都有的 `Error:` → `markTestSkipped` + `apiAvailable=false` 优雅降级——若 API 在首个卡片出现后中途死亡（DONE 永不抵达），会把 API 可用性 flake 变成硬失败，违反 DEBUGGING.md「API 调用失败 → markTestSkipped」与 spec Req-1 优雅跳过契约。**修复**：该等待补上同款 Error 检查降级。**run7 复跑验证**（见 12.4 运行证据）。
