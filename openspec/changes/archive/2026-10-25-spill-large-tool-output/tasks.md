## 1. 先定红

- [x] 1.1 `test/unit/spill_envelope_test.dart`：先写用例断言「超限时结果信封含 `total_bytes` / `omitted_bytes` / `head` / `tail` / `ref`，且 `omitted_bytes + 内联字节数 == total_bytes`」，**并额外断言 `total_bytes` 等于测试命令实际输出的字节数**（不只让信封内部自洽）。判据：实现不存在时该用例必须红；把 `total_bytes` 写小 100 后必须仍红。
- [x] 1.2 `test/integration/read_spill_roundtrip_test.dart`：先写用例断言「对一份 200000 字节的 spill 引用取 `(offset: 50000, limit: 1000)`，返回内容与文件对应区间逐字节相同」。判据：`read_spill` 不存在时该用例必须红。
- [x] 1.3 `sidecar/test/command_tool_test.cpp`（**已存在于 `sidecar/test/`，文件名就是它**）：在该文件里先写 `[spill]` 用例，断言「输出 200000 字节、**第 1 行**是 `error C2065`、最后一行是 `Build FAILED.` ⇒ 两者都在给模型的那份里」。判据：跑 `sidecar_tests.exe "[spill]"` 必须红。

## 2. C++：落盘 + 切分 + 导出

- [x] 2.1 新增 spill 写入：路径 `~/.aliasagent/spill/<会话 id>/<6 位序号>-<流>.txt`（**每条流一个文件**，例如 `000001-stdout.txt`），**原子写**（先 `*.tmp` 再改名，失败清临时文件；Windows 上用 `MoveFileExW(REPLACE_EXISTING)`，因为 CRT 的 `rename` 拒绝覆盖已有文件）。判据：`sidecar/test/spill_write_test.cpp` 断言写完的文件与输入逐字节相同；把改名换成直接写目标文件后，注入中途失败的那条用例必须红（已实测：目标文件被截空，`"" != "OLD-CONTENT"`）。
- [x] 2.2 **把新测试文件接进构建**：在 `sidecar/CMakeLists.txt` 的 `sidecar_tests` 显式源文件清单里加 `test/spill_write_test.cpp`（该清单不用 GLOB，不登记就编不进去）。判据：`sidecar_tests.exe --list-tests` 输出里能 grep 到 `[spill]` 标签的用例名。
- [x] 2.3 新增 UTF-8 安全切分：按码点边界取头 `preview_chars` 个字符与尾 `preview_chars` 个字符。判据：同文件断言切出的头尾各自是合法 UTF-8（严格模式校验），中文输入不会被切成半个字。
- [x] 2.4 `run_command` 改用新信封：完整输出先落盘，再按 `preview_chars × 2` 决定"全文内联"还是"头尾 + 引用"；**删掉"只截尾部 + 写系统临时文件"的旧逻辑**。判据：1.3 的用例转绿；另断言信封里没有任何指向系统临时目录的路径。
- [x] 2.5 导出 `read_spill(const char* request_json)`：成功 `{"ok":true,"text":…,"bytes_read":N,"total_bytes":M}`；失败五种（不在 spill 根内 / 引用不存在 / 越界 / 切点多字节字符中间 / 根目录不可读）各有不同错误文本。判据：`spill_write_test.cpp` 里五条负例各自断言错误文本互不相同。
- [x] 2.6 **`ref` 必须解析到 spill 根目录之内**：先 `canonical` 再比前缀，越界直接拒。判据：把 `~/.aliasagent/config.json` 当 `ref` 传入，必须 `ok:false` 且错误文本与"引用不存在"不同；把前缀检查注释掉后该用例必须红。

## 3. Dart：工具与配置

- [x] 3.1 `lib/services/sidecar_bridge.dart` 加 `readSpill(String requestJson)`；`lib/main.dart` 的 `_toolDefs` 加 `read_spill` 工具定义；**并在 `_executeTool` 的 `switch (name)` 里加 `case 'read_spill'`**（不加就落到 `default` 返回 `Unknown tool`）。判据：`test/integration/read_spill_roundtrip_test.dart` 转绿；另加一条用例走**模型路径**（`ChatScreen` 发起一次带 `read_spill` 的 tool_use），断言拿到的不是 `Unknown tool`。
- [x] 3.2 **确认新信封不会被通用截断掐掉引用段**：`lib/main.dart` 的 `_elideOversizedToolResult` 阈值是 `kToolResultElisionThreshold`（= `searchTextElisionThreshold` = 8000，见 `lib/services/search_text_assembly.dart`），而 `preview_chars` 可配。判据：`test/unit/spill_envelope_test.dart` 加一条「把 `preview_chars` 配到 4000（头尾合计 8000+）时，结果里的 `ref` 字段仍然完整可见」——把 `_elideOversizedToolResult` 对 run_command 的再取入口改坏后该条必须红。
- [x] 3.3 配置项 `spill.preview_chars`（默认 1000）：读配置、缺省回落 1000，并在 `Docs/user-guide/configuration.md` 的配置键表里出现。判据：`test/unit/spill_config_test.dart` 断言读到配置值、缺省用 1000；并断言文档里 grep 得到该键。

## 4. 写盘失败可见

- [x] 4.1 输出不超过预览阈值时写盘失败 ⇒ 直接内联全文，不报错。判据：`sidecar/test/spill_write_test.cpp` 注入不可写目录，断言 `ok:true` 且全文在内联里。
- [x] 4.2 输出超过预览阈值时写盘失败 ⇒ `ok:false` 且含写盘失败原因。判据：同文件注入不可写目录，断言 `ok:false` 且 `error` 里含目录与失败原因，且不返回任何内容片段。

## 5. 清理与保留

- [x] 5.1 删除会话时连带删除 `~/.aliasagent/spill/<会话 id>/`。判据：`test/unit/spill_cleanup_test.dart` 断言删会话后该目录不存在、别的会话目录仍在。
- [x] 5.2 文档写明"spill 随会话删除、不设时间上限"（不发明保留天数）。判据：`Docs/user-guide/tools-command.md` 里 grep 得到"随会话删除"。

## 6. 旧规范与旧用例的处置（这一步不做，两份规范会同时成立）

- [x] 6.1 新增 `specs/command-tool/spec.md` 的 **MODIFIED** delta：把现有「输出有界、只保留尾部、截断可见」那条改成"完整输出先落盘 + 头尾预览 + 引用"，并交代 `command_max_output_chars` / `command_output_full_chars` 两个配置键的去留。判据：`openspec validate spill-large-tool-output` 通过，且该 delta 的 Requirement 标题与主规范逐字一致（MODIFIED 要求标题匹配）。
- [x] 6.2 改 `sidecar/test/command_tool_test.cpp` 里按旧行为写的三条断言：`HEAD-MARKER` 必须存在（不再"头部丢掉"）、`full_output_paths` 不再出现、未超限时也不写临时文件。判据：改完跑 `sidecar_tests.exe "[command_tool]"` 全绿；改之前必须红（红在"头部丢掉"那条）。
- [x] 6.3 改 `Docs/user-guide/tools-command.md` 的旧表（四个配置键、`[output truncated; full output: <路径>]` 文案）。判据：该文件里 grep 不到旧文案，且能 grep 到"头尾预览"与"随会话删除"。

## 7. 文档与收尾

- [x] 7.1 `Docs/user-guide/tools-command.md` 补一节：长输出怎么交付、头尾各留多少、怎么用 `read_spill` 读回、写盘失败会看到什么。判据：`test/unit/user_docs_test.dart` 的「界面文案：」机制覆盖到新增界面文案；文档里的 `read_spill` 参数名与工具定义一致（grep 得到）。
- [x] 7.2 `Docs/user-guide/configuration.md` 补 `spill.preview_chars`（默认 1000）。判据：配置键表里 grep 得到该键，且与 `lib` 里读取的键名完全一致。
- [x] 7.3 `flutter analyze` 改动文件不新增问题。判据：与改动前数字相同，且本轮文件命中 0 条。
- [x] 7.4 全量 `flutter test` 全绿。判据：`All tests passed!`，通过数不低于改动前。
- [x] 7.5 C++ 两层验证：`cmake --build sidecar/build/windows --config Debug` + `sidecar_tests.exe`。判据：构建 exit 0；`[spill]` 与 `[command_tool]` 两个 tag 全绿；已知的联网 `Rate guard` 用例失败不算本变更引入（基线 1 条，见归档 change `2026-10-25-add-image-input` 的 tasks 第 17 组）。
- [x] 7.6 真机验收：`integration_test/live_spill_output_test.dart`（**新建，点名路径**）跑一条真实的失败构建命令，断言头部那条 error 出现在结果里，并用 `read_spill` 把中间段读回一次。判据：`flutter test --tags live --run-skipped integration_test/live_spill_output_test.dart -d windows` 通过，并把"头部 error"与"读回的中间段"两段输出贴进本条记录。

  **实测记录（2026-10-25，命令 `$ErrorActionPreference = "Continue"; cmake -S <tmp> -B <tmp>\build *> $null; cmake --build <tmp>\build --config Debug -- /nologo /v:q; Write-Output "BUILD-TAIL-MARKER"`）**：
  - 信封：`ref=C:\Users\76956\.aliasagent\spill\live-spill\000001-stdout.txt total=24997 omitted=22883`；给模型的那份 2166 字符、`truncated.stdout=true`。
  - **头部 error**：`...\bad.cpp(2,26): error C2065: “undeclared_symbol_at_line_1”: 未声明的标识符 [...\build\bad.vcxproj]`
  - **读回的中间段**（`read_spill(offset=1018, limit=2000)` → `ok=true bytes_read=2000 total_bytes=24997`；偏移按**字节**算 = `total 24997 − tail 1096 − omitted 22883`，11.3 修正后的读数）：`...asagent_live_spill_a6b7bc21\bad.cpp(3,26): error C2065: “undeclared_symbol_at_line_2”: 未声明的标识符 [...\build\bad.vcxproj]`
  - 第一次跑是**红**的：不加 `/nologo /v:q` 时 MSBuild 的横幅占满了头部 1000 字符，第一条 error 落到被省略的中段 —— 这条用例因此真的能失败。
  - **对抗验证发现的偏差（已登记为 11.3）**：这一行当时写的 `offset=1000` 是**手写**的数字，而用例里实际取的是 `head.length`（Dart 的 UTF-16 长度）。头部含中文时字节数大于字符数，所以那次读回的起点其实落在**头部之内**，不是省略段的开头 —— 记录里"读回了被省略的中间段"这个说法不准确。修法见 11.3。

## 10. 自查出来的四个问题（补登记，逐条做掉）

> 来源：apply 收尾时按"发现了问题就必须变成任务"自查。前两条是**真缺陷**（磁盘泄漏），后两条是**工件自相矛盾**与**脆弱修法**。

- [x] 10.1 **无主的 spill 目录要能清掉**。会话 id 为空时（后台折叠 / 未选会话）输出落进 `~/.aliasagent/spill/no-session/`，而"删会话"只删 `<会话 id>/` —— 这个目录只增不减。改法：`lib/services/spill_paths.dart` 加 `cleanOrphanSpillDirs()`（删掉 `no-session` 与 `_it_*` 这类无主目录），在应用启动初始化时调用一次。判据：`test/unit/spill_cleanup_test.dart` 加一条 —— 先造 `no-session` 与一个真实 UUID 目录，调清理后 `no-session` 不存在、真实目录仍在；把清理函数改成空实现后该条必须红。
- [x] 10.2 **单元测试不许往真实 spill 根留垃圾**。`test/unit/spill_envelope_test.dart` 每条用例都调 `run_command` 且不传 `spill_session`，于是每次都往真实 `~/.aliasagent/spill/no-session/` 写文件、且从不清理。改法：用例统一传 `spill_session: '_it_envelope'`，`tearDownAll` 删掉该目录。判据：同文件加一条 —— 断言本次跑完 `<根>/_it_envelope` 不存在、`<根>/no-session` 里没有本次新增的文件（用文件数前后对照）；把 `spill_session` 去掉后该条必须红。
- [x] 10.3 **design / proposal 与 tasks 口径一致**：`design.md` 的迁移顺序里写着 `web_fetch` 的 2000 字硬切"必须改"，但本期 tasks 只覆盖 `run_command` —— 两处说法不一致，读工件的人会以为这期就该改。改法：把 design / proposal 里那两处改成"本期只改 `run_command`；`web_fetch` 的硬切**另开一个 change**"，并写明它现在仍然是缺陷（不假装修好了）。判据：`grep -c '必须改' design.md` 命中里不再有 `web_fetch` 那一处；`openspec validate spill-large-tool-output` 仍 valid。
- [x] 10.4 **把"正文里有没有 spill 引用"的字符串嗅探收成一处并加守卫**。9.1 在 `elideOversizedToolResult` 里用 `body.contains('[spill refs:')` 判断，文案一改就静默失效。改法：抽成 `ChatScreenState.bodyHasSpillRefs(String body)`（常量标记只写一次），并加单测覆盖"有 / 没有"两侧。判据：`test/unit/spill_envelope_test.dart` 加一条断言 —— 真拼装出的正文 `bodyHasSpillRefs == true`、随便一段文字 `== false`；把标记常量改掉后该条必须红。

## 8. 本轮改过的既有断言（改前 → 改后对照）


> 依据：`specs/command-tool` 的两条 MODIFIED delta、`specs/command-tool-tests` 的一条 MODIFIED delta，与 `specs/tool-output-spill`（两个旧配置键废弃、头尾预览取代"只留尾部"）。
>
> **准确说法（对抗验证后改正）**：这些改动**不是每一处**都多了一条反向断言 —— 只有前三条（C++ 超长输出、C++ 未超限、请求体断言）真的加了"旧键/旧文案不许回来"的反向断言；后四条是"把旧行为换成新行为"的等价改写，判据强度不变（不比旧的松，但也没有加严）。初稿写成"每一处都多了一条"，与文件实际不符。

| 文件 | 改前 | 改后 |
|---|---|---|
| `sidecar/test/command_tool_test.cpp`「超长输出…」 | `HEAD-MARKER` 必须 **不存在**（头部丢掉）、`full_output_paths` 必须有、临时目录必须多一个文件 | `HEAD-MARKER` 必须**存在**、`full_output_paths` 不许出现、必须有 `spill.stdout.ref` 且文件里两头标记都在、临时目录**不许**新增文件 |
| 同上「未超限…」 | 断言"不写文件" | 名字改成"未超限时也落盘"，并且：`spill.stdout.omitted_bytes == 0`、引用文件存在 |
| 同上「超过写文件上限…」（删除） | 用 `full_output_chars=1500` 验"超上限不落文件" | 该行为随系统临时文件一起被删；写盘失败的两种处置改由 `spill_write_test.cpp` 的 4.1 / 4.2 覆盖 |
| 同上「字符上限低于下限被抬到下限」 | `max_output_chars: 200` → 抬到 1000 | 改成 `preview_chars: 0` → 回落 1000，并断言 `spill.stdout.head` 的字节数正好 1000 |
| `test/integration/command_tool_test.dart` 覆盖 8 | 同上（`max_output_chars: 1000`，`stdout.length <= 1000`） | `preview_chars: 500` / 1000 两档，断言正文 1000 ≤ len < 1500、且 `head` 长度分别是 500 / 1000 |
| `test/integration/tool_call_test.dart` 请求体断言 | 请求里必须有 `max_output_chars:1234`、`full_output_chars:2000000` | 请求里**不许**有这两个键；必须有 `preview_chars:1000` 与 `spill_session` |
| `test/unit/agent_type_config_command_test.dart` | 四个键的解析/回落/写回（含 8000、2000000、抬到 1000、50000） | 只剩两个超时键；新增一条"两个输出上限键读进来不报错、**不再写回**" |
| `test/integration/startup_tool_readiness_test.dart` | 未就绪时 9 个本地工具、就绪后 11 个 | 10 / 12（多了本地工具 `read_spill`；断言里的工具名清单也加上了它） |

## 9. 收尾时自己发现的两处粗糙 + 一条漏登记的实现

> 来源：apply 完成后自查。前两条是**已知粗糙**（当时只写进了对话、没落成任务 —— 违反"发现即入工件"，本条就是补登记）；第三条是实施 2.4 时被崩溃逼出来的修复，代码先落地了，工件里没登记，一并补上。

- [x] 9.1 **通用截断的尾注不许对 `run_command` 说"无法自动再取"**。现状：结果超过 `kToolResultElisionThreshold` 被通用截断时，`elideOversizedToolResult` 拼的尾注是「本篇无法自动再取，请重新给出地址后再试」，而它上面一行恰好是 `[spill refs: … read_spill(ref, offset, limit)]` —— 自相矛盾。改法：正文里出现 `[spill refs:` 时，尾注改成"用 read_spill 按 ref 读回"。判据：`test/unit/spill_envelope_test.dart` 加一条 —— 拼装后用 `preview_chars=4000` 逼出通用截断，断言最终文本里含 `read_spill`、**不含**「无法自动再取」；把尾注分支改回旧的固定文案后该条必须红。
- [x] 9.2 **两条流同时远超预览阈值**（`command-tool` 规范里的场景，目前只测了单条流）。判据两层：① `sidecar/test/command_tool_test.cpp` 的 `[spill]` 加一条 —— stdout 与 stderr 各写 200000 字节，断言 `truncated.stdout` 与 `truncated.stderr` 都为真、两边的 `spill` 信封都在、两个 ref 指向不同文件且文件大小都为 200000；② `test/unit/spill_envelope_test.dart` 加一条 —— 用真实命令产出双流信封，走 `composeCommandResultText` + `elideOversizedToolResult`，断言拼装结果没超过阈值、两个 ref 都还在。

  **偏差（对抗验证后补记）**：② 里"断言拼装结果没超过阈值"这半句**当时没做到** —— 那条用例只在 `print` 里打长度，`expect` 里只有"两个 ref 都在"。① 是完整做到的（113 断言那轮）。补断言登记为 11.2。
- [x] 9.3 **登记 `std::rename` 覆盖语义的修复与守卫**（实施 2.4 时被 `[spill]` 的 nlohmann 断言崩溃逼出来的真 bug：Windows 的 CRT `rename` 拒绝覆盖已有文件，应用重启后调用序号从 1 重来就撞车，大输出直接报写盘失败）。改法：改名走 `MoveFileExW(MOVEFILE_REPLACE_EXISTING)`（POSIX 仍用 `rename`）。判据：`sidecar/test/spill_write_test.cpp` 的「同一序号重复写会覆盖而不是失败」—— 复位序号后连写两次，断言两次 `ok`、路径相同、文件内容是第二次的；把改名换回 `std::rename` 后该条必须红（实测已红过：`ok=false`）。

## 11. 对抗验证第二轮查出来的四件事（工件已改，这四条要动代码/文档）

> 来源：`workflow-8` 的五面审查（25 条 claim，25 条复核判定 `verified`）。前 11 条属于工件口径问题，已在同轮改掉（见第 12 节的处置表）；下面四条**落到代码或用户文档**，必须单独做，不许算进"已修"。

- [x] 11.1 **两个废弃键的告警要有测试**。`specs/command-tool` 有三处要求"读到 `command_max_output_chars` / `command_output_full_chars` 时 SHALL 打一行废弃告警、不许静默忽略"，但 `tasks.md` 全文没有一条管这件事，也没有任何用例断言它（代码里 `agent_type_config.dart` 的 `_warnDeprecated` 是有的）。改法：在 `test/unit/agent_type_config_command_test.dart` 里加一条，捕获 `debugPrint` 输出（用 `debugPrint = (String? m, {int? wrapWidth}) {...}` 换掉全局回调），断言含两个键名之一并含「已废弃」。判据：把 `_warnDeprecated` 的 `debugPrint` 删掉后该条必须红。
- [x] 11.2 **9.2 的 Dart 用例补一条长度断言**。任务 9.2 的 ② 声称"断言拼装结果没超过阈值"，但那条用例只在 `print` 里打长度、没有 `expect`。改法：加 `expect(elided.length, lessThanOrEqualTo(ChatScreenState.kToolResultElisionThreshold + 200), ...)`（留出尾注本身的空间），并断言两个 ref 都在。判据：把 `composeCommandResultText` 里"引用放最后"改成"放中间"后该条必须红（引用会被砍掉）。
- [x] 11.3 **live 用例的 `read_spill` 偏移改成按字节算**。现在写的是 `offset = head.length`（Dart UTF-16 长度），头部含中文时字节数 > 字符数，起点会落在头部之内 —— 7.6 的记录也因此写错（说"读回了被省略的中间段"）。改法：用 `utf8.encode(head).length` 作偏移，并把 7.6 记录按新读数重贴一次。判据：用例里断言"读回的第一行不是头部末行"（或断言 `offset` 等于 `total - tailBytes - omitted` 那侧的关系）；把偏移换回 `head.length` 后，头部含中文的那次必须红。
- [x] 11.4 **用户文档补两条**：① 内联预览里换行被归一成 LF、非法字节被换成 U+FFFD（spill 文件里是原始字节）；② 应用启动时会清掉 `~/.aliasagent/spill/no-session/` 这类无主目录。判据：`Docs/user-guide/tools-command.md` 里 grep 得到「LF」与「no-session」；把这两个行为删掉（或改掉）后，`test/unit/user_docs_test.dart` 不红也算不落地 —— 所以另加一条 grep 断言进 `spill_config_test.dart` 那类用例。



