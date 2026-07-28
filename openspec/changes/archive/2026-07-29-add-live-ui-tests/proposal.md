## Why

当前 live test（smoke test）只验证"app 能开机"——启动、窗口出现、日志无 ERROR、数据库存在。无法验证核心功能：用户在 app 里打字 → AI 回复 → 工具调用 → 结果展示。这些真实对话链路只有 mock 测试覆盖，而 mock 测试无法发现 OS 级问题（pipe 死锁、DLL 依赖、FFI 崩溃）。

需要一层使用真实 API + 真实 sidecar DLL 的 UI 集成测试，在 app 的 widget 树中驱动完整对话流程。

## What Changes

- 新增 `integration_test/real_api_test.dart`：使用真实 `SidecarBridge`（真实 DLL）和真实 API key，通过 `WidgetTester` 驱动 UI 交互
- 测试场景：发送消息 → 等待 AI 回复 → 验证回复存在且非空；发送触发 web_fetch 的消息 → 验证 ToolCallCard 出现且状态为 Done → 验证 AI 引用了抓取内容
- 处理流式动画（`_StreamingDots` 无限动画导致 `pumpAndSettle` 死循环）：使用手动 `pump(Duration)` 循环
- 可选：给关键 widget 加 Key 加固选择器

## Capabilities

### New Capabilities
- `live-ui-tests`: 使用真实 API 和真实 sidecar DLL 的 Flutter integration_test，驱动 UI 交互验证完整对话链路

### Modified Capabilities
无

## Impact

- **新增**: `integration_test/real_api_test.dart`
- **依赖**: `integration_test` SDK（已在 pubspec.yaml）、真实 sidecar.dll（项目根已有）、真实 API key（`~/.aliasagent/config.json`）
- **运行方式**: `flutter test integration_test/real_api_test.dart`（headless）
- **网络依赖**: 需要网络和有效 API key——这是 live test 的设计意图，不是缺陷
- 不修改生产代码（除非选择加 widget Key）
