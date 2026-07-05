## Why

对 Phase 17 (auto-title) + Phase 18.1–18.5 (tool call cards UI) 的 working tree 改动进行了全面的 code review，发现 4 个状态管理 bug 和 6 个清理/效率问题。最严重的问题是 `_deleteSession` 不清除 `_toolActivities` 导致 stale tool cards 泄漏到新会话，以及 async gap 后缺少 `mounted` 检查可能导致 widget dispose 后仍发起 API 调用。应在 Phase 18.6 持久化重构之前修复这些基础问题，避免在重构时把 bug 带进新架构。

## What Changes

### Bug 修复
- `_deleteSession` 增加 `_toolActivities = []` 清理
- `_sendMessage` 的 `_sessionRepo.get()` await 之后增加 `mounted` 检查
- `onToolCall` / `onThinking` 的 `catch (_) {}` 改为至少 `debugPrint` 记录错误
- 空 tool ID fallback 单点赋值（仅 `onToolCall` 一处 `tc['id'] ??=`）
- `_streamingText` 从 `allText` 改为 `turnText`，修复多轮工具调用时 streaming bubble 跨轮文本拼接

### 回归修复（测试中发现）
- **`_selectSession` 切换会话时清空 `_messages`**：`_endStreaming()` 抽离后，`setState` 被拆成两次，`_messages` 在 async `_loadMessages()` 完成前保留旧会话数据。若用户在此窗口内发送消息，`snapMessages` 捕获错误历史，导致跨会话内容污染
- **`_deleteSession` 嵌套 `setState` 修正**：`_endStreaming()` 当前在外层 `setState` 内部调用，移出以避免嵌套
- **`_loadMessages` 增加错误处理**：DB 查询失败时静默保留旧 `_messages`，导致错误会话内容持续显示
- 空 tool ID 兜底逻辑：当 `tc['id']` 为空时生成 fallback ID 而非用空字符串

### 清理
- 提取 `_endStreaming()` 方法，消除 7 处重复的 `_isStreaming = false; _streamingText = ''; _toolActivities = [];`
- Auto-title 逻辑下沉到 `SessionRepository.updateTitleIfDefault()`
- 单条 title 更新后 patch 本地 `_sessions` 列表而非全量重载

### 效率
- streaming 中改用 `jumpTo` 替代 `animateTo`，避免频繁动画冲突
- tool 执行结果批量更新后一次 `setState`，而非每个 tool 各触发一次

## Capabilities

### New Capabilities
（无 — 本次为纯 bug 修复和代码清理，不引入新功能）

### Modified Capabilities
（无 — 不改变任何 spec 级别的行为需求）

## Impact

- `lib/main.dart` — `_ChatScreenState`：状态清理路径、mounted 检查、工具调用错误处理
- `lib/ui/chat_area.dart` — `_ChatAreaState`：auto-scroll 动画策略
- `lib/services/session_repository.dart` — 新增 `updateTitleIfDefault()` 方法
