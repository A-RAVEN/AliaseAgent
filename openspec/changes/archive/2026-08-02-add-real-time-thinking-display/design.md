## Context

`add-extended-thinking` 交付时，C++ SSE 解析器（`model_gateway.cpp`）采用 buffered 架构：`write_callback` 只把事件 push 进 `impl_->events`，`curl_easy_perform` 完成后 `dispatch_events` 一次性把所有事件投递给 Dart。结果：整个响应（thinking、文本、工具调用）在 curl 完成后才到达 UI，thinking 期间界面完全静默，thinking 卡片一次性出现完整内容。

用户原始需求是动态流式展示（与其他 harness 一致），本 change 恢复该设计。

## Goals / Non-Goals

**Goals:**
- curl 在独立线程运行，SSE 增量事件实时投递到主 isolate（thinking_delta → on_thinking 增量调用；text_delta → on_chunk 实时调用）
- thinking 期间 UI 立即显示"💭 Thinking..."卡片并随增量逐字增长
- 完成后卡片保留，现有折叠/展开/持久化逻辑不变（持久化只含最终 thinking 块）
- 回调字符串跨线程生命周期安全（无 use-after-free）——即使请求被中途取消或会话切换
- 请求并发安全：任意时刻至多一个活动请求（C++ 互斥串行化 + Dart 门禁），支持主动取消（超时/会话切换）

**Non-Goals:**
- 修改 thinking API 请求格式（`output_config.effort` 修正属 `add-extended-thinking` 收尾，不在此 change）
- tool_use 增量投递（JSON 分片必须累积到 content_block_stop，维持现状）
- 非阻塞请求语义（仍为同步调用，curl 线程 join）——**取消支持属本 change**，但取消后仍走同步返回路径

## Decisions

### D1: curl 独立线程 + join 保持同步语义 + 请求互斥串行化

**Choice**: `execute()` 内 spawn `std::thread` 跑 `curl_easy_perform`，FFI 调用线程 `join()` 等待；整个请求生命周期（spawn + join）持有全局 `request_mutex`（`std::lock_guard`），保证任意时刻至多一个活动请求。

```
FFI 调用线程 (worker isolate Dart 线程)
  │  send_message() 进入 C++
  │  lock request_mutex（若上一请求未结束则阻塞等待，天然串行）
  │  spawn std::thread ──→ curl_easy_perform (write_callback 实时调回调)
  │  join() 等待线程结束
  │  unlock request_mutex
  └── 返回 request_id
```

**Rationale**: 保持 send_message 同步语义（现有 Dart 代码无需改动调用方式），同时让回调消息实时投递到主 isolate 事件循环——实时性由"回调投递目标"决定，与 FFI 线程是否阻塞无关。

**串行化的必要性（审查 F1）**: 原设计假设"Dart 收到 done 后才发起下一次调用"，但真实代码存在两条打破该假设的路径——(1) `main.dart` 的 `_selectSession`/`_newChat`/`_deleteSession` 在流式期间调 `_endStreaming()`（不取消 C++ 请求）后用户立即发新消息；(2) `sidecar_bridge.dart` 120s 超时路径。两者都会让新 `execute()` 在旧 curl 线程仍在流式时进入 → 未加锁的 `impl_` 字段竞争 + 同一 CURL handle 双线程 `curl_easy_perform`（libcurl 官方禁止："You must never use a single handle from more than one thread at any given time"）。请求互斥锁把并发 execute 变为串行；配合 D3 的清空时机与 D7 的取消，消除 UAF。

### D2: NativeCallable 移至主 isolate 创建，Pointer 以 address(int) 传递

**Choice**: `SidecarBridge.sendMessage` 在主 isolate 创建 NativeCallable.listeners，把 `nativeFunction.address`（int）通过 `Isolate.spawn` 参数传给 worker；worker 内 `Pointer.fromAddress(addr)` 重建指针后用于 FFI 调用。

**关键原理**: `NativeCallable.listener` 的回调投递到**创建它的 isolate** 的事件循环。现在 callables 在 worker（阻塞在 curl 上）创建，回调消息积压到 curl 完成后才处理。移到主 isolate 后，C++ curl 线程调用回调 → 消息立即进入主 isolate 事件循环 → UI 实时 setState。

**为什么传 address 而非 Pointer 对象**: 审查发现官方文档互相矛盾——api.dart.dev 旧版 `SendPort.send` 例外清单含 `Pointer`（"…exceptions: … Pointer, UserTag, MirrorReference"），dart.dev/language/concurrency 亦把 Pointer 列入不可发送清单；但当前 SDK（Flutter 3.41.9 / Dart 3.11.x）中 `Pointer` 已改为 `final class Pointer<T extends NativeType> implements SizedNativeType`（不再继承 `NativeFieldWrapperClass1`），本地 SDK 源码 `SendPort.send` 文档例外清单不含 Pointer，且实证（Isolate.spawn 参数与 SendPort.send 嵌套容器传递 NativeCallable.nativeFunction 均成功、地址逐位一致）确认当前 SDK 可发送。为消除"未文档化行为 + SDK 升级回归"风险，本设计**不依赖 Pointer 对象可发送性**：传 `Pointer.address`（int，纯数值）在跨 isolate 时绝对安全，worker 侧 `Pointer.fromAddress` 重建等价。

### D3: 回调字符串生命周期——deque + mutex + 串行屏障

**Choice**: `ModelGateway::Impl` 增加：

```cpp
std::mutex pending_mutex;
std::deque<std::string> pending_strings;  // 增量事件文本，元素地址稳定
```

- write_callback（curl 线程）: `lock → pending_strings.emplace_back(text) → ptr = &pending_strings.back() → unlock → on_chunk(ptr)`（thinking 同理）
- 新请求在持有 `request_mutex`（D1）时清空 `pending_strings`——此时上一个请求的 curl 线程已 join（其所有回调 FFI 调用已发出），且 Dart 侧串行门禁（D2/D7）保证上一次请求的 done 回调已被主 isolate 处理完

**正确性依据**:
1. `std::deque::emplace_back` 不使已有元素地址失效
2. 每个字符串只被 curl 线程写一次、主 isolate 读一次（listener 内 toDartString 同步拷贝），无同一元素并发读写
3. **清空时机屏障由三层保证**（审查 F1/F8 修订）：
   a. **C++ 层**：`request_mutex` 使 execute 严格串行——新 execute 进入时上一个 execute 已 join（curl 线程已停止调用回调），消除"旧请求流式中新请求清空"的窗口；
   b. **Dart 门禁层**：`SidecarBridge` 维护活动请求引用，新 `sendMessage` 在上一请求未结束（或未取消完成）时排队等待；请求结束的唯一信号是主 isolate 收到 done 回调（含取消路径的 done(-1)）——回调消息经 isolate 消息队列按序投递（同源消息顺序为 VM 稳定实现行为，实证 5000 条严格保序），done 是最后一条，故 done 处理完 = 之前所有回调已执行完；
   c. **取消路径**：`_endStreaming`/超时 → `cancel_request()`（D7）→ C++ 快速终止 → join 后由 FFI 线程发 on_done(-1, "cancelled")（16.5：修正——9.8 已记录实测依据：curl 线程 perform 返回后调用原生回调无法到达 Dart isolate）→ 主 isolate 处理 → 门禁放行。不再存在"伪造 done 后 C++ 仍在流式"的窗口（原 F6 风险）。

### D4: thinking 增量事件格式（复用 on_thinking 回调）

**Choice**: on_thinking 回调签名不变（`const char* thinking_json`），事件内容分两种（**均为 sidecar 合成格式，仅用于内部回调，非 wire 格式**）：

```json
// 增量（每个 thinking_delta 触发一次）
{"type":"thinking_delta","index":0,"delta":"让我分析..."}

// 最终（content_block_stop 触发；完整块由解析器累积 thinking_delta/signature_delta 得到，stop 仅是触发时机）
{"type":"thinking","index":0,"thinking":"完整内容...","signature":"sig_abc"}
```

**wire 格式映射（审查 DELTA-FIELD-NAME/SSE-CBS-CONTENT 澄清）**: API wire 流中事件类型是 `content_block_delta`（data 含 `index` 与 `delta` 对象），`thinking_delta` 是 `delta.type` 的值、增量文本在 `delta.thinking`；`content_block_stop` 的 data 仅含 `type` 和 `index`，不含 content_block 对象。C++ 解析器按 `content_block_delta.index` + `delta.type=="thinking_delta"` + `delta.thinking` 累积增量，**在 content_block_stop 时**投递合成的最终 `thinking` 事件（含完整文本 + 累积的 signature）。Dart 侧绝不按 `"thinking_delta"` 或顶层 `"delta"` 字段去解析 wire 事件——它只消费合成格式。

Dart 侧按 `type` 区分：增量 → 在当前轮块列表按 index 追加 delta；最终 → 更新完整文本 + signature（**并进入持久化，见 D8**）。

**Rationale**: 不改 FFI 签名（避免连锁破坏），JSON 内容区分事件类型即可。

### D5: text_delta 实时投递

**Choice**: text_delta 到达时直接调 on_chunk（实时），不再 buffered。`turnText` 累积逻辑在 Dart 侧已有（onChunk 回调里 `turnText += text`），无需改动。流式指示器（_StreamingDots）恢复真实动态。

### D6: ChatThinkingItem 增加 index 字段（作用域 = 当前轮；重建按序派生）

**Choice**: `ChatThinkingItem` 增加 `int index`。**index 语义为"当前请求（轮）content 数组内的块序号"**——SSE 的 index 每条新消息从 0 重启（官方文档："Each content block has an index that corresponds to its index in the final Message content array"），因此 index 只在单轮内有意义，定位查找**限定在当前轮**，不跨轮匹配（审查 F3 修复）。

**增量定位（onThinking）**: 维护当前轮块列表 `turnThinkingBlocks`（按 index 排列）。`thinking_delta` → 在 `turnThinkingBlocks` 内按 index 查找对应块的增量状态（该轮首个 delta 创建新卡片，后续 delta 追加）；`thinking`（最终）→ 更新完整文本 + signature 并把最终块放入 `turnThinkingBlocks`。UI 卡片更新同样只查"当前轮新增的 ChatThinkingItem"（从卡片创建时刻起算，或直接由增量状态驱动重建），**绝不遍历历史卡片**——历史卡片的 index 与新轮 index 0 数值相同也不受影响。

**重建路径（_buildChatItems / turn 完成转换）**: `ChatThinkingItem.index` **不是持久化字段**，而是重建时的派生值——按 thinking_json 中块数组的顺序赋 0..N-1（与 SSE index 语义一致）。旧数据（add-extended-thinking 时期写入、无 index 字段的 thinking_json）自然兼容：按序派生即可，无需回退策略（审查 RTD-2 修复）。turn 完成时（isStreaming→false 的实例重建）与 DB 重建统一按序派生 index。

### D7: 取消语义（超时/会话切换真正终止请求）

**Choice**: 新增 FFI `cancel_request()`：置 `std::atomic<bool> cancel` 标志；curl 线程通过 `CURLOPT_XFERINFOFUNCTION` 感知取消并快速返回 `CURLE_ABORTED_BY_CALLBACK` → join 完成后由 **FFI 线程**发 `on_done(-1, "cancelled")`（实测依据：curl 线程在 libcurl 调用栈之外（perform 返回后）调用原生回调实测无法到达 Dart isolate，FFI 线程——worker isolate 线程——路径可到达；join 后 curl 线程已终止，close callables 安全性不受影响）→ execute 返回。Dart 侧 `_endStreaming()`/超时/会话切换调用 `cancel_request()` 后等待旧请求 Future 完成，再放行新请求。

**为什么需要（审查 F1/F6 修复）**: 原设计 Non-Goals 无取消，导致 (1) 会话切换后 C++ 请求仍在流式、新请求并发进入（UAF 窗口）；(2) Dart 120s 超时伪造 onDone(-1)，主 isolate 若此时 close NativeCallable，curl 线程后续调用即 UB（官方文档："After NativeCallable.close is called, invoking the nativeFunction from native code will cause undefined behavior"）。取消后：`on_done` 一律在 join 完成后由 FFI 线程发出（真实完成或取消——16.5 修正，与 D7 Choice 一致；curl 线程 perform 返回后调用原生回调实测无法到达 Dart isolate），主 isolate **只在收到 done 后才 close callables 并完成 Completer**——close 时 curl 线程必然已停止调用回调。

**幂等性（审查 F5 修复）**: C++ 侧 `done_dispatched` 改为在 push DONE 事件时互斥检查（`[DONE]` 兼容标记与 `message_stop` 都可能触发，二者不得双发）；Dart 侧 Completer 幂等——`_completer.isCompleted` 判空，忽略重复 done。双触发场景由自建 fixture（`message_stop_end_turn.txt`，含 `message_stop` + `data: [DONE]`）与 live 实测支持；DeepSeek Anthropic 兼容端点是否注入 `[DONE]` 官方文档无记载（DeepSeekAPIDoc.md 的 `[DONE]` 仅出现于 OpenAI 格式 chat/completions 节）——该行为按"兼容性冗余处理"对待，不视为官方保证（9.8）。

**已知边缘（10.5, lost-cancel 窗口）**: `cancel_request()` 若在 `execute()` 重置 `cancel_flag` 之前到达（worker 启动窗口：Isolate.spawn + DLL 加载 + execute 初始化，数十毫秒）会被重置吞掉——请求随后正常完成并落库正常回复（`doneCode 0`，非 cancelled）。影响：用户发送后立即切换会话时旧请求可能跑完。旧行为（未切回）无害——旧会话收到正常回复。**但若用户切回并发新消息，旧请求的迟到 done(0) 必须被 epoch 机制（15.1/16.1）拦截**——过期回复不得落库/渲染/拆除新请求流式状态（E1 修正，design 中 10.5 的"无害"论断在该场景下不成立）。已接受为已知边缘（r2-f3，低严重度，epoch 机制缓解）；彻底消除需为 cancel 增加请求级关联（超出本 change 范围）。

### D8: 持久化过滤——仅最终 thinking 块入库

**Choice**: `turnThinkingBlocks` 只累积**最终** `thinking` 事件（`type=="thinking"`，含完整文本 + signature）；`thinking_delta` 事件**只驱动 UI 增量渲染**，绝不进入 `turnThinkingBlocks`。

**为什么需要（审查 F4/RTD-1 修复）**: 现有代码 `onThinking` 对每个事件无条件 `turnThinkingBlocks.add(th)`，事件流从"每块 1 次"变"每块 N+1 次"后，delta 对象 `{"type":"thinking_delta",...}` 会写入 thinking_json → (1) `_buildApiMessages` 将其作为非法 content 块回灌 API——content 数组合法类型仅 text/thinking/tool_use 等（DeepSeek 文档 Message Fields 证实），thinking_delta 不是 content 类型，多轮 tool_use 循环时请求畸形；(2) `_buildChatItems` 读 `th['thinking']` 得 null → 历史重建出空卡片，破坏"历史可浏览"需求。过滤后 thinking_json 只含最终块，与 `add-extended-thinking` 的 schema 完全兼容（旧数据无需迁移）。

### D9: 请求代际（epoch）——会话切换失效整个调用（15.1/17.5）

**Choice**: `ChatScreen` 维护 `_requestEpoch`（每次 `_sendMessage` 递增并传入 `_callModel`）与 `_switchEpoch`（会话切换时记录当前代际）。被切换过的调用（`_switchEpoch >= epoch`）在以下位置被拦截：

- 工具循环每轮开头（循环中止——无论是否切回，切换即作废整个调用）
- tool 批次内每个工具执行前（副作用工具不落盘）
- 回调层（onChunk/onToolCall/onThinking 渲染前——迟到回调不渲染垃圾）
- 成功路径（stale 回复不落库/不渲染/不拆除新请求流式卡片）
- 错误路径（stale 取消不落错误卡片）
- `_sendMessage` 异常 catch（stale 调用异常不 cancel 新请求）

`sessionId` 与 `epoch` 在用户消息 insert **之前**捕获（17.5）——insert/标题更新等 await 期间的切换不会把消息落到错误会话。

**Rationale**: 取代早期的 `_cancelSwitchSessionId` 单槽标志——其语义无法区分"我的请求被切换走"与"更新的请求被切换走"（RTD-14.3-14.7-REGRESSION）。epoch 是调用级代际：被切换过的调用无论是否切回一律作废（13.3 边界消除），新请求不受 stale 调用干扰。

## Risks / Trade-offs

- **[回调时序]**: 主 isolate 忙时回调延迟 → 增量积压后批量渲染（视觉上仍为动态，仅可能小幅度批次化）。→ 可接受；与 harness 的节流行为类似。
- **[并发安全]**: curl 线程与主 isolate 并发访问 pending_strings → D3 的 mutex + 单一写/单一读设计规避；同一字符串无并发读写；D1 请求互斥锁 + D7 取消消除并发 execute 与伪造 done 窗口。
- **[NativeCallable 生命周期]**: worker 不再负责 close callables → 由主 isolate 在收到 done（真实完成或取消）后统一 close（保持现有 Timer.run 模式，移到主 isolate）；close 前 curl 线程必然已停止调用回调（D7）。
- **[取消粒度]**: 取消响应延迟取决于 curl 检查频率（XFERINFO 回调在 libcurl 传输循环中频繁触发，实测亚秒级）。→ 可接受。
- **[回归风险]**: 现有 59+ C++ 测试与 132 Dart 测试依赖 buffered 行为 → 全部更新为实时语义后验证；live test 4/4 必须重跑。
- **[DeepSeek 增量实测]**: live test 4 实测（2026-08-02）确认 DeepSeek Anthropic 兼容端点**真实下发 thinking_delta 增量流**（sidecar.log：逐字 delta len=1..9 → final len=1053），增量渲染完整可用（8.12 PASS）。
- **[adaptive 格式验证状态（9.9 + 2026-08-02 补充验证）]**: 请求体 `thinking.type="adaptive"` + `display="summarized"` + `output_config.effort` 的格式**有 live 实证**（DeepSeek 接受并返回 thinking 流），但 **DeepSeek 官方文档未记载该格式**——api-docs.deepseek.com/guides/anthropic_api/ 兼容表只写 "thinking | Supported (budget_tokens is ignored)" / "output_config | Only effort is supported"；thinking_mode 指南（2026-08-02 经 WebSearch/WebFetch 抓取官方原文）记载的 Anthropic 格式 toggle 为 `{"reasoning":{"effort":"none/low/high/max"}}`（`none` 禁用）、effort 为 `{"output_config":{"effort":"low/high/max"}}`，"adaptive"/"display"/"summarized" 在该页 0 次出现（**已验证**，非待验证）。实现保持 adaptive 格式（Anthropic 原生格式，同时兼容 Anthropic 端点 + DeepSeek 实测接受），文档差异如实记录。**遗留验证项**：MCP 配额恢复（2026-08-22）后按规则复核 5 个外部 URL（libcurl threadsafe、platform.claude.com streaming、DeepSeek anthropic_api、Anthropic extended-thinking、docs.anthropic.com messages-streaming）——其中 DeepSeek thinking_mode 已用 WebFetch 官方原文复核（用户授权替代通道）。
