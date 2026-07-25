## Why

`_sendMessage` 的 tool call 循环硬编码了 `for (int turn = 0; turn < 5; turn++)`，在 5 轮后强行终止，即使模型还有工具要调。这假设了模型的行为模式（"不会超过 5 轮工具调用"），但实际对话中 DeepSeek 常做多轮递进搜索，5 轮用完被掐断，用户收不到最终回复。循环退出应该由模型的 `stop_reason` 决定，不应该由客户端预设上限。

## What Changes

- **移除 5 轮硬上限**: `for` 循环改为 `while (true)`，退出仅由模型自身决策（`turnToolCalls.isEmpty` → 模型不再调工具）
- **安全网保留**: 追加 50 轮计数器防御代码 bug 导致的死循环，触发时 log warning
- 循环体其余逻辑（工具执行、消息持久化、UI 更新）不变

## Capabilities

无 spec 变更。5 轮硬上限从未写入任何 spec——移除一个 spec 不包含的限制，不需要修改 spec。

## Impact

- **1 文件**: `lib/main.dart` — `_sendMessage` 中的 `for` 循环头 + 尾部 guard
- 不涉及 sidecar、持久化、UI widget、测试基础架构
