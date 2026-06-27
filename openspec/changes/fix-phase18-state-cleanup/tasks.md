## 1. Bug 修复

- [ ] 1.1 `_deleteSession` 增加 `_toolActivities = []`：在 `wasCurrent` 分支中，与 `_messages = []` / `_isStreaming = false` / `_streamingText = ''` 并列添加 `_toolActivities = []`
- [ ] 1.2 `_sendMessage` async gap 后增加 `mounted` 检查：在 `_sessionRepo.get()` 返回后，调用 `_loadSessions()` 和 `_callModel()` 之前，检查 `if (!mounted) return;`
- [ ] 1.3 `onToolCall` / `onThinking` 的 `catch (_)` 改为 `catch (e)` 并 `debugPrint` 记录错误和原始 JSON
- [ ] 1.4 空 tool ID 生成 fallback：**仅在 `onToolCall` 一处**通过 `tc['id'] ??= 'tool_${turn}_${turnToolCalls.length}'` 设置 fallback ID，后续工具执行循环直接使用 `tc['id']` 取值，**不在两处重复计算**（两处 `turnToolCalls.length` 值不同会导致 ID 不一致，所有结果 match 到最后一张卡片）
- [ ] 1.5 `_streamingText` 跨 tool turn 累积修复：将 `_streamingText = allText` 改为 `_streamingText = turnText`，仅显示当前轮次文本而非跨轮拼接（多轮工具调用时中间轮次的文本会拼入 `allText` 但不应该出现在 streaming bubble 中）

### 🔎 Checkpoint 1: Bug 修复验收

| # | 验收项 | 通过标准 |
|---|--------|----------|
| A | 删除会话清除 tool cards | 含 tool cards 的会话 → 删除 → 新会话不显示 stale cards |
| B | dispose 后不调 API | 快速切换/关闭窗口不触发 sidecar 调用 |
| C | JSON parse 错误有日志 | 模拟畸形 JSON → `debugPrint` 输出 error + raw JSON |
| D | 空 ID 不碰撞 | 多个无 ID tool call → 每个独立显示结果，不互相覆盖 |
| E | streaming text 按轮显示 | 多轮工具调用 → streaming bubble 只显示当前轮次文本，不显示前轮拼接 |

## 2. 状态清理统一

- [ ] 2.1 提取 `_endStreaming()` 方法：在 `_ChatScreenState` 中新增方法，包含 `mounted` 检查 + `setState` 内清除 `_isStreaming` / `_streamingText` / `_toolActivities`；方法声明上方加注释 `// NOTE: Will be refactored in Phase 18.9 when _chatItems replaces separate lists`
- [ ] 2.2 替换所有手动重置：`_selectSession`、`_newChat`、`_deleteSession`、`_callModel` 的 6 个清理点全部改用 `_endStreaming()`

### 🔎 Checkpoint 2: 状态清理验收

| # | 验收项 | 通过标准 |
|---|--------|----------|
| A | 所有路径状态正确清除 | 正常完成 / 错误 / 切换会话 / 新建 / 删除会话后均无残留 streaming 状态 |
| B | 添加新状态字段只需一处 | 搜索 `_toolActivities = []` 只有 `_endStreaming()` 一处 |

## 3. Auto-Title 下沉

- [ ] 3.1 `SessionRepository` 新增 `updateTitleIfDefault(sessionId, text)`：封装 `get` → 检查 `title == 'New Chat'` → 截断 30 字符 → `updateTitle`
- [ ] 3.2 `_sendMessage` 中调用 `updateTitleIfDefault()` 替代内联逻辑；title 更新后 patch 本地 `_sessions` 列表对应条目的 `title` 字段 + `_sortSessions()`，替代 `_loadSessions()` 全量重载

### 🔎 Checkpoint 3: Auto-Title 验收

| # | 验收项 | 通过标准 |
|---|--------|----------|
| A | 功能行为不变 | 新会话首条消息自动生成标题，超 30 字符截断 |
| B | 非首条不触发 | title 已非 "New Chat" 时不再查询 DB |
| C | Sidebar 即时更新 | 标题更新后 sidebar 显示新标题，无延迟 |

## 4. 效率优化

- [ ] 4.1 streaming 滚动改用 `jumpTo`：在 `ChatArea.didUpdateWidget` 中，当 `isStreaming` 为 true 时使用 `jumpTo(maxScrollExtent)` 替代 `animateTo`（非 streaming 的增量滚动保留 `animateTo`）
- [ ] 4.2 tool 结果批量 setState：在 `_callModel` 工具执行循环中，移除每个 tool 的 `setState` 调用，改为在所有 tool 执行完毕后统一 `setState` 一次

### 🔎 Checkpoint 4: 效率验收

| # | 验收项 | 通过标准 |
|---|--------|----------|
| A | streaming 滚动不闪烁 | 快速 streaming 时滚动流畅，无动画冲突 |
| B | tool 结果仅一次 setState | 多 tool 调用的 streaming 完成时，仅一次 widget rebuild |
| C | 非 streaming 滚动保持动画 | 新消息到达时仍然有平滑滚动动画 |
