## Why

用户的原始需求是 thinking 内容**动态流式展示**（与其他 AI harness 一致：思考内容逐字出现、思考期间有反馈、完成后保留可折叠浏览）。但 `add-extended-thinking` 实现时，审计发现 C++ SSE 解析器只在 `content_block_stop` 时一次性发送完整 thinking 块，我擅自把设计降级为"完整块交付"——用户看不到 thinking 的动态过程。本 change 恢复原始设计：**C++ 实时投递 thinking 增量事件，Dart 侧动态渲染**。

同时，现有架构中整个响应（文本、thinking、工具调用）都是 curl 完成后一次性 dispatch 的，思考期间 UI 完全静默。本 change 一并解决：curl 移入独立线程，增量事件实时回调，文本流式也恢复实时性。

## What Changes

- **C++ model_gateway**: curl_easy_perform 移入独立 std::thread（FFI 调用线程 join 保持同步语义），write_callback 直接实时调用回调（不再 buffered 后统一 dispatch）
- **C++ 请求串行化 + 取消**: execute() 以全局互斥锁串行化（任意时刻至多一个活动请求，消除 impl_ 竞争与 curl handle 并发）；新增 `cancel_request()` FFI 取消支持（atomic 标志 + curl 快速返回），Dart 侧超时/会话切换改为真正取消而非伪造 done
- **C++ SSE 增量事件**: thinking_delta 到达时实时投递 `{"type":"thinking_delta","index":N,"delta":"..."}`（wire 格式为 `content_block_delta` + `delta.type=thinking_delta` + `delta.thinking`，合成格式仅内部回调使用）；content_block_stop 时投递最终 `{"type":"thinking","index":N,"thinking":"完整","signature":"..."}`（完整块由解析器累积 delta 得到，stop 仅是触发时机）；text_delta 实时投递；tool_use 保持 stop 时投递完整 JSON
- **回调字符串生命周期**: 增量文本存于 impl_ 的 `std::deque<std::string>`（元素地址稳定，mutex 保护），新请求在持有请求互斥锁时清空（Dart 侧串行门禁保证上一次请求的 done 回调已处理——done 是最后一条回调消息）
- **Dart FFI bridge**: NativeCallable 从 worker isolate 移回主 isolate 创建（回调实时投递到主 isolate 事件循环），worker 通过 `Pointer.address`（int）接收并 `Pointer.fromAddress` 重建；sendMessage 改为 Completer 模式（幂等 complete，忽略重复 done）；请求串行门禁——上一请求未结束（含未取消）时新请求排队
- **Dart UI**: onThinking 处理增量事件——按 index 在当前轮块列表内创建/更新 ChatThinkingItem（内容增量追加），thinking 卡片思考期间实时显示内容增长；**仅最终 thinking 事件进入 turnThinkingBlocks 持久化**（delta 事件不落库、不回灌 API）
- **ChatThinkingItem**: 增加 `index` 字段，作用域为当前轮（SSE index 每条消息从 0 重启）；DB 重建时按块数组顺序派生 index 0..N-1（兼容旧数据）

## Capabilities

### New Capabilities
- `thinking-streaming`: Thinking 内容实时增量投递与动态渲染——思考期间卡片出现并逐字增长，完成后保留（现有折叠逻辑不变）

### Modified Capabilities
- `model-gateway`: curl 线程化 + SSE 事件实时回调投递（不再 buffered 后一次性 dispatch）
- `ffi-bridge`: on_chunk/on_thinking 回调改为实时多次调用（增量语义），NativeCallable 创建位置移至主 isolate
- `chat-ui`: ChatThinkingItem 支持增量更新（index 定位 + 内容追加）
- `extended-thinking`: onThinking 事件格式从"完整块单次"变为"增量流 + 最终块"

## Impact

- **C++ sidecar**: `model_gateway.h/.cpp`（线程化 + 实时回调 + 增量事件 + 字符串生命周期管理 + 请求互斥串行化 + 取消支持）、`sidecar_api.h/.cpp`（新增 `cancel_request` FFI）
- **Dart FFI bridge**: `sidecar_bridge.dart`（NativeCallable 位置 + Pointer.address 传递 + Completer 幂等模式 + 请求串行门禁 + 超时改取消）
- **Dart UI**: `chat_item.dart`（+index）、`main.dart`（onThinking 增量处理 + 持久化过滤 + 重建 index 派生）
- **Tests**: C++（增量事件、实时回调、生命周期、并发串行、取消、done 幂等）、Dart（增量渲染、index 定位、门禁、幂等、持久化过滤、跨轮隔离、折叠状态）、live test（动态过程可见性 + DeepSeek 增量实测）
