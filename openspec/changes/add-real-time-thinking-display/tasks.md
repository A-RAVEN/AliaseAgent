## 1. C++ model_gateway — curl 线程化 + 实时回调

- [ ] 1.1 `execute()` 内 spawn `std::thread` 跑 curl_easy_perform，FFI 调用线程 join 等待（保持同步语义）
- [ ] 1.2 write_callback 直接实时调用回调（on_chunk/on_thinking），不再 buffered 后统一 dispatch；tool_use 保持 stop 时投递完整 JSON
- [ ] 1.3 新增 `pending_strings`（std::deque<std::string> + std::mutex）存储增量文本；回调传指向 deque 元素地址的指针（deque 地址稳定）
- [ ] 1.4 execute() 开头清空 pending_strings（此时上一次请求所有回调消息已被主 isolate 按序处理完——done 是最后一条）
- [ ] 1.5 thinking_delta → on_thinking(`{"type":"thinking_delta","index":N,"delta":"..."}`) 实时投递；content_block_stop → on_thinking(`{"type":"thinking","index":N,"thinking":"...","signature":"..."}`) 最终投递
- [ ] 1.6 text_delta → on_chunk 实时投递
- [ ] 1.7 验证 curl 线程抛异常/崩溃时线程安全退出（join 不悬挂）

## 2. C++ 测试更新

- [ ] 2.1 新增测试：thinking_delta 事件实时投递（增量 JSON 格式 + index）
- [ ] 2.2 新增测试：最终 thinking 事件含完整文本 + signature + index
- [ ] 2.3 新增测试：text_delta 实时投递（回调在 curl 完成前触发——用 mock server 分块发送验证顺序）
- [ ] 2.4 新增测试：tool_use 仍只在 content_block_stop 投递完整 JSON
- [ ] 2.5 更新受影响的现有测试（事件格式变化：thinking 事件带 index）
- [ ] 2.6 运行完整 sidecar_tests，全部通过

## 3. Dart FFI Bridge — NativeCallable 移至主 isolate

- [ ] 3.1 `sendMessage` 在主 isolate 创建 NativeCallable.listeners（on_chunk/on_tool_call/on_thinking/on_done）
- [ ] 3.2 通过 Isolate.spawn 参数传递 nativeFunction Pointer 给 worker（Pointer 可发送）
- [ ] 3.3 worker 的 FFI 调用使用传入的 Pointer（不再自己创建 callables）
- [ ] 3.4 sendMessage 改为 Completer 模式：on_done 时 complete，Future 语义不变
- [ ] 3.5 callables 的 close 移到主 isolate（onDone 后 Timer.run 统一 close）
- [ ] 3.6 更新 FakeSidecar 接口（如签名变化）并运行受影响测试

## 4. Dart UI — 增量渲染

- [ ] 4.1 `ChatThinkingItem` 增加 `index` 字段
- [ ] 4.2 main.dart onThinking：`type=="thinking_delta"` → 按 index 查找 ChatThinkingItem，创建新实例（旧内容+delta）替换
- [ ] 4.3 onThinking：`type=="thinking"`（最终）→ 更新完整文本 + signature
- [ ] 4.4 首个 delta 创建卡片时 isStreaming: true；turn 完成转 false（现有逻辑保留）
- [ ] 4.5 验证：thinking 期间卡片动态增长，完成后保留折叠状态（现有折叠逻辑不变）

## 5. Dart 测试

- [ ] 5.1 新增测试：thinking_delta 增量更新（FakeSidecar 发多个 delta，验证卡片内容逐步增长）
- [ ] 5.2 新增测试：最终 thinking 事件替换完整内容 + signature
- [ ] 5.3 新增测试：多块 thinking（不同 index）各自独立更新
- [ ] 5.4 新增测试：text 实时流式（onChunk 多次调用）
- [ ] 5.5 运行完整 flutter test，全部通过

## 6. Live 测试

- [ ] 6.1 更新 live test 4：验证 thinking 期间卡片出现并动态增长（用 pumpUntilFound 检查中间状态）
- [ ] 6.2 运行全部 live tests，4/4 通过

## 7. Honesty Review

- [ ] 7.1 Workflow 对抗验证：外部正确性（文档声称须 MCP 验证 + URL 引用）+ 内部一致性 + 用户需求对照（流式已恢复）。发现问题追加新任务并立即修复。
