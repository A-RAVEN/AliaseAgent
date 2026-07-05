## 1. Bug 修复

- [x] 1.1 `_deleteSession` 增加 `_toolActivities = []`：在 `wasCurrent` 分支中，与 `_messages = []` / `_isStreaming = false` / `_streamingText = ''` 并列添加 `_toolActivities = []`
- [x] 1.2 `_sendMessage` async gap 后增加 `mounted` 检查：在 `_sessionRepo.get()` 返回后，调用 `_loadSessions()` 和 `_callModel()` 之前，检查 `if (!mounted) return;`
- [x] 1.3 `onToolCall` / `onThinking` 的 `catch (_)` 改为 `catch (e)` 并 `debugPrint` 记录错误和原始 JSON
- [x] 1.4 空 tool ID 生成 fallback：**仅在 `onToolCall` 一处**通过 `tc['id'] ??= 'tool_${turn}_${turnToolCalls.length}'` 设置 fallback ID，后续工具执行循环直接使用 `tc['id']` 取值，**不在两处重复计算**（两处 `turnToolCalls.length` 值不同会导致 ID 不一致，所有结果 match 到最后一张卡片）
- [x] 1.5 `_streamingText` 跨 tool turn 累积修复：将 `_streamingText = allText` 改为 `_streamingText = turnText`，仅显示当前轮次文本而非跨轮拼接（多轮工具调用时中间轮次的文本会拼入 `allText` 但不应该出现在 streaming bubble 中）

### 🔎 Checkpoint 1: Bug 修复验收

| # | 验收项 | 通过标准 |
|---|--------|----------|
| A | 删除会话清除 tool cards | 含 tool cards 的会话 → 删除 → 新会话不显示 stale cards |
| B | dispose 后不调 API | 快速切换/关闭窗口不触发 sidecar 调用 |
| C | JSON parse 错误有日志 | 模拟畸形 JSON → `debugPrint` 输出 error + raw JSON |
| D | 空 ID 不碰撞 | 多个无 ID tool call → 每个独立显示结果，不互相覆盖 |
| E | streaming text 按轮显示 | 多轮工具调用 → streaming bubble 只显示当前轮次文本，不显示前轮拼接 |

## 2. 状态清理统一

- [x] 2.1 提取 `_endStreaming()` 方法：在 `_ChatScreenState` 中新增方法，包含 `mounted` 检查 + `setState` 内清除 `_isStreaming` / `_streamingText` / `_toolActivities`；方法声明上方加注释 `// NOTE: Will be refactored in Phase 18.9 when _chatItems replaces separate lists`
- [x] 2.2 替换所有手动重置：`_selectSession`、`_newChat`、`_deleteSession`、`_callModel` 的 6 个清理点全部改用 `_endStreaming()`

### 🔎 Checkpoint 2: 状态清理验收

| # | 验收项 | 通过标准 |
|---|--------|----------|
| A | 所有路径状态正确清除 | 正常完成 / 错误 / 切换会话 / 新建 / 删除会话后均无残留 streaming 状态 |
| B | 添加新状态字段只需一处 | 搜索 `_toolActivities = []` 只有 `_endStreaming()` 一处 |

## 3. Auto-Title 下沉

- [x] 3.1 `SessionRepository` 新增 `updateTitleIfDefault(sessionId, text)`：封装 `get` → 检查 `title == 'New Chat'` → 截断 30 字符 → `updateTitle`
- [x] 3.2 `_sendMessage` 中调用 `updateTitleIfDefault()` 替代内联逻辑；title 更新后 patch 本地 `_sessions` 列表对应条目的 `title` 字段 + `_sortSessions()`，替代 `_loadSessions()` 全量重载

### 🔎 Checkpoint 3: Auto-Title 验收

| # | 验收项 | 通过标准 |
|---|--------|----------|
| A | 功能行为不变 | 新会话首条消息自动生成标题，超 30 字符截断 |
| B | 非首条不触发 | title 已非 "New Chat" 时不再查询 DB |
| C | Sidebar 即时更新 | 标题更新后 sidebar 显示新标题，无延迟 |

## 4. 效率优化

- [x] 4.1 streaming 滚动改用 `jumpTo`：在 `ChatArea.didUpdateWidget` 中，当 `isStreaming` 为 true 时使用 `jumpTo(maxScrollExtent)` 替代 `animateTo`（非 streaming 的增量滚动保留 `animateTo`）
- [x] 4.2 tool 结果批量 setState：在 `_callModel` 工具执行循环中，移除每个 tool 的 `setState` 调用，改为在所有 tool 执行完毕后统一 `setState` 一次

### 🔎 Checkpoint 4: 效率验收

| # | 验收项 | 通过标准 |
|---|--------|----------|
| A | streaming 滚动不闪烁 | 快速 streaming 时滚动流畅，无动画冲突 |
| B | tool 结果仅一次 setState | 多 tool 调用的 streaming 完成时，仅一次 widget rebuild |
| C | 非 streaming 滚动保持动画 | 新消息到达时仍然有平滑滚动动画 |

## 5. 回归修复（测试中发现）

> 测试发现了 3 个由 `_endStreaming()` 抽离引发的回归问题：切换会话时 `_messages` 在 async gap 间泄漏旧数据、删除会话时嵌套 `setState`、以及 `_loadMessages` 无错误处理。

### 问题：`_selectSession` async gap 跨会话泄漏

`_selectSession` 拆成两个 setState 后，`_currentId` 更新了但 `_messages` 在 `_loadMessages()` 完成前保留旧会话数据。UI 短暂显示"B 的标题 + A 的消息"。若用户在此窗口发送消息，`snapMessages` 捕获到错误的会话历史，API 请求带错上下文。

- [x] 5.1 `_selectSession` 增加 `_messages = []`：在 `setState` 内与 `_currentId = s.id` 同帧执行，确保异步 `_loadMessages` 完成前不显示旧会话数据

### 问题：`_deleteSession` 嵌套 setState

`_endStreaming()` 当前在 `setState(() { ... _endStreaming(); ... })` 内部被调用，造成嵌套 setState 调用。

- [x] 5.2 `_deleteSession` 移出 `_endStreaming()`：将 `_endStreaming()` 从外层 `setState` 回调内移出，在 `wasCurrent` 分支中独立调用（在外层 setState 之前，与 _selectSession / _newChat 一致）

### 问题：`_loadMessages` 无错误处理

`_msgRepo.queryBySession()` 无 try-catch。DB 查询失败时异常被 async zone 吞掉，`_messages` 保持旧值永不更新——这是最严重的跨会话污染形式（永久性的，不是暂时闪烁）。

- [x] 5.3 `_loadMessages` 增加 try-catch：将 `queryBySession` 包裹在 try-catch 中，catch 时先 `if (!mounted) return;` 再 `setState(() => _messages = [])` 清空列表（含 `debugPrint` 记录错误），避免永久显示错误会话数据

### 问题：`onToolCall` / 工具结果无条件修改 `_toolActivities`，跨会话泄漏

`_callModel` 的 `onToolCall` 回调（行 358）无条件执行 `_toolActivities.add(...)`，仅在 `setState`（行 363）处检查 `_currentId == sessionId`。工具结果更新（行 436）同样无守卫。当用户在 API 响应进行中切换会话时，旧会话的回调仍可修改 `_toolActivities`，下次任何来源的 `setState` 都会渲染被污染的列表——会话 B 的 UI 中出现会话 A 的工具卡片。此问题会在下次 `_endStreaming()` 或 `_sendMessage` 时自动修复（transient UI corruption），但应在源头防止。

- [x] 5.4 `onToolCall` 增加会话守卫：将 `_toolActivities.add(...)` 包裹在 `if (_currentId == sessionId)` 中
- [x] 5.5 工具结果更新增加会话守卫：将 `_toolActivities[idx] = ...` 包裹在 `if (_currentId == sessionId && idx >= 0)` 中

### 🔎 Checkpoint 5: 回归修复验收

| # | 验收项 | 通过标准 |
|---|--------|----------|
| A | 切换会话不泄漏消息 | 会话 A 有消息 → 切换到空会话 B → UI 立即显示空列表（不是 A 的消息），然后加载 B 的真实消息 |
| B | 切换后立即发送不串消息 | 会话 A 有消息 → 切换到 B → 不等加载完成就发送 "你好" → API 请求中不含 A 的历史 |
| C | 删除会话无嵌套 setState | 删除当前会话时，`_endStreaming()` 不在任何外层 `setState` 回调内调用（可通过断点或代码审查验证） |
| D | DB 错误时清空列表 | 模拟 DB 查询失败 → `_messages` 清空为 `[]` 而非保留旧值 |
| E | 切换会话不泄漏工具卡片 | 会话 A 有 in-flight tool call → 切换到 B → B 的 UI 不显示 A 的工具卡片 |
| F | 工具结果不泄漏 | 会话 A 的工具执行结果不更新到会话 B 的 UI |
