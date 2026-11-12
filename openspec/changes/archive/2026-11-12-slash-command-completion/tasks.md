# Tasks: slash-command-completion

按物理顺序执行（先写用例跑出红，再实现）。回链：状态机=design D1（含光标判据与"首段后无文本"）；拦截前置="面板可见且存在高亮行"（D2，零候选不吞键）；匹配=借鉴 DSH 骨架（D3）；接受=只替换首段、保留其后文本（D4）；接线点=`lib/ui/input_bar.dart`（main.dart 里没有 TextField，已核实）。展开语义一行不碰。

## 1. 匹配纯函数（Dart）

- [x] 1.1 新建 `lib/ui/slash_completion.dart`：`List<String> filterSkillNames(String query, List<String> names)`——空查询按 names 输入顺序全量；不区分大小写按序子序列匹配（按序不必相邻）；前缀命中排最前，其余按首次命中位置；无命中返回空列表。零 IO 纯函数，注释写明"借鉴 DSH dsh-client-ui-commands fuzzy-label 的排序骨架（前缀→对齐分→原始序），本实现有意不移植对齐分"
- [x] 1.2 新建 `test/unit/slash_completion_test.dart`：前缀优先于子序列、子序列按序不必相邻（**用 `/egk` 命中 `edge-skill` 证明非相邻**，`/ed` 只能证相邻子序列）、大小写不敏感（`/EGK` 同命中）、空查询按输入顺序全量、无命中空列表、多命中排序稳定。贴全绿输出

## 2. 用例先行（先红）

- [x] 2.1 新建 `test/widget/slash_completion_panel_test.dart`（**先写、先跑出红证据再实现 2.2/2.3**）。现场配方（照 slash_command_display_test 先例）：setUp 建临时根 → `SkillCatalogService.instance.setRootForTests(临时根)` → 写 `edge-skill/SKILL.md`（frontmatter `name: edge-skill` + 非空 description）→ pump ChatScreen 三次至 `hasScanned`；tearDown 恢复默认根并 `resetForTests()`。用例清单（每条都要能红）：
  - ① 键入 `/ed`：面板出现且含 `edge-skill`；**先断正事实**——面板行 findsOneWidget 且 `tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus`——再 sendKeyEvent(tab)；断文本=`/edge-skill `（尾部空格）、**焦点仍 hasFocus**、面板消失、**未发送**（user 角色 MessageBubble findsNothing 且 FakeSidecar.sendHandles 为空；pump 节奏与同文件对照用例一致）
  - ② 回车同 Tab（接受补全、不发送）
  - ③ Esc 关闭、文本不变、焦点在输入框
  - ④ 继续打空格（`/ed `）面板消失、文本保持
  - ⑤ `/EGK` 子序列命中；`/zzz` 无命中时**显示"无匹配技能"行且按回车仍走发送原行为**（发送对照：普通文本点 Send → 气泡出现 / sendHandles 非空——这条对照就是 ③ 的反空断言控制，负断言与对照同一 pump 节奏）
  - ⑥ ↑↓ 移动高亮后 Tab 接受对应行（夹具含两个技能）
  - ⑦ 空目录（resetForTests + 空临时根）：键入 `/` 显示空态行「装一个技能后这里会自动出现候选（详见 skills.md）」、无候选行、不报错
  - ⑧ `/ed 正文`（首段后有文本）光标移回首段：面板不显示
  贴改前红输出（现状无面板，全部必红）与改后绿输出

## 3. 面板组件与输入行接线（Dart）

- [x] 3.1 实现候选面板组件（Overlay + LayerLink/CompositedTransformTarget/Follower，`Target` 放在 `lib/ui/input_bar.dart` 的 `_InputBarState.build` 内包住 `Expanded` 里的 TextField）：浮于输入框上方、宽度对齐、不占布局；行=技能名、高亮行 secondaryContainer 级色调；无命中行「无匹配技能」与空态行（精确串同上）；面板 never request focus
- [x] 3.2 输入行接线（`lib/ui/input_bar.dart` 的 `_InputBarState`，在**现有 `Focus(onKeyEvent: _onKey)` 里、先于既有 Enter→`_submit()` 分支**）：面板可见**且有高亮行**时 Tab/Enter=接受、↑↓=移动、Esc/Shift+Tab=关闭（全 handled）；零候选一律 ignored（Enter 仍发送、Tab 仍焦点遍历）；D1 状态机（`/` 开头 + `selection.isValid && isCollapsed && 1 <= baseOffset <= 首段末` + 有焦点 + 首段后无文本）；接受=只把首段替换为 `/名␣`、其后文本原样保留、光标落插入点后、不发送；击键重筛现读 `activeSkillNames`；鼠标点击候选=接受。`flutter analyze` 改动文件零新增

## 4. 文档与守卫

- [x] 4.1 `Docs/user-guide/slash-commands.md` 补"补全"一节（触发/Tab 接受/回车改道语义——面板可见时回车是接受不是发送、接受后或 Esc 后再按回车才发送/零候选不吞键/空目录提示/候选表随最近一条消息刷新非即时/Tab 被面板截胡是无障碍已知限制）；文档守卫加能失败判据（含"Tab"与空态精确串）
- [x] 4.2 若其它守卫因新文案/新文件变红，点名改并贴改前红证据；无则写明为什么不改

## 5. 全量验证与变异（主循环批次执行）

- [x] 5.1 `scripts\sync_sidecar_dll.ps1` 后 `flutter analyze`（基线 161——出处 `%TEMP%\skill_9.1_analyze.log`，改动文件零新增）+ `flutter test` 全量贴 `+N All tests passed!`

**实测**：DLL 已是最新（sync-OK already current）；analyze `161 issues found` = 基线，改动文件零新增（Select-String 无命中）；全量 `+855 All tests passed!`（基线 +837，新增 18 条 = 单测 8 + widget 9 + 文档守卫 1）

- [x] 5.2 两个变异（各贴红证据后恢复，复跑全绿、改动文件哈希与变异前逐位相同）：① 把 3.2 的 Tab 拦截删掉（面板可见时 Tab 走默认焦点遍历）→ 2.1①的 Tab 用例必须红（红在"文本未替换"与"焦点断言"两处，任务里点名）；② 把接受分支改成接受后调用 `_submitInput()` → 2.1①的"未发送"断言必须红

**实测**（任务文本里的 `_submitInput()` 是旧稿名，实现里方法叫 `_submit()`，变异落在它上面；变异前哈希 899606F0…B391D）：
① 删 Tab 分支 → `+7 -2`，①红在 `Expected: '/edge-skill ' Actual: '/ed'`（文本未替换）且现场 `焦点=false`（焦点断言红），⑥连带红。恢复后哈希逐位相同。
② `_acceptCandidate` 末尾加 `_submit()` → ①红在 `Tab 后：气泡=[user:/edge-skill , assistant:收到] sendHandles=[s1]`（"未发送"断言红）。恢复后哈希逐位相同（899606F0…B391D），复跑 `+9 All tests passed!`

- [x] 5.3 `openspec validate slash-command-completion` 通过贴输出

**实测**：`Change 'slash-command-completion' is valid`
