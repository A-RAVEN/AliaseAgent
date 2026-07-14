## Why

当前 `add-smoke-tests` 和 `add-widget-interaction-tests` 覆盖了编译/分析/启停/日志/DB 和 Widget 渲染逻辑，但缺少端到端的数据流验证——SSE streaming、tool call 流程、auto-title、错误传播，以及对应的视觉回归。`SidecarBridge` 是 C++ FFI 硬依赖，widget test 无法通过它驱动 UI 交互。需要提取接口 + 注入 Fake 实现，使全自动的 integration test + 视觉回归成为可能。

## What Changes

- 提取 `ISidecar` 抽象接口（`lib/services/sidecar_bridge.dart`）
- `SidecarBridge` 改为 `implements ISidecar`（行为不变）
- 新增 `FakeSidecar` 实现：返回预设 SSE 事件流，可控制消息/工具调用/错误/stop_reason
- `ChatScreen` 新增可选 `ISidecar?` 构造参数（向后兼容）
- 新增 `test/integration/` 目录，包含端到端测试脚本
- Integration test 用 FakeSidecar 驱动 app 进入 4 种 UI 状态（空状态/auto-title/tool card/error），每种状态自动截图并对比 reference
- 首次运行生成 baseline screenshots（`test/smoke/references/`），后续运行做视觉 diff
- 移除 `add-smoke-tests` 中 4 个手动截图任务（被本 change 的自动截图取代）

## Capabilities

### New Capabilities
- `fake-sidecar`: FakeSidecar 实现——可编程控制 SSE 事件流，模拟消息回复、工具调用、错误、stop_reason
- `sidecar-interface`: ISidecar 接口提取——抽象 `chat()` 流和 `setWorkspace()`，统一真实和测试实现
- `integration-tests`: Flutter integration_test 入口，串联 FakeSidecar + Fake repo 做端到端验证
- `visual-regression`: 每个 test scenario 自动截图 → 首次生成 baseline → 后续 diff regression

### Modified Capabilities
（无 — 不改动现有功能需求）

## Impact

- `lib/services/sidecar_bridge.dart` — 接口提取 + SidecarBridge implements ISidecar
- `lib/ui/chat_area.dart` — 增加 FakeSidecar 测试文件
- `lib/main.dart` — ChatScreen 新增可选 `ISidecar?` 参数（~4 行）
- `test/integration/` — 新增目录（3-5 个测试文件）
- `test/smoke/references/` — baseline screenshots（首次运行后 git-tracked）
- `add-smoke-tests` tasks.md — 移除 4.1-4.4 手动截图任务（被自动化取代）
