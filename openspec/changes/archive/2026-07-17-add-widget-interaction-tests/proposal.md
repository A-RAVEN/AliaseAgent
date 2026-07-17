## Why

当前 `test/widget_test.dart` 是 Flutter 模板的 counter 假测试，没有任何实际 UI 验证。`add-smoke-tests` 提供了编译/分析/启停/截图/日志的自动化验证，但无法测试应用内的用户交互流程（发送消息、按钮点击、UI 状态变化）。需要补齐 Widget 级别的交互测试，覆盖核心 UI 路径。

## What Changes

- 用真实的 Widget 测试替换 `test/widget_test.dart` 中的模板 counter 测试
- 新增 `test/widget/` 目录，组织各级测试文件
- **Tier 1 纯 Widget 测试**：`ChatArea`、`SessionSidebar`、`MessageBubble`、`ToolCallCard` 的独立渲染验证——不依赖任何服务，改动量为零
- **Tier 2 Mock 测试**：`ChatScreen` 加可选构造函数参数注入 `SessionRepository` / `MessageRepository` 接口，用 Mockito 模拟数据验证完整交互链（输入→发送→标题更新→tool call 渲染→错误气泡）
- 新增 dev dependency：`mockito` + `build_runner`（生成 mock 类）

## Capabilities

### New Capabilities
- `widget-ui-tests`: 叶子 Widget 纯 UI 测试——验证空状态占位文本、消息气泡渲染、会话列表显示、工具卡片展示
- `widget-interaction-tests`: 带 mock 的交互流程测试——发消息、切换会话、auto-title 更新、tool card 出现、错误气泡出现

### Modified Capabilities
（无 — 不改动现有功能需求）

## Impact

- `test/widget_test.dart` — 删除或替换为实际测试入口
- `test/widget/` — 新增测试目录
- `lib/main.dart` — `ChatScreen` 新增可选 `sessionRepo` / `msgRepo` 参数（向后兼容，默认行为不变）
- `pubspec.yaml` — 新增 `mockito`、`build_runner` dev dependency
- `add-smoke-tests` smoke test 保持独立，本 change 为互补关系
