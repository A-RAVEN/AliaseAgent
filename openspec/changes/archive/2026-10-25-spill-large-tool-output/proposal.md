## Why

工具输出现在**由各个工具各自截断，且截完不留可取的引用**，最典型的是 `run_command`：工具说明原文写着 *"Long output is truncated to its tail and the full output is written to a temp file whose path is reported."*

这带来三个具体问题：

1. **只留尾部** —— 构建、测试、编译器诊断的第一条错误通常出现在**头部**，恰好被砍掉。今天我就为「哪个 C++ 用例失败」绕了三轮才拿到名字。
2. **临时文件无保障** —— 谁清理、保留多久、下次还在不在，都没有约定；路径只是碰巧能用。
3. **占位不带量** —— 模型不知道少了多少字节，无法判断"该不该去读全文"。

这不是上下文窗口的问题（那是压缩的职责），是**工具结果的交付契约**问题。

## What Changes

- **工具输出先落盘（本期只对 `run_command` 生效）**：每次 `run_command` 调用都把 stdout 与 stderr 各自的完整输出写到 `~/.aliasagent/spill/<会话>/<6 位序号>-<流>.txt`（每条流一个文件，例如 `000001-stdout.txt`），成功写完再做下一步判断。
- **按长度决定交付方式**：全文长度 ≤ `preview_chars × 2` ⇒ 直接内联全文；超过 ⇒ 内联**头尾各 `preview_chars` 个字符**（`preview_chars` 默认 **1000**，由用户 2026-10-25 指定），其余以**引用**形式给出。（初稿把同一个 1000 同时当"内联上限"与"每侧长度"，导致 1001–2000 字符既算超限又会被全文内联，已改为单一阈值 `2×preview_chars`。）
- **引用必须可读回**：新增 `read_spill` 工具，按引用 + 字节偏移 + 字节长度取回任意片段，用它代替"让模型猜临时文件还能不能读"。
- **信封必须带量**：返回里包含总字节数、被省略的字节数、头预览、尾预览、引用。**保留期不写进信封** —— 本变更不设时间上限；清理责任挂在**会话删除**上（`<会话 id>/` 整个删），另外**应用启动时会清掉无主的 `no-session/` 与测试目录**（这两件事都写进 `Docs/user-guide/tools-command.md`）。
- **写盘失败不许静默**：小输出退回内联；大输出明确报错（说清写盘失败原因），不得当成"输出就这么点"。
- **本期只改 `run_command`，其余另开 change**：`web_fetch` / `grep_file` / `read_file` 的迁移**不在本期范围**。**注意**：`glob_file` / `grep_file` / `read_file` 现在的结果里已经写了取回办法（"call glob_file again with max_results=2N"、"use offset/limit to read more"），它们不属于"丢了就取不回"的那类；真正缺取回办法的是 `run_command`（系统临时文件随时会被清理，本期已改）与 `web_fetch` 的 2000 字硬切（切完只有一个 `...`，**本期不改，它仍然是缺陷**，见 design 的 D7）。
- **【BREAKING】废弃两个旧配置键**：`command_max_output_chars` 与 `command_output_full_chars` 由 `spill.preview_chars` 取代；旧键读入时打告警并忽略，用户文档同步改表。

## Capabilities

### New Capabilities

- `tool-output-spill`: 工具输出的交付契约 —— 先落盘、按体积选内联或引用、引用可读回、信封带量、写盘失败可见。

### Modified Capabilities

- `command-tool`: 「输出有界、只保留尾部、截断可见」这条整条改写（完整输出改落 spill、内存里保留头尾、信封带量、两个旧配置键废弃）；`四个配置项与缺省值` 那条一并改写（三个值 + 两个旧键废弃）。
- `command-tool-tests`: 「命令构造与输出取舍由 C++ 单测覆盖」这条改写 —— 它逐字钉着"保留尾部 / 未超限不留文件 / 超写文件上限不落文件"三条旧行为，不改它就会出现"两份规范同时成立"。
- `ffi-bridge`: 新增 `read_spill` 的 FFI 导出（Dart 侧工具要调它读回片段，且必须限制在 spill 根目录内）。
- `tool-execution-tests`: 新增一组针对新交付形状的断言（头尾都留、引用可见、双流各一个引用）。

> 更正（2026-10-25 对抗验证后）：初稿把 `tool-execution-tests` 写成"既有断言要改"，核实后该 spec 里 `run_command` 命中 **0** 处，所以它其实是 **ADDED**；真正钉住旧行为的有**两份**主规范 —— `command-tool` 与 `command-tool-tests`，外加 `sidecar/test/command_tool_test.cpp` 里的三条断言。初版只列了 `command-tool`，漏了 `command-tool-tests`（第二轮对抗验证抓出来的），该文件的 delta 已补上。

## Impact

- **C++**：`sidecar/src/command_tool.cpp`（落盘 + 头尾预览 + 信封）、新增 spill 的写入/读取实现、`sidecar_api` 导出 `read_spill`。
- **Dart**：`_toolDefs` 增 `read_spill`，并在 `_executeTool` 的 `switch (name)` 里加 `case 'read_spill'`（不加会落 `default` 返回 `Unknown tool`）；`run_command` 结果不再被通用的 `_elideOversizedToolResult` 掐掉引用段（阈值 `kToolResultElisionThreshold` = 8000 字符，见 `lib/services/search_text_assembly.dart`）。
- **配置**：新增 `spill.preview_chars`（默认 1000），写进 `Docs/user-guide/configuration.md` 的配置键表；`command_max_output_chars` / `command_output_full_chars` 标废弃。
- **磁盘**：`~/.aliasagent/spill/` 新目录，按会话归堆；会话删除时连带清理。
- **测试分层**：单元（信封形状、写盘失败退回）、集成（`read_spill` 取回内容与文件逐字节一致）、C++（`run_command` 的头尾都留）、live（构建失败场景，头部的第一条 error 可见）。
- **不引入的东西**（按项目立场）：不做命令审批、不做沙箱、不做快照回退 —— 见 `Docs/rejected-approaches.md` 第 24、25 条。
