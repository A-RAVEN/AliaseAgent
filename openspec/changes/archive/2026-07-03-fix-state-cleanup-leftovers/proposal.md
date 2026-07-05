## Why

fix-phase18-state-cleanup 三轮对抗审查中发现了 3 个 pre-existing 的 LOW 级别问题，均在 `_ChatScreenState`（`lib/main.dart`）中。这些问题不影响当前功能但违反了代码规范（缺 mounted 守卫、静默 catch、重复逻辑），应在 chat-agent-window 18.6 重构前修掉。

## What Changes

- `_loadSessions` 的 `await _sessionRepo.list()` 之后增加 `mounted` 检查
- `_executeTool` 的 `catch (_)` 改为 `catch (e)` + `debugPrint`
- `_sendMessage` auto-title 中移除 widget 层的重复截断逻辑（`updateTitleIfDefault` 已在 repo 层处理截断）

## Capabilities

### New Capabilities
（无 — 本次为纯代码清理，不引入新功能需求）

### Modified Capabilities
（无 — 不改变任何 spec 级别的行为需求）

## Impact

- `lib/main.dart` — `_ChatScreenState`：`_loadSessions`（1 行）、`_executeTool`（2 行）、`_sendMessage`（-3 行）
