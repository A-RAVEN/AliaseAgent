## Context

fix-phase18-state-cleanup 已修复了 14 个状态管理 bug。三轮对抗审查中额外发现 3 个 pre-existing LOW 问题，不严重但应在 chat-agent-window 18.6 重构前修掉。三者均集中在 `_ChatScreenState` 中，不涉及跨模块变更。

## Goals / Non-Goals

**Goals:**
- 补齐 `_loadSessions` 的 `mounted` 守卫，与项目中其他 async gap 后的模式保持一致
- `_executeTool` 的 catch 加 `debugPrint`，与 task 1.3 对 `onToolCall`/`onThinking` 的修复保持一致
- 移除 `_sendMessage` 中 widget 层的重复截断逻辑（`updateTitleIfDefault` 已在 repo 层处理）

**Non-Goals:**
- 不改变任何功能行为
- 不引入新的状态管理方案

## Decisions

### D1: `_loadSessions` 加 mounted 守卫

**选择**: 在 `await _sessionRepo.list()` 之后 `setState` 之前加 `if (!mounted) return;`。
**原因**: 项目中 `_endStreaming()`、`_storeError`、`_sendMessage` 均已采用此模式。`_loadSessions` 是少数遗漏的 async 方法。

### D2: `_executeTool` catch 加 debugPrint

**选择**: `catch (_)` → `catch (e)` + `debugPrint('[AliasAgent] _executeTool parse error: $e')`。
**原因**: 与 task 1.3 的修复一致——`onToolCall` 和 `onThinking` 回调已做了相同处理。保持 `_ChatScreenState` 中所有 catch 块风格统一。

### D3: 移除 `_sendMessage` 中重复的截断逻辑

**选择**: 依赖 `SessionRepository.updateTitleIfDefault()` 返回的 `true` + session 中已存的 title，不再在 widget 层重新计算截断。
**原因**: `updateTitleIfDefault` 已封装了 "检查 New Chat → 截断 30 字符 → update DB" 的完整逻辑。当前 `_sendMessage` 在 244 行又重新算了一次 `text.length > 30 ? ...`，结果完全一致。
**替代方案**: 保留重复计算作为 defensive check → 增加代码噪音，无实际价值。

### D4: 补齐其余 async gap 的 mounted 守卫

**选择**: 在 `_loadMessages`（happy path）、`_newChat`、`_deleteSession` 三个方法的 `await` → `setState` 之间增加 `if (!mounted) return;`。
**原因**: 当前只有 `_endStreaming()`、`_storeError`、`_sendMessage` 有此守卫。`_loadSessions`（task 1.1）补齐后，仍有 3 个 async gap 遗漏。虽然这三个方法是用户交互触发（widget 生命周期较稳定），但仍应与项目中其他 async gap 保持一致。
**Known-acknowledged exclusions**: 不再有——所有 `_ChatScreenState` 中的 async→setState 路径均已补齐。

## Risks / Trade-offs

- **[R] `_loadSessions` 加 mounted 后 session 列表可能不更新** → Mitigation：仅在 widget disposed 时才会 return，正常操作不受影响。与 `_storeError` 的模式一致。
- **[R] 移除截断后若 `updateTitleIfDefault` 行为变更可能导致不一致** → Mitigation：截断逻辑在 repo 层有明确的 spec（30 字符 + "..."），变更是统一的。
