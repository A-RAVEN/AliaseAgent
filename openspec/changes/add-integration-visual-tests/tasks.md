## 1. ISidecar 接口提取

- [x] 1.1 `lib/services/sidecar_bridge.dart`：提取 `abstract class ISidecar`，包含 `sendMessage()` 和 `setWorkspace()` 签名
- [x] 1.2 `SidecarBridge` 改为 `implements ISidecar`，签名和方法体不变
- [x] 1.3 `lib/main.dart`：`ChatScreen` 新增可选参数 `ISidecar? sidecar`，默认 `SidecarBridge.instance`

## 2. FakeSidecar 实现

- [x] 2.1 `test/integration/helpers/fake_sidecar.dart`：创建 `FakeSidecar implements ISidecar`，支持 `queueChunk()` / `queueToolCall()` / `queueThinking()` / `queueDone({code, error, stopReason})`
- [x] 2.2 `sendMessage()` 实现：按序回放队列中的事件，依次调用 `onChunk` / `onToolCall` / `onThinking` / `onDone` 回调
- [x] 2.3 `readFile()` / `listDir()` 实现：返回 `stubReadFile()` / `stubListDir()` 预设的 JSON 结果
- [x] 2.4 `setWorkspace()` 实现：no-op

## 3. Integration Test 编写

- [x] 3.1 `test/integration/message_flow_test.dart`：FakeSidecar + Fake repo → 发送消息 → 收到 fake 回复 → 验证 UI 渲染
- [x] 3.2 `test/integration/tool_call_test.dart`：FakeSidecar 发射 tool_call + stub readFile → 验证 ToolCallCard 出现在消息列表
- [x] 3.3 `test/integration/auto_title_test.dart`：FakeSidecar + Fake repo → 发送首条消息 → 验证 session title 从 "New Chat" 更新
- [x] 3.4 `test/integration/error_flow_test.dart`：FakeSidecar 返回 queueDone(code=1, error) → 验证错误消息渲染
- [x] 3.5 `test/integration/streaming_state_test.dart`：验证 sendMessage 调用后 isStreaming=true → onDone 后 isStreaming=false

## 4. 视觉回归集成

- [x] 4.1 `test/integration/helpers/screenshot_utils.dart`：`captureWidgetAsPng(GlobalKey, path)` 用 `RepaintBoundary.toImage()` 截图
- [x] 4.2 `test/smoke/05_visual_regression.sh`：调用 `flutter test integration_test/`，用 `sha256sum` 逐文件对比 `output/*.png` vs `references/*.png`
- [x] 4.3 `test/smoke/run_all.sh`：在 step 4 之后追加 step 5（visual regression）
- [x] 4.4 Baseline 机制：首次运行（`references/` 为空）→ 复制 `output/` 到 `references/` → 报告 "BASELINE_CREATED"

## 5. 清理

- [x] 5.1 `add-smoke-tests/tasks.md`：删除 4.1-4.4 手动截图任务（已被本 change 自动化取代）

### 🔎 Checkpoint: 验收

| # | 验收项 | 通过标准 |
|---|--------|----------|
| A | 接口提取无副作用 | `flutter build windows --debug` 编译成功，行为不变 |
| B | FakeSidecar 可编程 | 预设事件序列 → `sendMessage()` → 回调按序触发 |
| C | Integration test 可运行 | `flutter test integration_test/` 全部通过 |
| D | 视觉回归可用 | 首次运行生成 baseline，再次运行做 diff |
| E | 全管线串联 | `bash test/smoke/run_all.sh` 5 个 step 全部通过 |
