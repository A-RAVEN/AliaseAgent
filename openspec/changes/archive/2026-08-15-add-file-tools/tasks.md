## 1. C++ edit_file 批量重构

- [x] 1.1 重写 `tools::edit_file`：解析必填 `edits` 数组（1..N 对 `{old_text, new_text, replace_all?}`），移除顶层 `old_text`/`new_text`/`replace_all`；空/缺失数组返回 `{"ok":false,"error":"edits must contain at least one replacement"}`
- [x] 1.2 逐对校验：空 `old_text` 立即拒绝（`{"ok":false,"error":"old_text must not be empty"}`，防 find 死循环）；非空但缺失 → 整体失败（错误信息指出失败的对序号与原因），零改动
- [x] 1.3 实现验证阶段：所有替换对在**原始内容**上定位；任一 old_text 缺失或非 replace_all 多匹配 → 整体失败，零改动
- [x] 1.4 实现重叠检测：任意两个替换对的命中区间（原始内容字节区间）重叠 → `{"ok":false,"error":"edits overlap"}`，零改动
- [x] 1.5 实现倒序应用：验证全过后按**每个命中位置（per-hit）的原始内容字节偏移全局倒序**写回（非按对、非按数组顺序；replace_all 对的所有命中位置都参与排序）——防止 per-pair 排序在 replace_all 跨区间时写错文件（第二轮 F9 修正）
- [x] 1.6 per-edit `replace_all` 独立语义（单对全部出现替换）；三层匹配（exact → normalized → diagnostic）逐对复用；命中区间坐标始终基于原始内容
- [x] 1.7 既有保护保留：1MB/二进制/目录拒绝逻辑不变（整个请求级别）；`edits` 数组长度上限（设计值 100，超出返回错误）
- [x] 1.8 更新 edit_file 的 C++ 单测：单替换、多替换、任一失败全失败、多匹配拒绝、重叠拒绝、per-edit replace_all、空数组、**空 old_text 拒绝**、二进制/大文件拒绝、**数组顺序≠位置顺序（先写位置靠后的对，后写位置靠前的对，内容正确）**、**replace_all 对的某次命中位于另一对命中区间之后（per-hit 倒序正确性）**、edits 长度超限——全部改新 schema 并新增批量场景

## 2. C++ 子进程骨架抽提

- [x] 2.1 从 `web_fetch.cpp` 抽提通用子进程执行函数（Windows CreateProcessA + Job Object + 管道 + 100ms 轮询 + 超时终止；POSIX fork + select）到独立文件（如 `subprocess.h/.cpp`），参数为 argv 列表 + 超时秒数 + stdout/stderr 捕获；**新增 argv→命令行拼接逻辑**（CreateProcess 引号/空格转义规则；web_fetch 现骨架只拼 `python "path"`，无通用转义——第二轮 F16）
- [x] 2.2 迁移 `run_crawl4ai_subprocess` 使用抽提后的骨架，保持行为不变（web_fetch 测试全绿）
- [x] 2.3 新增子进程命令行转义的 C++ 单测：参数含空格、双引号、反斜杠时的拼接与还原正确（rg 场景：pattern 含 `"` 与空格）

## 3. C++ glob_file 实现

- [x] 3.1 实现 `tools::glob_file`：定位 rg.exe（复用 `web_fetch.cpp::resolve_script_path()` 模式探测 DLL 相对位置 + CWD 相对位置，无 PATH 兜底；Linux/macOS 追加 PATH 探测），构造 `rg --files --no-require-git -g <pattern> <workspace_root>`（root 恒为 workspace 根，无 root 入参；`--no-require-git` 保证 .gitignore 在非 git 仓库下仍生效）
- [x] 3.2 输出处理：路径去根化为相对 workspace 根（边界检查见 design D3）；截断到 `max_results`（默认 200）——**多读一条确认截断**（总量恰为 max_results 时不报 truncated，防误报）；截断时响应含 `"truncated":true`；rg 缺失时返回明确错误（安装指引）
- [x] 3.3 glob 字符集校验：允许 `A-Za-z0-9*?.,_/-[]{}!`（含 `,`——alternatives `{a,b}` 语法需要），拒绝 `..`（路径穿越）与绝对路径（`/` 开头或盘符）；非法返回错误
- [x] 3.4 超时接线：glob_file 子进程执行传 30s 超时，超时终止并返回 `{"ok":false}` 超时错误
- [x] 3.5 C++ 单测：扩展名递归（`**`）、`-g foo` 不匹配 `foo/bar`（man page 反例）、`?` 单字符、`!` 取反、截断标记（含**恰好 max_results 不截断**）、**30s 超时**、rg 缺失错误、路径穿越/绝对路径拒绝、**文件名内 `..` 不误拒（`a..b.txt` 合法）**、**退出码 1 空结果成功**、**路径去根化（相对 root 输出）**——收尾轮 F10/F15 —— **全部通过（rg 15.2.0 实测，2026-08-15）；"30s 超时"接线由 subprocess 1s 超时机制测试（subprocess_test）覆盖 + SEARCH_TIMEOUT_SEC 常量，非 30s 工具级测试（诚实性修正）**

## 4. C++ grep_file 实现

- [x] 4.1 实现 `tools::grep_file`：构造 `rg --json -n --no-require-git --glob <glob> -- <pattern> <workspace_root>`（`--` 隔离 pattern；glob 可选；`--no-require-git` 保证 .gitignore 在非 git 仓库下仍生效——ripgrepDoc 第 8 节），`ignore_case` 映射 `-i`；`-m` 取 `max_results` 的放宽值（4×，防首文件独占偏置——第二轮 F14），全局截断按 D3 消息类型判定（非"到上限即杀"——收尾轮 F14）；`max_results` 默认 100
- [x] 4.2 解析 rg `--json` 输出：**宽容解析**（字段名 schema 未验证——同时接受 `path.text`/`path.bytes`，行号缺失降级为无行号），统一为 `path:line:text` 条目；**路径去根化**（绝对路径且位于 root 下时剥离 root 前缀，与 workspace-relative 承诺一致——第二轮 F13）；**截断判定**：收集满 max_results 后继续读，下一条是 match → `"truncated":true` 并终止子进程；下一条是 summary → 不截断（总量恰为 max_results——收尾轮 F6/F14）
- [x] 4.3 错误处理（收尾轮 F3/F9 修正）：**退出码三态**——0（有匹配）与 1（无匹配，返回空结果成功，**不得**按 web_fetch 骨架"非 0 即失败"处理）为成功；2（错误）→ **读 stderr 判别**：正则错误特征（如 "regex parse error"）→ `{"ok":false,"error":"invalid regex: ..."}`；其他错误 → `{"ok":false,"error":"search failed: <stderr summary>"}`；rg 缺失 → 安装指引；超时（30s）→ 终止子进程并返回超时错误
- [x] 4.4 实测 `--json` match 消息字段名并回填 `Docs/ripgrepDoc.md`（主循环维护职责，规则 8）—— **已回填（rg 15.2.0 实测，见 ripgrepDoc 1.1 节）**
- [x] 4.5 C++ 单测：符号查找、glob 过滤、ignore_case、`-` 开头 pattern 字面匹配（`--` 隔离）、非法正则（退出码 2）与**软错误（退出码 2 非正则）区分**（stderr 判别——已抽提 `classify_grep_regex_error` 直测）、截断标记（含**恰好 max_results 不截断**）、超时、rg 缺失、路径穿越拒绝、**pattern 含空格/引号的命令行转义**（第二轮 F16）、**路径去根化与宽容解析**（path.text/path.bytes/行号缺失降级——已抽提 `build_match_entry` 直测）—— **全部通过（rg 15.2.0 实测）；软错误与宽容解析以抽提函数单测覆盖，"超时"接线由 subprocess 机制测试覆盖（诚实性修正）**
- [x] 4.6 实测验证并记录：二进制文件跳过行为、`*`/`?`/`**` glob 语义（**含 `*`——收尾轮 F5**）、`--json` 输出路径形态（绝对/相对）与字段名——与 `Docs/ripgrepDoc.md` 对照，若与 spec 场景不符则**记录差异并汇报用户，未经用户明确允许不改 spec 验收标准**（CLAUDE.md 规则）—— **实测完成（见 ripgrepDoc 2.1/9.1 节）；所有 spec 场景与实测一致，无差异需上报**

## 5. FFI 导出与 Dart 集成

- [x] 5.1 `sidecar_api.cpp/.h` 导出 `glob_file`/`grep_file`（静态缓冲模式，参照 read_file）；`tools.h` 声明对应函数
- [x] 5.2 `sidecar_bridge.dart` 增加 `globFile`/`grepFile` 同步 FFI 调用（Interface + RealSidecar + FakeSidecar）
- [x] 5.3 `main.dart`：`edit_file` tool def 更新为 `edits` 数组 schema（描述明示批量语义、空 old_text 拒绝、上限）；新增 `glob_file`/`grep_file` tool def（无条件注册，描述含沙箱范围/glob 语法/结果上限；**grep_file 描述明示"glob 非空时绕过 gitignore 规则"**——收尾轮 F14）
- [x] 5.4 `_executeTool` 更新：`edit_file` 按 `edits` 打包请求；新增 `glob_file`/`grep_file` case（透传 pattern/glob/ignore_case/max_results；模型可见 content 为逐路径/`path:line:text` 格式）
- [x] 5.5 更新 Dart 侧 edit_file 相关测试（widget/integration，FakeSidecar）到新 schema（含空 old_text 场景）；新增 glob/grep 的 FakeSidecar stub 测试

## 6. 分发与文档

- [x] 6.1 确认 rg 分发方式（Windows: `tools/rg.exe` 用户放置；Linux/macOS: 包管理器），不提供自动下载脚本
- [x] 6.2 `Docs/ripgrepDoc.md` 已建立（2026-08-10，抓取自 man page）；实现后按 4.4 回填 `--json` 字段名实测结果 —— **已回填（1.1/2.1/9.1 节，2026-08-15 实测）**
- [x] 6.3 更新 tool def 相关测试（存在性断言）、DEBUGGING.md（新工具日志说明，如需）
- [x] 6.4 live 测试验证：AI 自然使用 `grep_file`/`glob_file`/批量 `edit_file` 完成一次多文件任务（如搜索 TODO 并编辑） —— **通过（2026-08-15，真实模型 deepseek-v4-pro 自然使用新工具完成 TODO→DONE 任务，8 秒）**

## 7. 收尾

- [x] 7.1 全量测试跑通：C++ 单测（220 用例非 live 全绿，含 rg 实测）+ Dart 单测（153 全绿）+ live 测试（模型自然使用新工具）——除既有 `[zhipuai][live][rate-guard]` live 测试（需真实 ZhipuAI API，与本次改动无关，属环境性失败）
- [x] 7.2 诚实性审查任务（开 Workflow 对抗验证，4 维度 12 findings 全部确认）——见第 8 节追加任务

## 8. 诚实性审查发现（2026-08-15 收尾轮 Workflow 对抗验证，12 findings 全部确认，0 驳回）

- [x] 8.1 grep_file 软错误（退出码 2）被 summary 吞掉：on_stdout_chunk 对 summary 返回 true → decided=true → 跳过 exit-2 检查，rg 软错误（不可读文件）被静默报告 ok:true 而非 spec 要求的 `{"ok":false,"error":"search failed: <stderr>"}`（[1][8]）。修复：summary 不再返回 true（让进程自然结束以保留真实退出码），exit-2 检查按 `!res.stopped_early` 判断（truncated 才跳过）—— **已修复，icacls 实测确认：不可读文件场景返回 `search failed: rg: ... 拒绝访问。`**
- [x] 8.2 subprocess.cpp 忽略 `AssignProcessToJobObject` 返回值：当子进程因父进程已在其他 job 而无法放入本 job 时（CI/沙箱/计划任务），超时与 early-stop 路径的 `TerminateJobObject` 对空 job 无效，rg/crawl4ai 残留运行。修复：记录赋值结果，失败时回退 `TerminateProcess(pi.hProcess, 1)`（[2]）
- [x] 8.3 glob_file 未实现流式 early-termination：无 on_stdout_chunk，缓冲整个 `rg --files` 输出到 EOF 才截断，违反 design D4"max_results 到达即终止"承诺；大目录下即使前 200 条已产生也会等到 30s 超时或耗尽内存。修复：用 on_stdout_chunk 流式按行解析，收集满 max_results+1 条即终止并标 truncated（[3]）
- [x] 8.4 edit_file Tier-2 `map_norm_to_orig` 裸 CR 尾随空白不一致：normalize_whitespace 将裸 CR 先转 LF 再剥离行尾空白，但 map 的尾随判定只认 `\n`/CRLF → 裸 CR 前空白映射成过短区间 → 静默写坏文件。修复：尾随判定加裸 CR（`content[peek]=='\r'`）（[4]）—— **已修复，新增 bare-CR 回归测试**
- [x] 8.5 main.dart glob_file 模型可见内容硬编码 `paths.take(100)`，但 max_results 默认 200 → 101-200 条静默丢弃且无 truncated 标记。修复：改为 `take(maxResults)`（[5]）
- [x] 8.6 main.dart grep_file 模型可见内容硬编码 `matches.take(100)`，max_results 无上限时静默丢弃。修复：改为 `take(maxResults)`（[6]）
- [x] 8.7 main.dart grep_file 行文本 `.trim()` 剥掉前导缩进（应只剥尾随换行）。修复：改 `.trimRight()`（[7]）
- [x] 8.8 诚实性问题：tasks.md 3.5/4.5 标注 [x] 声称覆盖"30s 超时"/"软错误（退出码 2 非正则）区分"/"rg 缺失"/"宽容解析降级"测试，但 search_tools_test.cpp 无对应测试用例。修复：补齐可行的测试（grep rg 缺失、软错误 stderr 判别抽提为可测函数 `classify_grep_regex_error`、宽容解析降级抽提 `build_match_entry` 直测），并如实修正 tasks.md 3.5/4.5 注释（30s 超时改为"由 subprocess 1s 超时机制测试 + SEARCH_TIMEOUT_SEC 接线覆盖"）（[9][10][11]）
- [x] 8.9 ripgrepDoc.md 出现重复的 `## 2. -g/--glob glob 语义` 章节（L46 与 L66），且旧 ⚠️ 注记（"无斜杠 pattern 未验证"）与新增 2.1 实测确认矛盾。修复：删除重复章节（保留 2 与 2.1）（[12]）
- [x] 8.10 诚实性审查任务：8.1-8.9 修复后开 Workflow 做一轮对抗验证，核对 9 项修复均已落地、无回归（规则 2/8），且上轮 12 findings 全部关闭 —— **复审 Workflow 确认 0 findings（修复全部落地、无回归），审查循环终止**
