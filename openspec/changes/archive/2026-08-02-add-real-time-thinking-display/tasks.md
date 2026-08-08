## 1. C++ model_gateway — curl 线程化 + 实时回调 + 请求串行化

- [x] 1.1 `execute()` 内 spawn `std::thread` 跑 curl_easy_perform，FFI 调用线程 join 等待（保持同步语义）；整个请求生命周期（spawn + join）持有全局 `request_mutex`（std::lock_guard），任意时刻至多一个活动请求
- [x] 1.2 write_callback 直接实时调用回调（on_chunk/on_thinking），不再 buffered 后统一 dispatch；tool_use 保持 stop 时投递完整 JSON
- [x] 1.3 新增 `pending_strings`（std::deque<std::string> + std::mutex）存储增量文本；回调传指向 deque 元素地址的指针（deque 地址稳定）
- [x] 1.4 execute() 在持有 request_mutex 时清空 pending_strings（此时上一请求 curl 线程已 join、Dart 门禁保证其 done 回调已被主 isolate 处理完——done 是最后一条回调消息）
- [x] 1.5 thinking_delta → on_thinking(`{"type":"thinking_delta","index":N,"delta":"..."}`) 实时投递；content_block_stop → on_thinking(`{"type":"thinking","index":N,"thinking":"...","signature":"..."}`) 最终投递（完整块由解析器累积 delta 得到；代码注释注明 wire 映射：content_block_delta.index + delta.type=thinking_delta + delta.thinking）
- [x] 1.6 text_delta → on_chunk 实时投递
- [x] 1.7 验证 curl 线程抛异常/崩溃时线程安全退出（join 不悬挂）

## 2. C++ 测试更新

- [x] 2.1 新增测试：thinking_delta 事件实时投递（增量 JSON 格式 + index）
- [x] 2.2 新增测试：最终 thinking 事件含完整文本 + signature + index
- [x] 2.3 新增测试：text_delta 实时投递（回调在 curl 完成前触发——用 mock server 分块发送验证顺序）
- [x] 2.4 新增测试：tool_use 仍只在 content_block_stop 投递完整 JSON
- [x] 2.5 更新受影响的现有测试（事件格式变化：thinking 事件带 index）
- [x] 2.6 运行完整 sidecar_tests，全部通过

## 3. Dart FFI Bridge — NativeCallable 移至主 isolate + 串行门禁

- [x] 3.1 `sendMessage` 在主 isolate 创建 NativeCallable.listeners（on_chunk/on_tool_call/on_thinking/on_done）
- [x] 3.2 通过 Isolate.spawn 参数传递 `nativeFunction.address`（int）给 worker（Pointer 对象跨 isolate 发送性无文档保证，address 传递零风险）；worker 内 `Pointer.fromAddress` 重建
- [x] 3.3 worker 的 FFI 调用使用重建后的 Pointer（不再自己创建 callables）
- [x] 3.4 sendMessage 改为 Completer 模式：on_done 时 complete（幂等——isCompleted 判空，忽略重复 done，无 StateError）；Future 语义不变
- [x] 3.5 callables 的 close 移到主 isolate（收到真实 done——正常完成或取消——后 Timer.run 统一 close；close 前 curl 线程必然已停止调用回调）
- [x] 3.6 请求串行门禁：新 sendMessage 在上一请求未结束（done 未处理或未取消完成）时排队等待；超时路径调用 `cancel_request()`（C++ 侧）等待取消 done，不再伪造 onDone
- [x] 3.7 更新 FakeSidecar 接口（如签名变化）并运行受影响测试

## 4. Dart UI — 增量渲染 + 持久化过滤

- [x] 4.1 `ChatThinkingItem` 增加 `index` 字段（作用域 = 当前轮；SSE index 每条消息从 0 重启）
- [x] 4.2 main.dart onThinking：`type=="thinking_delta"` → 在当前轮块列表内按 index 查找 ChatThinkingItem，创建新实例（旧内容+delta）替换（不跨轮匹配历史卡片）
- [x] 4.3 onThinking：`type=="thinking"`（最终）→ 更新完整文本 + signature，并加入 `turnThinkingBlocks`（持久化只含最终块；thinking_delta 绝不进入 turnThinkingBlocks/thinking_json/_buildApiMessages）
- [x] 4.4 首个 delta 创建卡片时 isStreaming: true；turn 完成转 false（现有逻辑保留）
- [x] 4.5 验证：thinking 期间卡片动态增长，完成后保留折叠状态（现有折叠逻辑不变；streaming 中折叠卡片不自动展开、turn 完成不改变折叠状态）
- [x] 4.6 turn 完成转换与 `_buildChatItems` 重建 ChatThinkingItem 时按块数组顺序派生 index 0..N-1（index 非持久化字段；旧数据无 index 自然兼容）

## 5. Dart 测试

- [x] 5.1 新增测试：thinking_delta 增量更新（FakeSidecar 发多个 delta，验证卡片内容逐步增长）
- [x] 5.2 新增测试：最终 thinking 事件替换完整内容 + signature
- [x] 5.3 新增测试：多块 thinking（不同 index）各自独立更新
- [x] 5.4 新增测试：text 实时流式（onChunk 多次调用）
- [x] 5.5 新增测试：thinking_delta 不持久化（thinking_json 只含最终块；_buildApiMessages 无 thinking_delta 块）
- [x] 5.6 新增测试：跨轮 index 不冲突（第二轮 index 0 的 delta 不修改第一轮卡片）
- [x] 5.7 新增测试：重建派生 index（含旧数据无 index 字段场景）；turn 完成转换保留 index
- [x] 5.8 新增测试：streaming 中折叠状态保持用户控制（delta 到达/turn 完成均不自动展开/折叠）
- [x] 5.9 运行完整 flutter test，全部通过

## 6. Live 测试

- [x] 6.1 更新 live test 4：验证 thinking 期间卡片出现并动态增长（用 pumpUntilFound 检查中间状态）——**实测确认 DeepSeek 端点真实下发 thinking_delta 增量文本**；若端点按 display:omitted 语义不发送增量，记录实测结果并确认退化路径（最终块 + 指示器动画）
- [x] 6.2 运行全部 live tests，4/4 通过

## 7. Honesty Review（proposal 审查触发）

- [x] 7.1 Workflow 对抗验证：外部正确性（文档声称须 MCP 验证 + URL 引用）+ 内部一致性 + 用户需求对照（流式已恢复）。发现问题追加新任务并立即修复。

## 8. Round 1 Fixes（外部正确性 + 对抗验证发现）

- [x] 8.1 C++ 请求串行化（D1）：`execute()` 全局 `request_mutex` 覆盖 spawn + join；并发 execute 安全（impl_ 无竞争、同一 CURL handle 不跨线程——libcurl 官方要求）。测试：两线程并发 execute 断言串行
- [x] 8.2 C++ 取消支持（D7）：新增 FFI `cancel_request()`——atomic 标志 + curl XFERINFO 检查快速返回 CURLE_ABORTED_BY_CALLBACK + 取消路径由 curl 线程发 on_done(-1,"cancelled")（join 前）；无活动请求时 no-op。测试：取消后 execute 快速返回 + on_done(-1)
- [x] 8.3 C++ done 幂等：done_dispatched 在 push done 事件时互斥检查（[DONE] 与 message_stop 双触发只发一次 on_done）。测试：真实 fixture（message_stop + [DONE] 并存）断言 on_done 恰好一次
- [x] 8.4 Dart 门禁（D3b）：SidecarBridge 串行化新请求（上一请求 done 未处理或未取消完成时排队）
- [x] 8.5 Dart 超时改取消（F6）：120s 超时路径调用 cancel_request() + 等待取消 done 后 close callables 并完成 Future；不伪造 onDone
- [x] 8.6 Dart Completer 幂等（F5）：重复 done 忽略，无 StateError
- [x] 8.7 Dart 持久化过滤（F4/RTD-1）：turnThinkingBlocks 只累积最终 thinking 事件；thinking_delta 不落库、不回灌 API（_buildApiMessages 不含 thinking_delta 块）
- [x] 8.8 Dart index 当前轮作用域（F3）：增量查找限定当前轮，不跨轮匹配；重建与 turn 完成转换按数组序派生 index（RTD-2），旧数据无 index 兼容
- [x] 8.9 spec 显式折叠条款落地（RTD-3）：streaming 中折叠卡片不自动展开、turn 完成不改变折叠状态（对应测试 5.8）
- [x] 8.10 C++ 测试补齐：并发串行化（8.1）、取消（8.2）、done 幂等（8.3）、多块 thinking + tool_use 混合流的增量/最终事件顺序
- [x] 8.11 Dart 测试补齐：门禁串行、幂等 done、delta 不持久化、跨轮 index、重建派生（5.5-5.8 之外的门禁/幂等测试）
- [x] 8.12 Live 实测（DSK-STREAM-EVENTS）：DeepSeek 端点增量行为实测（6.1 已含）——确认 thinking_delta 真实下发或记录退化路径
- [x] 8.13 更新 design/spec/实现一致性：wire 映射注释、持久化过滤、index 派生与 design D4/D6/D8、specs 一致
- [x] 8.14 运行全部测试：C++ sidecar_tests 全部通过、Dart flutter test 全部通过、live 4/4
- [x] 8.15 Honesty Review（Round 1）：Workflow 对抗验证——外部正确性（MCP + URL 引用）+ 内部一致性 + 用户需求对照（流式恢复、折叠用户控制、历史可浏览）。发现问题追加新任务并立即修复。

## 9. Round 2 Fixes（实现审查 Workflow 发现）

- [x] 9.1 错误/取消路径 thinking 卡片卡死（RTD-BUG-B/CANCEL-STUCK-CARD）：`_endStreaming()` 把残留 ChatThinkingItem 转 isStreaming=false（保留内容）——消除无限动画点 + 下一轮 index 0 delta 命中卡死卡片的跨轮碰撞
- [x] 9.2 index 随事件持久化 + 回灌 API（RTD-BUG-A/F2）：Dart 侧在 turnThinkingBlocks.add 前与 _buildApiMessages 回灌前剥离 `index` 键（D6"index 非持久化字段"语义对齐；旧数据含 index 的同样剥离）
- [x] 9.3 30s fallback 伪造 done（fallback-fake-done/F1）：fallback 路径不 close callables（仅 complete + onDone(-1)）——消除"curl 线程可能存活时 close = UB"窗口；注释记录权衡
- [x] 9.4 message_stop 后残留回调（post-done-callbacks-unguarded）：write_callback 解析循环在 done_dispatched 后停止处理（非合规服务端防御）
- [x] 9.5 会话切换取消污染历史（F3）：doneError=='cancelled' 且 _currentId != sessionId 时跳过 _storeError 落库
- [x] 9.6 worker 异常快速失败（F4）：_workerMain 外层 try/catch，异常时经 onDone 指针投递 done(-1, error)——门禁即时放行而非 150s 卡顿
- [x] 9.7 onThinking 显式 type 检查（RTD-BUG-C）：final 分支要求 type=='thinking'，未知类型记录日志不持久化
- [x] 9.8 文档修正（d7-spec-text-drift + deepseek-done-marker-claim）：design.md D7 + model-gateway spec 取消条款改为"join 后 FFI 线程发出（实测依据）"；"[DONE] 双触发"表述改为"自建 fixture + live 实测"而非官方依据
- [x] 9.9 验证状态记录（adaptive-thinking-unverified + ext-verify-blocked）：design 记录 adaptive+display+summarized 格式有 live 实证但 DeepSeek 官方文档未记载（thinking_mode 文档记载 reasoning.effort 机制）；MCP 配额恢复（2026-08-22）后复核 5 个 URL 的遗留项
- [x] 9.10 重跑全部测试：C++ sidecar_tests、Dart flutter test、live 4/4；新增错误路径卡死卡片与跨轮碰撞回归测试（widget）
- [x] 9.11 Honesty Review（Round 2）：Workflow 对抗验证 Round 2 修复。发现问题追加新任务并立即修复。

## 10. Round 3 Fixes（Round 2 审查 Workflow 发现）

- [x] 10.1 9.6 快速失败路径双缺陷（R2-F1/9.6-worker-*）：catch 块 errPtr **不 free**（故意泄漏，与 pending_strings 生命周期一致——NativeCallable listener 异步读）+ stopReason 传非 null 空串（ffi 2.2.0 toDartString 对 nullptr 抛 UnsupportedError → finish 不被调 → 门禁不释放）；修正 sidecar_bridge.dart 中"toDartString on nullptr = ACCESS_VIOLATION"的过时注释
- [x] 10.2 9.5 取消守卫竞态（R2-F2）+ 文案替换失效（9.3-b）：改为基于 `_cancelSwitchSessionId` 标志（_selectSession/_newChat/_deleteSession 切换时记录旧 sessionId；doneCode!=0 分支：doneError=='cancelled' 或 _cancelSwitchSessionId==sessionId → 跳过落库并清标志）——A→B→A 竞态与 timedOut 文案替换均不失效
- [x] 10.3 fallback 触发加日志（9.3-a）：fallback 分支 print 专用文案（取消路径失败可见），且 finish 文案替换不影响 fallback 标识
- [x] 10.4 补 9.5 widget 测试（R2-F3）：流式时切换会话 → 旧会话无 'Error: cancelled' 卡片（FakeSidecar cancelCount + queueDone(-1,'cancelled')）
- [x] 10.5 lost-cancel 窗口记录（r2-f3）：design 记录"cancel_request 在 execute 重置 cancel_flag 前调用会被吞（worker-startup 窗口），请求正常完成落库"为已知边缘（低严重度，与旧行为一致）
- [x] 10.6 重跑全部测试：C++ sidecar_tests、Dart flutter test、live 4/4
- [x] 10.7 Honesty Review（Round 3 — 最终）：Workflow 对抗验证 Round 3 修复 + 用户需求终检。发现问题追加新任务并立即修复。

## 11. Round 4 Fixes（Round 3 最终审查 Workflow 发现）

- [x] 11.1 标志残留 + 旧 done 干扰新请求（R3-F1/RTD-10.2-STALE-FLAG/R3-F6）：doneCode==0 路径开头检测 `_cancelSwitchSessionId == sessionId` → 清标志（wasSwitchCancelled）；该轮所有 `_endStreaming()` 调用改为 `if (_currentId == sessionId && !wasSwitchCancelled)`——切换取消的旧请求以成功完成时既不残留标志（后续真实错误不被误跳过），也不清掉用户已切回并新发的请求的流式状态
- [x] 11.2 注释修正（R3-F3）：_webWorkerMain 中 'ACCESS_VIOLATION if toDartString() called on nullptr' 过时注释改为 ffi 2.2.0 实际行为（UnsupportedError）
- [x] 11.3 fallback 残余窗口补注释（R3-F2）：9.3/10.3 注释补记 pending_strings 生命周期洞（fallback 打破 D3 屏障后，卡死请求最终完成时 stable_str 压入的字符串可能被下一请求清空——已接受为低概率边缘，注释记录）
- [x] 11.4 FakeSidecar 扩展 gate + 真实切换会话测试（R3-F4）：FakeSidecar 支持挂起事件流（Completer gate）；测试：流式时切换会话 → 放行 cancelled done → 断言旧会话无 Error 卡片 + cancelCount>0
- [x] 11.5 chat-ui spec 补条款（R3-F5）：'Session-switch cancellation does not persist error cards' requirement
- [x] 11.6 重跑全部测试：C++ sidecar_tests、Dart flutter test、live 4/4
- [x] 11.7 Honesty Review（Round 4 — 收尾）：Workflow 对抗验证 11.x 修复。若 clean 则结束，否则继续修复。

## 12. Round 5 Fixes（Round 4 收尾审查 Workflow 发现）

- [x] 12.1 多轮 stale 循环中止（RTD-R4-01）：`_callModel` while(true) 循环开头检查 `_currentId != sessionId → return`（用户切换会话 = 中止整个调用的剩余工具轮次——替代一次性标志，无竞态；A→B→A 切回后继续属合理语义）
- [x] 12.2 错误路径 _endStreaming 守卫（RTD-R4-02）：doneCode!=0 分支重排——先算 switchCancelled（标志或文案），守卫 `_endStreaming`（`!switchCancelled`），再判跳过
- [x] 12.3 live 增量测量修正（RTD-R4-03）：bodyTexts 过滤排除头部文本（含 '· ' 或 'chars'）——display:omitted 降级路径不再误报 PASS
- [x] 12.4 补测试（RTD-R4-04）：lost-cancel 场景（gate + 切换 + done(0) → 成功路径清标志 + 不 _endStreaming）；循环中止（切换后旧 tool 循环第二轮不执行）
- [x] 12.5 删除遗留 stop_reason debugPrint（LEFTOVER-STOP-REASON-DEBUGPRINT）
- [x] 12.6 重跑全部测试：C++ sidecar_tests、Dart flutter test、live 4/4
- [x] 12.7 Honesty Review（Round 5 — 收尾）：Workflow 对抗验证 12.x 修复。若 clean 则结束，否则继续修复。

## 13. Round 6 Fixes（Round 5 收尾审查 Workflow 发现）

- [x] 13.1 12.1 中止路径清 flag（cancel-flag-leak-on-loop-abort）：`_currentId != sessionId` 裸 return 前清 `_cancelSwitchSessionId`（工具间隙切换无 done 会来清——该路径 flag 语义无意义；不清则切回后新请求真实错误被误判丢弃 + _isStreaming 卡 true）
- [x] 13.2 补 12.2 守卫测试（F2）：A→B→A 快速切回 + 新消息 + 过期 cancelled done——断言新请求流式状态不被拆除（无错误卡片、请求正常完成）
- [x] 13.3 修正 12.1 注释（F3）：诚实记录"切回后旧循环继续使用发送时消息快照（不含切回后新消息）"为已知边界，不声称覆盖
- [x] 13.4 删除 doneStopReason 死代码（F4）
- [x] 13.5 C++ 日志级别（info-level-wire-diagnostics）：request body 与 SSE 逐事件日志降为 LOG_TRACE（隐私 + DEBUGGING.md 一致性——文档"DEBUG level"与实际 logger 无 DEBUG 级矛盾，同步修正 DEBUGGING.md）
- [x] 13.6 _callModel 异常恢复（streaming-flag-exception-residue）：_sendMessage 包 try/catch——_callModel 抛异常时 _endStreaming 恢复 _isStreaming（防永久封锁发送）
- [x] 13.7 重跑全部测试：C++ sidecar_tests、Dart flutter test、live 4/4
- [x] 13.8 Honesty Review（Round 6 — 收尾）：Workflow 对抗验证 13.x 修复。若 clean 则结束，否则继续修复。

## 14. Round 7 Fixes（Round 6 收尾审查 Workflow 发现）

- [x] 14.1 content_block_delta text 漏转 TRACE（R6-01/F1——唯一漏网的逐事件日志，含完整对话文本，隐私）
- [x] 14.2 删除 13.2 测试（R6-02/F2——FakeSidecar 单槽 gate 机制错误，测试制造的状态真实架构不可达）
- [x] 14.3 flag 生命周期统一（R6-03/F3）：13.1 改条件清除（if flag==sessionId）；_sendMessage 开头清 flag（A→B→A 切回后 stale flag 不误判新请求错误）
- [x] 14.4 13.6 catch 清 flag（R6-04）
- [x] 14.5 C++ Impl::last_error 死字段删除（F4）
- [x] 14.6 DEBUGGING.md FFI Tracing 节更新（F6——旧 dispatch_events 日志行已不存在）
- [x] 14.7 cancelled 标记 = !done_dispatched（F5——成功流完成后 _endStreaming 的 cancelRequest abort 收尾传输不再误标 "cancelled"，日志恢复排障价值）
- [x] 14.8 重跑全部测试：Dart flutter test 149/149；C++ sidecar_tests 173/174（唯一失败 = ZhipuAI live 网络不可达，环境性外部依赖，非代码回归——Kimi live 同报连接错误）；live 4/4 已实测
- [x] 14.9 Honesty Review（Round 7 — 收尾）：Workflow 对抗验证 14.x 修复。若 clean 则结束，否则继续修复。

## 15. Round 8 Fixes（Round 7 收尾审查 Workflow 发现）

- [x] 15.1 epoch 代际重构（RTD-14.3-14.7-REGRESSION 根治）：删除 `_cancelSwitchSessionId`，改为 `_requestEpoch`/`_switchEpoch`——`_sendMessage` 递增 epoch 传入 `_callModel`；切换时 `_switchEpoch = _requestEpoch`；循环开头 + tool 分支前检查 `_switchEpoch >= epoch`（被切换过的调用无论是否切回一律中止——消除 13.3 边界 + 迟到 turn2 拆除新请求的回归 + F3 误判）；错误卡片抑制用 `_switchEpoch >= epoch || doneError=='cancelled'`
- [x] 15.2 ffi-bridge spec last_error 残留引用更新（RTD-14.5）：spec.md:76 改为描述 pending_strings 机制
- [x] 15.3 model-gateway spec 取消条款补限定（RTD-14.7）：on_done(-1,"cancelled") SHALL 限定"其 done 尚未派发"；场景补"cancel during active stream whose done has not yet been dispatched"
- [x] 15.4 tasks.md 14.8 诚实修正（RTD-14.8/F1）："C++ sidecar_tests 173/174（唯一失败 ZhipuAI live 网络不可达，环境性）"；live 4/4 已实测
- [x] 15.5 tool 副作用中止（F2）：切换后已收到的 tool_use 不再执行（tool 分支前 epoch 检查）——write_file 等副作用工具不落盘
- [x] 15.6 ffi_tracing_test.cpp:33 注释更新（F3）
- [x] 15.7 清理调试残留（F4）：删除 `_cxx_test_output.txt`、`_d9_log2.txt`
- [x] 15.8 重跑全部测试：C++ sidecar_tests、Dart flutter test、live 4/4
- [x] 15.9 Honesty Review（Round 8 — 收尾）：Workflow 对抗验证 15.x 修复。若 clean 则结束，否则继续修复。

## 16. Round 9 Fixes（Round 8 收尾审查 Workflow 发现）

- [x] 16.1 成功路径 epoch 守卫（E1）：doneCode==0 分支 wasSwitchCancelled 时直接 return（不 insert 过期回复、不渲染、不转换卡片）
- [x] 16.2 回调层 epoch 检查（E2）：onChunk/onToolCall/onThinking 渲染前检查 `_switchEpoch >= epoch`（迟到回调不渲染垃圾）
- [x] 16.3 tool 循环逐工具 epoch 检查（E3/F3）：批次内每个 _executeTool 前检查——切换后同批后续副作用工具不执行
- [x] 16.4 catch epoch 守卫（E4）：13.6 catch 仅当 `_switchEpoch < epoch`（本调用未被切换）才 _endStreaming——被切换旧调用的异常不杀新请求
- [x] 16.5 文档修正（E5/F2）：design.md 补 15.1 epoch 条目 + 10.5"无害"论断修正 + 67c/103 行取消投递方表述；chat-ui spec:23 flag 机制改为 epoch
- [x] 16.6 epoch 语义回归测试（E6/F1）：A→B→A 切回 + 迟到 done(0) 不干扰新请求（用 FakeSidecar gate + tool 循环构造）；12.4a 标题修正
- [x] 16.7 重跑全部测试：C++ sidecar_tests、Dart flutter test、live 4/4
- [x] 16.8 Honesty Review（Round 9 — 最终收尾）：Workflow 对抗验证 16.x 修复。达到 10 轮上限后输出最终审查报告。

## 17. Round 10 Fixes（第 10 轮上限审查 Workflow 发现——修复后输出最终报告）

- [x] 17.1 FakeSidecar gate 改 per-send（fake-sidecar-gate-broadcast/FINAL-R10-02）：sendMessage 弹出自己的门（`final g = _gates.removeAt(0); await g.future;`）——按文档语义逐个放行，不依赖隐式 listener 顺序
- [x] 17.2 补 stale 无 tool_call 轮测试（16.6-does-not-discriminate）：stale 轮仅 chunk+done → 断言 stale 回复未落库 + 新请求流式卡片存活（覆盖 16.1/16.2 修复面）
- [x] 17.3 design.md 补 epoch 决策条目（design-epoch-entry-missing）——D9
- [x] 17.4 dispatch_done 注释修正（dispatch-done-comment-stale）：注明 curl 线程（流内）与 FFI 线程（join 后）双投递方
- [x] 17.5 _sendMessage sessionId/epoch 捕获提前（FINAL-R10-01）：用户消息 insert 前捕获——切换发生在 insert/标题更新 await 期间时消息不落到错误会话、epoch 关联不丢
- [x] 17.6 重跑全部测试：C++ sidecar_tests、Dart flutter test、live 4/4
