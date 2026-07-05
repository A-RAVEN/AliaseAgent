## 1. 代码清理

- [x] 1.1 `_loadSessions` 增加 `mounted` 检查：在 `await _sessionRepo.list()` 之后、`setState` 之前，加 `if (!mounted) return;`（与 `_endStreaming()` / `_storeError` / `_sendMessage` 模式一致）
- [x] 1.2 `_executeTool` catch 改为 `catch (e)` + `debugPrint`：与 task 1.3 对 `onToolCall` / `onThinking` 的处理一致
- [x] 1.3 `_sendMessage` 移除 widget 层重复截断逻辑：`updateTitleIfDefault` 返回 `true` 后直接用 session 中已存的 title 展示，不再在 widget 层重新计算 `text.length > 30 ? ...`。简化 `if (titleUpdated)` 分支，只用 `_sessions.sort(...)` 确保 sidebar 顺序更新
- [x] 1.4 `_loadMessages` happy path 增加 `mounted` 检查：在 `await _msgRepo.queryBySession(...)` 之后、`setState(() => _messages = msgs)` 之前，加 `if (!mounted) return;`（catch path 已有，补 happy path）
- [x] 1.5 `_newChat` 增加 `mounted` 检查：在 `await _sessionRepo.create()` 之后、`_endStreaming()` 之前，加 `if (!mounted) return;`
- [x] 1.6 `_deleteSession` 增加 `mounted` 检查：在 `await _sessionRepo.delete(s.id)` 之后、`wasCurrent` 判断之前，加 `if (!mounted) return;`

### 🔎 Checkpoint: 验收

| # | 验收项 | 通过标准 |
|---|--------|----------|
| A | dispose 后 setState 被拦截 | 快速关闭窗口后 `_loadSessions` 不触发 setState |
| B | _executeTool parse 错误有日志 | 侧车返回非 JSON → `debugPrint` 输出 error |
| C | auto-title 行为不变 | 首条消息后 sidebar 标题正确更新，无重复计算 |
