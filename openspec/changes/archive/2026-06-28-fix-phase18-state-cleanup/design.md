## Context

Code review 发现 Phase 17/18.1–18.5 的改动中存在 4 个 bug 和 6 个清理/效率问题。这些改动集中在 `_ChatScreenState`（`lib/main.dart`）和 `_ChatAreaState`（`lib/ui/chat_area.dart`）两个 State 类，不涉及跨模块架构变更。修复策略：bug 逐个修，清理问题通过提取 `_endStreaming()` 统一处理，效率问题采用最小改动方案。

## Goals / Non-Goals

**Goals:**
- 消除 4 个已知 bug：stale tool cards 泄漏、缺 mounted 保护、静默 catch、空 ID 碰撞
- 消除 7 处重复的状态重置代码
- 减少 streaming 期间的无效 rebuild 和动画冲突
- 将 auto-title 业务规则从 widget 层下沉到 repository 层

**Non-Goals:**
- 不改变 ChatArea 的三列表接口（Phase 18.10 的 ChatItem 统一重构会解决这个问题）
- 不实现 tool call 持久化（Phase 18.6–18.10）
- 不引入新的状态管理框架

## Decisions

### D1: 提取 `_endStreaming()` 而非内联重置

**选择**: 在 `_ChatScreenState` 中新增 `void _endStreaming()` 方法：
```dart
void _endStreaming() {
  if (!mounted) return;
  setState(() {
    _isStreaming = false;
    _streamingText = '';
    _toolActivities = [];
  });
}
```
**替代方案**: 保持现状或创建独立的 `StreamingState` 类 — 后者过度设计，因为 Phase 18.10 的 ChatItem 重构会从根本上改变状态管理。

### D2: Auto-title 下沉到 repository

**选择**: 在 `SessionRepository` 新增 `updateTitleIfDefault(sessionId, text)` 方法，封装 "New Chat" 判断 + 30 字符截断逻辑。
**替代方案**: 保留在 widget 层 — 但业务规则放在 widget 层会因入口分散（快捷键、语音输入等未来功能）而产生 bug。

### D3: streaming 滚动改用 `jumpTo`

**选择**: 在 `didUpdateWidget` 中，当 `isStreaming` 为 true 时将 `animateTo`（150ms）替换为 `jumpTo`（瞬时）。非 streaming 的增量滚动（新消息到达）保留 `animateTo` 以获得平滑体验。
**替代方案**: 节流 debounce — 增加复杂度，不如直接区分场景。

### D4: 空 tool ID 生成 fallback

**选择**: 当 `tc['id']` 为空时，**仅在 `onToolCall` 回调中**通过 `tc['id'] ??= 'tool_${turn}_${turnToolCalls.length}'` 对 `tc` map 做原位赋值。后续工具执行循环直接用 `tc['id']` 取值，**不重复计算** ID。
**为什么不能在两处分别计算**: `onToolCall` 逐条触发时 `turnToolCalls.length` 递增（1, 2, 3...），工具执行循环时 `turnToolCalls.length` 已是最终值（常量），两处算出不同 ID 会导致 `indexWhere` 全部匹配到最后一张卡片。
**替代方案**: 直接丢弃无 ID 的 tool call — 但模型已经发出了 tool_use，丢弃会导致 tool_use 无对应 tool_result，违反 API 协议。

### D5: Tool 结果批量 setState

**选择**: 移除 `for` 循环中每个 tool 的 `setState`，改为在所有 tool 执行完毕后统一调用一次。
**替代方案**: 保留逐个 setState — 无任何好处，N 个 tool 产生 N 次无效重建。

### D6: `_streamingText` 按轮显示（对抗验证发现）

**选择**: 将 `_streamingText = allText` 改为 `_streamingText = turnText`，streaming bubble 只显示当前轮次文本。
**原因**: `allText` 跨 tool loop turn 累积，中间轮次若产生文本会拼接到后续轮次的 streaming 显示中（如 "让我读取文件" + "文件内容是 hello" → "让我读取文件文件内容是 hello"）。`turnText` 每轮重置（task 10.1 已修复存储侧，此为显示侧的对应修复）。
**替代方案**: 每轮开始时 `allText = ''` 清零 — 但 `allText` 若被其他地方引用（如最终存储逻辑）则需额外检查，不如直接用 `turnText` 隔离。

### D7: `_selectSession` 中同步清空 `_messages`（回归修复）

**选择**: 在 `_selectSession` 的 `setState` 中增加 `_messages = []`，与 `_currentId = s.id` 同帧执行。
**原因**: `_endStreaming()` 抽离后，`_selectSession` 拆成两个 `setState`（先清 streaming state，再设新 session）。第二个 `setState` 更新了 `_currentId` 但没清 `_messages`，然后异步 `_loadMessages()` 才加载新数据。在这个 async gap 中，UI 显示新 session 的标题 + 旧 session 的消息。若用户在此期间发送消息，`_sendMessage` 的 `snapMessages` 捕获到错误会话的历史。
**替代方案**: 合并 `_endStreaming()` 和 session 切换回单个 `setState` — 但会失去 `_endStreaming()` 的复用价值。直接在 `_loadMessages` 开头清空 `_messages` — 但先设 `_currentId` 后清空 `_messages` 的顺序不如一起做。

### D8: `_deleteSession` 中 `_endStreaming()` 移出外层 setState（回归修复）

**选择**: `_endStreaming()` 仍在 `wasCurrent` 分支内调用，但在外层 `setState` **之前**独立执行（与 `_selectSession`、`_newChat` 一致）。
**原因**: 当前 `_endStreaming()` 在 `setState(() { ... _endStreaming(); ... })` 内被调用，造成嵌套 `setState`。Flutter 不会 crash 但依赖实现细节，不是规范用法。移出后代码更清晰。
**替代方案**: 移到 `setState` 之后 — 等价，但与其他两个调用点（`_selectSession` 行 184、`_newChat` 行 193）的 before-setState 模式不一致。

### D9: `_loadMessages` 增加错误处理（回归修复）

**选择**: 将 `final msgs = await _msgRepo.queryBySession(_currentId!)` 包裹在 try-catch 中，catch 时 `setState(() => _messages = [])` 清空列表。
**原因**: D7 已在所有调用点（`_selectSession`、`_deleteSession`）同步清空 `_messages = []`，D9 提供 catch 内的冗余防御——若未来新增调用路径漏了 D7 的清空，或 DB 查询在清空后、返回前失败，catch 块确保 `_messages` 始终被清空。同时提供 `debugPrint` 错误日志用于诊断。catch 内先 `if (!mounted) return;` 再 `setState`，与 `_endStreaming()` 保持一致。
**替代方案**: 不处理，完全依赖 D7 — 但缺少 error logging 会掩盖 DB 故障。

### D10: `onToolCall` / 工具结果增加会话守卫（对抗验证发现）

**选择**: 将 `_toolActivities.add(...)` 包裹在 `if (_currentId == sessionId)` 中；将 `_toolActivities[idx] = ...` 包裹在 `if (_currentId == sessionId && idx >= 0)` 中。
**原因**: 当前 `onToolCall` 回调（行 358）无条件修改 `_toolActivities`，仅在 `setState`（行 363）处检查会话守卫。用户切换会话后，旧会话的回调仍可污染 `_toolActivities` 列表，下一次任何来源的 `setState` 都会渲染错误数据。`_endStreaming()` / `_sendMessage` 会在后续自动清空（transient corruption），但应在源头防止。
**替代方案**: 依赖现有 `setState` 守卫 — 但 `setState` 守卫仅阻止 rebuild，不阻止数据写入 `_toolActivities`。下一次 rebuild 时污染仍然可见。

## Risks / Trade-offs

- **[R] `jumpTo` 滚动可能感觉突兀** → Mitigation：仅在 `isStreaming` 时用 `jumpTo`（文本在逐字增长，用户注意力在文字上，不会感知到滚动动画缺失）。新消息到达时的滚动仍用 `animateTo`。
- **[R] `_endStreaming()` 被某路径遗忘调用** → Mitigation：方法名清晰，review 时容易发现。Phase 18.10 的 ChatItem 统一列表会从根上消除这个问题。
- **[R] `_endStreaming()` 是临时代码** → Mitigation：方法声明加 `// NOTE: Will be refactored in Phase 18.9` 注释，提醒后续开发者。
- **[R] `allText` 改为 `turnText` 可能影响其他引用** → Mitigation：`allText` 仅用于 `_streamingText` 赋值和最终存储的 content。存储逻辑已由 task 10.1 修复使用 `turnText`，本次仅修复显示侧的一致性。
- **[R] `_messages = []` 后 `_loadMessages` 失败导致空列表** → Mitigation：D9 的 try-catch 覆盖了 DB 失败场景。另外 `_newChat` 也设 `_messages = []` 且不加载 DB（新会话无历史），行为一致。
- **[R] `_endStreaming()` 移出 setState 后多一次 rebuild** → Mitigation：与 D1 已接受的 trade-off 一致，Phase 18.9 会整体重构。
- **[R] Abandoned `_callModel` callbacks continue running** → 旧会话的 `sendMessage` 无法被取消（C FFI 在 worker isolate 上阻塞，Dart 没有取消原语）。`onChunk` / `onToolCall` / `onThinking` / `onDone` 回调会继续触发，所有状态变更必须通过 `_currentId == sessionId` 守卫。D10 + Section 5.4/5.5 修复了 `_toolActivities` 的守卫遗漏。
