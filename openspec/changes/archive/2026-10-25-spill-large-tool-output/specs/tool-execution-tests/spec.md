## ADDED Requirements

### Requirement: run_command 的结果头尾都留，且引用可读

`run_command` SHALL 按 `tool-output-spill` 的契约交付结果：stdout 与 stderr 的完整输出各先落盘（`<会话>/<6 位序号>-<流>.txt`），超限时内联头尾各 `preview_chars` 个字符（缺省 1000）并给出引用。

SHALL NOT 再保留"只截到尾部 + 系统临时文件路径"的旧行为。

> **2026-10-25 修改（对抗验证后）**：初稿这里写的是"也 SHALL NOT 在 Dart 侧对结果做第二次截断"，那条与实现正好相反 —— `lib/main.dart` 的 `elideOversizedToolResult` 对**每个**工具结果（含 `run_command`）都生效，正文超过 8000 字符就保头保尾砍中段。本变更真正保证的是：**引用与省略量留在正文最后一行，所以那道通用截断掐不到它们**（判据见 `tasks.md` 的 3.2 / 9.1 / 9.2），而不是"不截"。

#### Scenario: 构建失败的头一条错误可见
- **WHEN** 执行一条先打印 500 行日志、再在头部第 2 行打出 `error C2065` 的命令
- **THEN** 结果里 SHALL 能看到那条 `error C2065`（因为它落在头部 1000 字符内），且 SHALL 给出 spill 引用

#### Scenario: 尾部也在
- **WHEN** 同一条命令的最后一行是 `Build FAILED.`
- **THEN** 结果里 SHALL 也能看到 `Build FAILED.`（落在尾部 1000 字符内）

#### Scenario: 通用截断发生时引用仍可见
- **WHEN** 把 `preview_chars` 配到 4000（头尾合计 8000），使整段结果必然超过 `kToolResultElisionThreshold`
- **THEN** 结果的最后一行 SHALL 仍含 spill 引用与省略量（它们不落在被砍掉的中段里），且 `read_spill` 能按该引用读回文件里的任意合法区间

#### Scenario: 两条流同时超限时各给一个引用
- **WHEN** 一条命令的 stdout 与 stderr 都远超预览阈值
- **THEN** 两条流的截断字段 SHALL 都为真，且 SHALL 各给一个引用；两个引用 SHALL 指向**不同**文件，两个文件 SHALL 各自等于该条流的完整输出字节数
