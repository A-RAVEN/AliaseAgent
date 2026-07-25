## Context

`_sendMessage` 的 tool call 循环当前为 `for (int turn = 0; turn < 5; turn++)`。位于 `lib/main.dart:489`。循环尾（`:697`）后的 `// Max tool turns exceeded` 是唯一走到那的路径——表示 5 轮耗尽、模型未回复、直接 `_endStreaming()`。

## Goals / Non-Goals

**Goals:**
- 循环退出由模型决定——模型说 `stop_reason=end_turn` 或无 tool_use → 循环结束
- 保留安全网防止真正的死循环

**Non-Goals:**
- 不修改循环体内的任何逻辑
- 不修改工具执行、消息持久化、UI 更新的其他部分

## Decisions

### D1: `for` → `while (true)`

```dart
// 之前:
for (int turn = 0; turn < 5; turn++) { ... }
// Max tool turns exceeded
if (_currentId == sessionId) _endStreaming();

// 之后:
int turn = 0;
while (true) {
    ... // body 完全不变
    if (turn >= 50) {
        debugPrint('[AliasAgent] Max tool turns (50) exceeded — aborting');
        if (_currentId == sessionId) _endStreaming();
        await _sessionRepo.touch(sessionId);
        return;
    }
    turn++;
}
```

**Why**: `while (true)` 让 `turnToolCalls.isEmpty` 分支（模型说"我回完了"）成为唯一正常的循环出口。循环体完全不碰，风险最小。

**Alternatives considered**:
- 直接 `while (true)` 无安全网 → 如果 stop_reason 解析有 bug，可能真死循环
- 配置化轮数上限 → 换汤不换药，还是假设模型行为

### D2: 安全网 50 轮

50 远高于实际需求（日志中最深才 5），纯粹防御代码 bug。触发时 log warning + 正常清理（`_endStreaming` + `touch`），不算静默失败。

## Risks / Trade-offs

- [死循环] 如果某 API 的 stop_reason 解析有 bug 永远不返回 end_turn → 安全网 50 轮兜底
- [Token 消耗] 无限制循环可能消耗大量 token → 这是模型行为决定的，不是客户端该管的；API 有 `max_tokens` 参数限制单次响应长度

## Open Questions

无。
