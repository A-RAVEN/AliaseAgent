## Why

用户的原始需求是 thinking 内容**动态流式展示**（与其他 AI harness 一致：思考内容逐字出现、思考期间有反馈、完成后保留可折叠浏览）。但 `add-extended-thinking` 实现时，审计发现 C++ SSE 解析器只在 `content_block_stop` 时一次性发送完整 thinking 块，我擅自把设计降级为"完整块交付"——用户看不到 thinking 的动态过程。本 change 恢复原始设计：**C++ 实时投递 thinking 增量事件，Dart 侧动态渲染**。

同时，现有架构中整个响应（文本、thinking、工具调用）都是 curl 完成后一次性 dispatch 的，思考期间 UI 完全静默。本 change 一并解决：curl 移入独立线程，增量事件实时回调，文本流式也恢复实时性。

## What Changes

- **C++ model_gateway**: curl_easy_perform 移入独立 std::thread（FFI 调用线程 join 保持同步语义），write_callback 直接实时调用回调（不再 buffered 后统一 dispatch）
- **C++ SSE 增量事件**: thinking_delta 到达时实时投递 `{"type":"thinking_delta","index":N,"delta":"..."}`；content_block_stop 时投递最终 `{"type":"thinking","index":N,"thinking":"完整","signature":"..."}`；text_delta 实时投递；tool_use 保持 stop 时投递完整 JSON
- **回调字符串生命周期**: 增量文本存于 impl_ 的 `std::deque<std::string>`（元素地址稳定，mutex 保护），execute 开头清空（此时上一次请求的所有回调消息已被主 isolate 按序处理完）
- **Dart FFI bridge**: NativeCallable 从 worker isolate 移回主 isolate 创建（回调实时投递到主 isolate 事件循环），worker 通过 Pointer 接收；sendMessage 改为 Completer 模式
- **Dart UI**: onThinking 处理增量事件——按 index 创建/更新 ChatThinkingItem（内容增量追加），thinking 卡片思考期间实时显示内容增长
- **ChatThinkingItem**: 增加 `index` 字段用于增量定位

## Capabilities

### New Capabilities
- `thinking-streaming`: Thinking 内容实时增量投递与动态渲染——思考期间卡片出现并逐字增长，完成后保留（现有折叠逻辑不变）

### Modified Capabilities
- `model-gateway`: curl 线程化 + SSE 事件实时回调投递（不再 buffered 后一次性 dispatch）
- `ffi-bridge`: on_chunk/on_thinking 回调改为实时多次调用（增量语义），NativeCallable 创建位置移至主 isolate
- `chat-ui`: ChatThinkingItem 支持增量更新（index 定位 + 内容追加）
- `extended-thinking`: onThinking 事件格式从"完整块单次"变为"增量流 + 最终块"

## Impact

- **C++ sidecar**: `model_gateway.h/.cpp`（线程化 + 实时回调 + 增量事件 + 字符串生命周期管理）
- **Dart FFI bridge**: `sidecar_bridge.dart`（NativeCallable 位置 + Completer 模式）
- **Dart UI**: `chat_item.dart`（+index）、`main.dart`（onThinking 增量处理）
- **Tests**: C++（增量事件、实时回调、生命周期）、Dart（增量渲染、index 定位）、live test（动态过程可见性）
