## ADDED Requirements

### Requirement: 真实动态库测试使用上下文夹具

真实动态库测试 SHALL 在调用上下文接口前通过 `create_context` 取得有效句柄，并在返回 `created:true` 时设置工作区；`created:false` 表示 C++ 状态仍在，SHALL NOT 重复覆盖工作区。`ping`、`browser_available`、`ensure_search_infra`、`get_search_providers` SHALL 继续按机器级接口直接调用，不得为了测试伪造默认上下文。

#### Scenario: 同一进程恢复上下文不重复初始化

- **WHEN** 测试用同一句柄连续调用两次 `create_context`
- **THEN** 第二次返回 `created:false`，且第一次设置的工作区与文件版本记录仍然保留

#### Scenario: 机器级接口先于任何上下文也能调用

- **WHEN** 测试进程尚未创建任何上下文时调用 `ping` 或 `ensure_search_infra("{}")`
- **THEN** 调用 SHALL 按其既有契约返回，SHALL NOT 报 `unknown_context`

## MODIFIED Requirements

### Requirement: read_file requires set_workspace first
The system SHALL create or ensure a context and call `set_workspace` **on that same context** before `read_file` or `list_dir` in all tests, as these functions resolve paths relative to that context's workspace directory. Calling `set_workspace` on one context SHALL NOT initialize another context.

#### Scenario: read_file after set_workspace
- **WHEN** a context is created, `set_workspace` is called with the project root on that context, then `read_file` is called with `pubspec.yaml` on the same context
- **THEN** the file content is returned successfully

#### Scenario: Another context is not implicitly initialized
- **WHEN** context 甲 has a workspace but context 乙 was only created and never initialized
- **THEN** `read_file` on 乙 SHALL NOT resolve paths using 甲's workspace; it SHALL report that 乙's workspace is unset
