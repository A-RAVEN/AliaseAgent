## Why

工具输出现在**由各个工具各自截断，且截完不留可取的引用**，最典型的是 `run_command`：工具说明原文写着 *"Long output is truncated to its tail and the full output is written to a temp file whose path is reported."*

这带来三个具体问题：

1. **只留尾部** —— 构建、测试、编译器诊断的第一条错误通常出现在**头部**，恰好被砍掉。今天我就为「哪个 C++ 用例失败」绕了三轮才拿到名字。
2. **临时文件无保障** —— 谁清理、保留多久、下次还在不在，都没有约定；路径只是碰巧能用。
3. **占位不带量** —— 模型不知道少了多少字节，无法判断"该不该去读全文"。

这不是上下文窗口的问题（那是压缩的职责），是**工具结果的交付契约**问题。

## What Changes

- **工具输出一律先落盘**：每次工具调用都把完整输出写到 `~/.aliasagent/spill/<会话>/<调用序号>.txt`，成功写完再做下一步判断。
- **按体积决定交付方式**：全文不超过内联上限 ⇒ 直接内联；超过 ⇒ 内联只给**头尾各 1000 字符**（1000 由用户 2026-10-25 指定），其余以**引用**形式给出。
- **引用必须可读回**：新增 `read_spill` 工具，按引用 + 偏移 + 长度取回任意片段，用它代替"让模型猜临时文件还能不能读"。
- **信封必须带量**：返回里包含总字节数、被省略的字节数、头预览、尾预览、引用、保留期。
- **写盘失败不许静默**：小输出退回内联；大输出明确报错（说清写盘失败原因），不得当成"输出就这么点"。
- **统一到一套机制**：先改 `run_command`，再把 `web_fetch` / `grep_file` / `read_file` 迁过来，并删掉各自的临时补丁（`maxLen = 2000`、工具结果中段裁剪）。

## Capabilities

### New Capabilities

- `tool-output-spill`: 工具输出的交付契约 —— 先落盘、按体积选内联或引用、引用可读回、信封带量、写盘失败可见。

### Modified Capabilities

- `ffi-bridge`: 新增 `read_spill` 的 FFI 导出（Dart 侧工具要调它读回片段）。
- `tool-execution-tests`: `run_command` 的结果形状与截断行为改变，既有断言要按新契约更新。

## Impact

- **C++**：`sidecar/src/command_tool.cpp`（落盘 + 头尾预览 + 信封）、新增 spill 的写入/读取实现、`sidecar_api` 导出 `read_spill`。
- **Dart**：`_toolDefs` 增 `read_spill`；`_executeTool` 里 `run_command` 的结果不再二次截断（`maxLen = 2000` 那处删除）。
- **配置**：内联上限（头尾各 1000 字符）、保留期（几天/几次会话）都做成配置项，写进 `Docs/user-guide/configuration.md` 的配置键表。
- **磁盘**：`~/.aliasagent/spill/` 新目录，按会话归堆；会话删除时连带清理。
- **测试分层**：单元（信封形状、写盘失败退回）、集成（`read_spill` 取回内容与文件逐字节一致）、C++（`run_command` 的头尾都留）、live（构建失败场景，头部的第一条 error 可见）。
- **不引入的东西**（按项目立场）：不做命令审批、不做沙箱、不做快照回退 —— 见 `Docs/rejected-approaches.md` 第 24、25 条。
