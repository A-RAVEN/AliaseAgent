## Context

`add-extended-thinking` 交付时，C++ SSE 解析器（`model_gateway.cpp`）采用 buffered 架构：`write_callback` 只把事件 push 进 `impl_->events`，`curl_easy_perform` 完成后 `dispatch_events` 一次性把所有事件投递给 Dart。结果：整个响应（thinking、文本、工具调用）在 curl 完成后才到达 UI，thinking 期间界面完全静默，thinking 卡片一次性出现完整内容。

用户原始需求是动态流式展示（与其他 harness 一致），本 change 恢复该设计。

## Goals / Non-Goals

**Goals:**
- curl 在独立线程运行，SSE 增量事件实时投递到主 isolate（thinking_delta → on_thinking 增量调用；text_delta → on_chunk 实时调用）
- thinking 期间 UI 立即显示"💭 Thinking..."卡片并随增量逐字增长
- 完成后卡片保留，现有折叠/展开/持久化逻辑不变
- 回调字符串跨线程生命周期安全（无 use-after-free）

**Non-Goals:**
- 修改 thinking API 请求格式（`output_config.effort` 修正属 `add-extended-thinking` 收尾，不在此 change）
- tool_use 增量投递（JSON 分片必须累积到 content_block_stop，维持现状）
- 非阻塞/取消请求语义（仍为同步调用，curl 线程 join）

## Decisions

### D1: curl 独立线程 + join 保持同步语义

**Choice**: `execute()` 内 spawn `std::thread` 跑 `curl_easy_perform`，FFI 调用线程 `join()` 等待。

```
FFI 调用线程 (worker isolate Dart 线程)
  │  send_message() 进入 C++
  │  spawn std::thread ──→ curl_easy_perform (write_callback 实时调回调)
  │  join() 等待线程结束
  │  （回调消息已实时投递到主 isolate，不受 join 阻塞影响）
  └── 返回 request_id
```

**Rationale**: 保持 send_message 同步语义（现有 Dart 代码无需改动调用方式），同时让回调消息实时投递到主 isolate 事件循环——实时性由"回调投递目标"决定，与 FFI 线程是否阻塞无关。

### D2: NativeCallable 移至主 isolate 创建

**Choice**: `SidecarBridge.sendMessage` 在主 isolate 创建 NativeCallable.listeners，把 `nativeFunction` Pointer 通过 `Isolate.spawn` 传给 worker；worker 的 FFI 调用使用这些 Pointer。

**关键原理**: `NativeCallable.listener` 的回调投递到**创建它的 isolate** 的事件循环。现在 callables 在 worker（阻塞在 curl 上）创建，回调消息积压到 curl 完成后才处理。移到主 isolate 后，C++ curl 线程调用回调 → 消息立即进入主 isolate 事件循环 → UI 实时 setState。

**Pointer 可发送性**: `NativeCallable.nativeFunction` 返回的 `Pointer<Void>` 可作为 isolate 消息传递（纯地址值）。

### D3: 回调字符串生命周期——deque + mutex + 时机屏障

**Choice**: `ModelGateway::Impl` 增加：

```cpp
std::mutex pending_mutex;
std::deque<std::string> pending_strings;  // 增量事件文本，元素地址稳定
```

- write_callback（curl 线程）: `lock → pending_strings.emplace_back(text) → ptr = &pending_strings.back() → unlock → on_chunk(ptr)`（thinking 同理）
- `execute()` 开头：清空 `pending_strings`（此时上一次请求的所有回调消息已被主 isolate 按序处理完——done 消息是最后一条，Dart 收到 done 后才会发起下一次调用）

**正确性依据**:
1. `std::deque::emplace_back` 不使已有元素地址失效
2. 每个字符串只被 curl 线程写一次、主 isolate 读一次（toDartString 同步拷贝），无同一元素并发读写
3. SendPort 消息保序 + worker 串行 await for：上一次请求的 onDone 处理完 = 之前所有回调已执行完，此时 execute 开头清空安全

### D4: thinking 增量事件格式（复用 on_thinking 回调）

**Choice**: on_thinking 回调签名不变（`const char* thinking_json`），事件内容分两种：

```json
// 增量（每个 thinking_delta 触发一次）
{"type":"thinking_delta","index":0,"delta":"让我分析..."}

// 最终（content_block_stop 触发）
{"type":"thinking","index":0,"thinking":"完整内容...","signature":"sig_abc"}
```

Dart 侧按 `type` 区分：增量 → 找到 index 对应的 ChatThinkingItem 追加 delta；最终 → 更新完整文本 + signature。

**Rationale**: 不改 FFI 签名（避免连锁破坏），JSON 内容区分事件类型即可。

### D5: text_delta 实时投递

**Choice**: text_delta 到达时直接调 on_chunk（实时），不再 buffered。`turnText` 累积逻辑在 Dart 侧已有（onChunk 回调里 `turnText += text`），无需改动。流式指示器（_StreamingDots）恢复真实动态。

### D6: ChatThinkingItem 增加 index 字段

**Choice**: `ChatThinkingItem` 增加 `int index`，用于增量事件定位对应卡片。`onThinking` 处理增量时：`_chatItems` 中按 `ChatThinkingItem.index == ev.index` 查找，创建新实例（追加后文本）替换原项。

## Risks / Trade-offs

- **[回调时序]**: 主 isolate 忙时回调延迟 → 增量积压后批量渲染（视觉上仍为动态，仅可能小幅度批次化）。→ 可接受；与 harness 的节流行为类似。
- **[并发安全]**: curl 线程与主 isolate 并发访问 pending_strings → D3 的 mutex + 单一写/单一读设计规避；同一字符串无并发读写。
- **[NativeCallable 生命周期]**: worker 不再负责 close callables → 由主 isolate 在 onDone 后统一 close（保持现有 Timer.run 模式，移到主 isolate）。
- **[回归风险]**: 现有 59+ C++ 测试与 132 Dart 测试依赖 buffered 行为 → 全部更新为实时语义后验证；live test 4/4 必须重跑。
