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

## Risks / Trade-offs

- **[R] `jumpTo` 滚动可能感觉突兀** → Mitigation：仅在 `isStreaming` 时用 `jumpTo`（文本在逐字增长，用户注意力在文字上，不会感知到滚动动画缺失）。新消息到达时的滚动仍用 `animateTo`。
- **[R] `_endStreaming()` 被某路径遗忘调用** → Mitigation：方法名清晰，review 时容易发现。Phase 18.10 的 ChatItem 统一列表会从根上消除这个问题。
- **[R] `_endStreaming()` 是临时代码** → Mitigation：方法声明加 `// NOTE: Will be refactored in Phase 18.9` 注释，提醒后续开发者。
- **[R] `allText` 改为 `turnText` 可能影响其他引用** → Mitigation：`allText` 仅用于 `_streamingText` 赋值和最终存储的 content。存储逻辑已由 task 10.1 修复使用 `turnText`，本次仅修复显示侧的一致性。
