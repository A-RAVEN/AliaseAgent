## Why

AI 模型训练数据有截止日期，无法知道当前真实时间。当用户询问时效性问题时，AI 会把当前日期当作"未来"而拒绝回答或给出误导性声明。需要提供一个工具让 AI 主动查询当前时间。

## What Changes

- 新增 `get_current_time` 工具：返回 ISO 8601 格式的当前时间
- 纯 Dart 实现，不涉及 C++ sidecar
- 始终可用（无需配置、无外部依赖）

## Capabilities

### New Capabilities
- `get-current-time-tool`: AI 可调用 `get_current_time` 工具获取当前真实时间

### Modified Capabilities
- `basic-tools`: `_toolDefs` 新增 `get_current_time` 工具定义

## Impact

- `lib/main.dart` — 新增 `get_current_time` 到 `_toolDefs` + `_executeTool` case
