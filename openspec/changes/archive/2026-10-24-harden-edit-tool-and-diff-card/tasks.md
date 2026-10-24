## 0. 开工前置

- [x] 0.1 记录开工基线：`git status --short` 确认 `lib/main.dart`、`lib/models/context_breakdown.dart` 里没有别人未提交的改动（当前工作区有正在进行的 `add-context-occupancy-ring`）；把 `flutter test` 与 `test/smoke/run_all.sh` 此刻的失败清单原样抄进本 change 的记录，作为后面"没有新增失败"的对照。验收：两份清单都贴出来；没有基线的"全绿"不许当验收。
- [x] 0.2 确认 C++ 测试二进制是新的：`cmake --build sidecar/build/windows --config Debug` 后跑 `sidecar\build\windows\Debug\sidecar_tests.exe --list-tests`，输出里能看到本 change 新增的用例名。验收：`ctest` 只执行已存在的 exe、不编译；不先构建的话"全绿"跑的是旧二进制，新用例根本没进去。

## 1. 原子写

- [x] 1.1 在 `sidecar/src/tools.cpp` 新增 `write_atomically(resolved_path, content)`：①每次写入前清理同目录下同一目标的旧临时文件（`<目标文件名>.tmp-*`）；②同目录临时文件 `<目标文件名>.tmp-<进程号>-<递增序号>` 写入并刷盘；③Windows 用 `MoveFileExW(MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)`、其它平台用 `rename` 覆盖；④任一步失败删除临时文件并返回错误。错误文案钉死两条：临时文件建不出来给 `Cannot stage file: <路径>`，改名失败（含目标只读）给 `Cannot replace file: <路径> (rename failed, error <系统错误码>)`——不得沿用现有的 `Cannot write file: <路径>`。转宽串用 `CP_ACP`（与 `GetFullPathNameA`/`GetFileAttributesA` 同码页）。验收：`write_file` 与 `edit_file` 两处 `std::ofstream(... trunc)` 覆写全部改为调用它，文件里不再有 `std::ios::trunc`。
- [x] 1.2 在 `sidecar/test/tool_execution_test.cpp` 增加原子写用例（必须能在"没有真正原子写"时变红）：①`read_file` 先让文件进入观测表 → 把目标文件设为只读 → `edit_file` 失败，错误文本以 `Cannot replace file:` 开头，调用前后文件字节完全相同，目录里没有 `<目标文件名>.tmp-*` 条目；②`edit_file` 成功后目录里同样没有临时文件残留；③预置一个 `<目标文件名>.tmp-999999-1` 的旧残留后成功写入，该残留被清掉；④含中文的目录名下 `write_file` 与 `edit_file` 内容都正确。验收：先构建（0.2）再 `ctest --test-dir sidecar/build/windows -C Debug` 全绿；把落盘改回 `std::ofstream(..., trunc)` 时用例 ① 变红（直接覆写在只读目标上给的是 `Cannot write file: …`）；该用例只在 Windows 成立（POSIX 上可写目录里的只读文件仍可被改名）。

## 2. 观测表与版本守卫

- [x] 2.1 在 `sidecar/src/tools.cpp` 增加进程级观测表 `path → {mtime_ticks, size}`（键为 `check_path` 解析出的规范化绝对路径），写记录的调用点共 5 处：`read_file` 的三个 `ok:true` 出口（空文件、`offset` 超过总行数、正常读取）、`write_file` 成功出口、`edit_file` 成功出口。验收：这 5 处都记录；`list_dir` 之后直接改、`glob_file` 之后直接改、`grep_file` 之后直接改、`run_command` 之后直接改，四条负向用例都必须拿到 `not_observed`（多记一处会让这四条变红）。
- [x] 2.2 增加仅测试使用的清空入口 `tools::reset_observation_state_for_tests()`（声明在 `sidecar/src/tools.h` 的 `namespace tools` 里，与现有 `classify_grep_regex_error` 等测试用函数同一节）。验收：用例 `read_file(a.txt)` → 清空 → `edit_file(a.txt)` 必须返回 `not_observed`；对照用例不清空时必须成功（证明是清空让它变的，不是别的原因）。把函数写成空实现时第一条变红。
- [x] 2.3 在 `edit_file` 里把守卫插在现有保护之后、读取内容与匹配之前，顺序写死为：参数结构 → `check_path` → 存在性/是否目录 → 1MB → 二进制 → 未观测 `not_observed` → 版本不符 `stale` → 读内容/匹配/写入。两条错误的 JSON 分别为 `{"ok":false,"code":"not_observed","error":"cannot edit \"<路径>\": read the file first"}` 与 `{"ok":false,"code":"stale","error":"cannot edit \"<路径>\": file changed since it was read; read it again before editing"}`。两种情况都不改文件。验收：两种拒绝与成功三种输入的返回值、以及拒绝后的文件字节，都在用例里逐条断言。
- [x] 2.4 改造现有 C++ 用例（必须紧跟 2.3，否则后面每一步的"ctest 全绿"都不成立）：目标为**文本文件**、当前"建文件后直接 `edit_file`"的用例改成先 `read_file`，并在相关用例开头调用清空入口；目标为**二进制文件、大于 1MB 的文件、目录**的用例不改编排（守卫排在它们之后，仍拿到原来的三条错误文案），只补一条"它不是 `not_observed`"的断言。验收：构建后 `ctest` 全绿；用例总数不少于改动前，三级匹配、批量、重叠、大小/二进制/目录判定这些原有断言一条都不删；改造完成后统计"以文本文件为目标且不先读"的 `edit_file` 用例数必须为 0。
- [x] 2.5 增加守卫用例：①没读过直接改文本文件 → `not_observed` 且文件不变；②`read_file` 后改 → 成功；③`write_file` 新建后立刻改 → 成功；④`read_file` 后用其它途径改文件（内容与大小都变、且 `old_text` 在新内容里**已经不存在**）再 `edit_file` → `stale`（不是"not found"诊断）且文件不变；⑤`stale` 后重新 `read_file` 再改 → 成功；⑥用 `dir/a.txt` 读、用 `dir/../dir/a.txt` 改 → 允许；⑦`read_file` 读一个空文件（返回 `ok:true`）后再 `edit_file` → 不是 `not_observed`；⑧对从未观测过的二进制文件、超大文件、目录调 `edit_file` → 仍是原来的三条错误文案，不是 `not_observed`；⑨读完 → 改 `aaa`→`bbbb`（**不等长**，让大小也变）成功 → 不再读直接改 `bbbb`→`ccc` → 成功（证明 `edit_file` 自己成功也记观测）；⑩`read_file` 返回 `ok:true` 的 `offset exceeds file length` 那条路径之后再改 → 不是 `not_observed`。验收：构建后 `ctest` 全绿；把守卫整段注释掉时用例 ①④ 变红；把 `edit_file` 成功出口的记录去掉时用例 ⑨ 变红。

## 3. C++ 结果里的 hunks

- [x] 3.1 `edit_file` 成功时按命中区间生成 `hunks`：`[{start_line, old_text, new_text}]`，一个命中位置一个元素、按起始偏移升序，`start_line` 为该位置在原文件中起点所在行（1 起），`old_text` 取磁盘上被替换的真实字节、`new_text` 为写入内容；`replace_all` 命中 N 处就给 N 个元素；失败响应不带 `hunks`；`hunks` 序列化后超过 1MB（复用 1MB 上限判据）时不附带 `hunks`，改带 `"hunks_omitted":"too large"`。验收：见 3.2 的用例判据，行号算错或漏掉体积封顶时对应用例变红。
- [x] 3.2 增加 `hunks` 用例（每条都先 `read_file` 造观测再改，否则会先撞 `not_observed`）：①第 3 行单处替换 → 一个元素 `start_line=3`、`old_text`/`new_text` 与磁盘实际一致；②`replace_all` 命中第 2、7、9 行 → 三个元素按 2、7、9 排序且 `replacements=3`；③Tab 与空格差异经归一化命中 → 该元素 `old_text` 含磁盘上的 Tab（不是参数里的空格），`matched_with` 仍在；④从第 10 行起连续替换 3 行 → `start_line=10` 且 `old_text` 是三行以 `\n` 连接；⑤任何校验失败（空数组、空 `old_text`、重叠、多命中、未读过、stale）→ 响应里没有 `hunks` 键；⑥构造一份 `hunks` 序列化超过 1MB 的成功编辑（用**一处**大替换：文件约 1MB、`old_text` 与 `new_text` 各约 600KB，避免几十万次小命中）→ 响应有 `"hunks_omitted":"too large"`、没有 `hunks` 键、而磁盘上替换已生效。验收：构建后 `ctest` 全绿；把行号计算改成固定 0 时用例 ①④ 变红，去掉体积封顶时用例 ⑥ 变红。

## 4. Dart 数据层

- [x] 4.1 在 `lib/models/tool_call_activity.dart` 增加 `EditHunk {start_line, old_text, new_text}` 与两个可空字段：`hunks`（列表）与 `hunksOmitted`（响应里 `hunks_omitted` 的值，Dart 侧取同名含义）；`toJson` 只在非空时写出，`fromJson` 缺省为 null，`copyWith` 支持替换。验收：`test/unit/tool_call_activity_test.dart` 里四条断言成立（见 4.2）。
- [x] 4.2 在 `test/unit/tool_call_activity_test.dart` 增加：①带两个 hunk 往返序列化后每个字段相同；②不含 `hunks` 的老 JSON 反序列化成功且 `hunks` 为 null；③`hunks` 为 null 时 `toJson` 输出里没有 `hunks` 键；④省略标记往返保持。验收：`flutter test test/unit/tool_call_activity_test.dart` 全绿；删掉 `hunks` 的序列化分支时用例 ① 变红，删掉省略标记的序列化时用例 ④ 变红。
- [x] 4.3 在 `lib/services/context_estimator.dart` 里，估算 `toolCallsJson` 前剔除 `hunks` 与省略标记；并在 `lib/models/context_breakdown.dart` 的 `fromTimeline` 累加原文段 `jsonEncode` 前做同样的剔除。验收：`test/unit/context_estimator_test.dart` 加一条——同一份消息，`toolCallsJson` 里带 200 行 `hunks` 与不带时 `estimateConversation` 结果相等；`test/unit/context_breakdown_test.dart` 加一条——同一段原文带与不带 `hunks` 时 `rawTokens` 相等。把任一剔除逻辑删掉时对应用例变红。
- [x] 4.4 在 `test/integration/tool_persistence_test.dart` 增加：把带两个 hunk 的 `edit_file` 活动存进消息再读回，`ToolCallActivity.fromJson` 出来的 `hunks` 与存之前逐字段相同，且卡片渲染时仍出现 `第 N 行`（覆盖"重开会话还能看到 diff"）。验收：`flutter test test/integration/tool_persistence_test.dart` 全绿；把 `toJson` 里的 `hunks` 去掉时该用例变红。

## 5. Dart 执行层

- [x] 5.1 在 `lib/main.dart` 改两处：①`_executeTool` 的 `edit_file` 分支里保留 sidecar 返回的 `hunks` 与省略标记，并按「`Edited <路径> (N replacements)` + 可选 ` — matched with …` + ` — 第 X、Y 行`」拼出模型可见文本（`hunks` 缺失或省略时整句与改动前逐字一致；行号清单超过 8000 字符（复用 `kToolResultElisionThreshold`）时只列前若干条并写 `共 N 处改动，其余行号见卡片`）；②执行循环里更新 `ToolCallActivity` 的 `copyWith` 调用处，把 `hunks` 与省略标记解析进去。错误路径不改写 sidecar 的英文 `error`。验收：`test/integration/tool_call_test.dart` 里断言这些输入的解析结果与文案。
- [x] 5.2 让实时请求体与重放一致：`lib/main.dart` 里放进 `assistantBlocks` 的 tool_use 块改成只含 `type/id/name/input` 的浅拷贝（不再直接 `addAll(turnToolCalls)` 持有引用），使 `tc.addAll(activity.toJson())` 之后写进活动对象的 `hunks`/`result`/`resultPreview` 不会被带进下一发请求。验收：`test/integration/message_flow_test.dart` 或 `tool_call_test.dart` 里加一条——一个工具轮里 `edit_file` 返回 hunks 后，第二发请求序列化出来的 tool_use 块只有四个键；把浅拷贝改回 `addAll` 时该用例变红。
- [x] 5.3 增加 Dart 侧用例：①结果含两个 hunk → `activity.hunks` 两条且行号正确、模型可见文本为 `Edited <路径> (N replacements) — 第 12、40 行`；②`matched_with` 存在且带 hunk → 文本里 `— matched with …` 在 `— 第 7 行` 之前；③`{"ok":false,"code":"stale","error":"cannot edit \"a.txt\": file changed since it was read; read it again before editing"}` → 模型可见文本与这句英文**逐字相等**且卡片状态为 error；④省略标记的成功结果 → 文本与改动前逐字一致、不带行号；⑤没有 `hunks` 的成功结果 → 同样与改动前逐字一致；⑥行号超过 8000 字符的结果 → 文本里出现 `共 ` 与 `其余行号见卡片`，且不含上千个逗号分隔行号。验收：`flutter test test/integration/tool_call_test.dart` 全绿；把行号拼装删掉时用例 ① 变红，去掉 8000 字符上限时用例 ⑥ 变红。

## 6. 卡片 UI

- [x] 6.1 在 `lib/ui/tool_call_card.dart` 增加 diff 区块（渲染在展开的结果区里）：每处 hunk 先渲染 `第 N 行`，再把 `old_text` 按行加 `-` 前缀（红色）、`new_text` 按行加 `+` 前缀（绿色）。验收：`test/widget/tool_call_card_test.dart` 展开后断言——每个 hunk 都有一条 `第 N 行`、被删行以 `-` 开头、新增行以 `+` 开头、三个 hunk（行号 3/40/88）在渲染顺序上依次出现。
- [x] 6.2 实现 12 行显示上限（用户在本次对话的提问中从 8/12/16/不设上限里选定 12）：在**展开的**结果区里摊平所有 hunk 的内容行只显示前 12 行，其余折叠成 `还有 N 行未显示，点击展开`（N 为精确剩余行数，行号行不计入上限）；点击后显示全部并隐藏该标记；折叠态不渲染 diff、仍显示原来的一句话结果。验收：`test/widget/tool_call_card_test.dart` 四条用例——展开后 4 行不出现标记、展开后 30 行出现"还有 18 行未显示"、点击后 30 行全在且标记消失、折叠态不出现 `第 N 行`。
- [x] 6.3 改标题行：`edit_file` 与 `write_file` 只显示 `工具名(路径)`，不再拼接完整参数；`edit_file` 有 `hunks` 时尾部加 `+N/−M`（N/M 为所有 hunk 的新增/删除行数之和），`hunks` 为空或省略时不显示。验收：`test/widget/tool_call_card_test.dart` 断言标题里不含替换文本、含 `edit_file(<路径>)`、含 `+3/−1`（折叠态也要能看到）、省略时标题没有 `+`/`−` 计数；其它工具标题不变。
- [x] 6.4 回退与省略可见：`hunks` 为空的老记录仍显示原来的字符串结果（含折叠/展开交互），不得出现空 diff 区块；响应带省略标记时，结果区显示 `diff 未显示：改动过大（N 处改动）`，N 取 `replacements`。验收：`test/widget/tool_call_card_test.dart` 两条用例——无 hunks 时展开后无 `第 N 行`、原结果文本可见、标题无计数；省略时出现那句提示且无空区块。

## 7. 端到端

- [x] 7.1 在 `test/integration/real_sidecar_test.dart` 增加真实 DLL 用例：建临时工作区 → `read_file` 读 → `edit_file` 改 → 断言结果含 `hunks` 且行号正确、磁盘内容正确；随后用 Dart 直接改该文件（改变大小），再 `edit_file` → 断言 `code == "stale"` 且文件未被改。验收：`powershell -NoProfile -File scripts\sync_sidecar_dll.ps1`（先构建）后 `flutter test test/integration/real_sidecar_test.dart` 全绿；把守卫去掉时 stale 那条变红。
- [x] 7.2 让 live 用例适应守卫：`integration_test/live_file_tools_test.dart` 的 Test 1（grep 找 TODO → edit 替换）、Test 2（批量 edits）与 Test 3（唯一命中拒绝/自愈）三个用例的夹具都是 Dart 直接写盘、不经 sidecar，因此都不在观测表里；新守卫下第一次 `edit_file` 会拿到 `not_observed`。三个用例的提示词都要改成先 `read_file` 再改（或在断言里显式允许一次 `not_observed` 后重试成功）。验收：`flutter test --tags live --run-skipped integration_test/live_file_tools_test.dart -d windows` 通过，并 `read_image` 读该用例产出的截图做视觉验收。

## 8. 文档同步

- [x] 8.1 更新 `Docs/user-guide/tools-file.md`：`edit_file` 一节写明「必须先读再改」（没读过就改会看到 `read the file first` 那句英文错误）、「文件在读过之后被外部改过会被拒绝」（`file changed since it was read; read it again before editing` 及恢复办法）、卡片上 diff 的读法（红 `-` 是原来的行、绿 `+` 是新的行、超过 12 行会折叠并写明还有多少行，折叠态只能从标题的 `+N/−M` 看出规模）、`write_file` 没有这层保护。验收：文档里引用的每段英文（**不含路径插值的那一截**）都能在 `sidecar/src/tools.cpp` 里逐字 grep 到；文档正文不出现 `not_observed`／`stale` 这两个 JSON 字段名；`flutter test test/unit/user_docs_test.dart` 全绿。
- [x] 8.2 在 `Docs/user-guide/tools-file.md` 的"限制"一节补三条：①外部程序若只改内容、既不改修改时间也不改大小，版本检查发现不了；②`write_file` 覆盖文件不受这层检查保护；③"读过一次"按整个文件算——`read_file` 被 2000 行截断时，没读到的那部分也能被改。验收：这一节里同时 grep 到 `write_file`、`修改时间`、`2000`，且这三句没有使用反引号包住的全小写英文词（避免触发 `test/unit/user_docs_test.dart` 的代码名校验）。

## 9. 顺带修：read_file 的截断标记

- [x] 9.1 `sidecar/src/tools.cpp` 的 `read_file` 里，截断判定从"只有默认第一页"改成"只要返回的末行小于文件总行数就置 `truncated` 并给出续读参数"（复用现有那句 `File has N lines, showing A-B. To continue reading, call read_file with {...}`，不新造数字）。验收：新增用例——对一份 8000 行文件用 `limit=5000` 读取，响应里必须同时出现 `truncated` 与可照抄的续读参数；把判据改回 `offset == 1 && limit == 2000` 时该用例变红。

## 10. 收尾验证

- [x] 10.1 `flutter analyze` 通过，改动文件无新增问题。验收：贴出命令与输出，并与 0.1 的基线问题清单比对。
- [x] 10.2 `powershell -NoProfile -File scripts\sync_sidecar_dll.ps1`（先构建）后 `flutter test` 全量通过。验收：贴出通过数、失败数，并与 0.1 基线比对"没有新增失败"。
- [x] 10.3 `cmake --build sidecar/build/windows --config Debug` 后 `ctest --test-dir sidecar/build/windows -C Debug` 全绿。验收：贴出用例数与失败数。
- [x] 10.4 整套冒烟用 `"C:\Program Files\Git\bin\bash.exe" test/smoke/run_all.sh`（不是 `run.bat`：它做的是构建/校验产物/同步 DLL/单文件测试/启动五步，与冒烟不是一回事，且第 5 步会 `pause` 挂住）。验收：贴出五个步骤各自结论，并与 0.1 基线比对——判定标准是"没有新增失败"，不是"五步全过"。

## 11. 开工基线（0.1 的实测记录，2026-10-20 23:3x）

- `git status --short`：` M CLAUDE.md`（10-15 起就存在）+ `?? openspec/changes/harden-edit-tool-and-diff-card/`；`lib/main.dart`、`lib/models/context_breakdown.dart` 均干净（`git status --short lib/main.dart lib/models/context_breakdown.dart` 无输出）。
- `flutter test`：`+383: All tests passed!`（exit=0，0 失败）。
- `bash test/smoke/run_all.sh`：Build PASS、Analyze FAIL、Checkpoints FAIL、Launch & Verify PASS、Visual Regression FAIL → `Total: 2 passed, 3 failed`（exit=1）。
- `sidecar_tests.exe` 全量：307 例 / 306 通过；唯一失败是 live 网络用例 `Rate guard: rapid-fire 5 consecutive ZhipuAI searches`（单独跑 5/5 通过，整跑时因机器负载失败），与本次改动无关。后续 C++ 验收按"相对这份基线没有新增失败"判定。

## 12. 收尾实测（对应 10.x）

- `flutter analyze`：改动前后都是 **170** 条（`git stash` 取出改动前源码后重跑得到同一数），且这 170 条里**没有一条**落在我改过的五个文件（`lib/main.dart`、`lib/ui/tool_call_card.dart`、`lib/models/tool_call_activity.dart`、`lib/services/context_estimator.dart`、`lib/models/context_breakdown.dart`）。
- `flutter test`：**407 全过**（基线 383，新增 24 条）。
- `ctest`：315 例 / 314 通过，唯一失败仍是基线那条 `[live]` 网络用例；排除 live 后 **311 例全过（4117 条断言）**。
- 冒烟：五步结论与基线**逐条相同**（Build PASS、Analyze FAIL、Checkpoints FAIL、Launch PASS、Visual FAIL）。
- 冒烟里 Checkpoints 的失败点是 `test/checkpoint_4_verify.dart` 在 `[A] PASS` 之后 0xC0000005 崩溃。**已证明与本次改动无关**：把本次改动 `git stash` 掉、用改动前源码重建 `sidecar.dll` 再跑，同样在同一处崩溃（exit=-1073741819）。
