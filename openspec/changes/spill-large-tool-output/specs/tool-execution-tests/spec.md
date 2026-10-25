## ADDED Requirements

### Requirement: run_command 的结果头尾都留，且引用可读

`run_command` SHALL 按 `tool-output-spill` 的契约交付结果：完整输出先落盘，超限时内联头尾各 1000 字符并给出引用。

SHALL NOT 再保留"只截到尾部 + 临时文件路径"的旧行为，也 SHALL NOT 在 Dart 侧对结果做第二次截断。

#### Scenario: 构建失败的头一条错误可见
- **WHEN** 执行一条先打印 500 行日志、再在头部第 2 行打出 `error C2065` 的命令
- **THEN** 结果里 SHALL 能看到那条 `error C2065`（因为它落在头部 1000 字符内），且 SHALL 给出 spill 引用

#### Scenario: 尾部也在
- **WHEN** 同一条命令的最后一行是 `Build FAILED.`
- **THEN** 结果里 SHALL 也能看到 `Build FAILED.`（落在尾部 1000 字符内）

#### Scenario: 不再有第二次截断
- **WHEN** `run_command` 返回的信封超过旧的 `maxLen` 值
- **THEN** 结果 SHALL 原样传给模型，SHALL NOT 被 Dart 侧再截一刀
