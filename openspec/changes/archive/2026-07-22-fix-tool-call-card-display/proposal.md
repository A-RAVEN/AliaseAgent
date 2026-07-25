## Why

当前 `ToolCallCard` 的折叠/展开模式对 web_search/web_fetch 等富结果工具毫无意义——折叠模式显示前 300 字符格式化文本（过多），展开模式也只展示第一条搜索结果（过少）。用户既看不到简洁摘要，也看不到完整结果列表。需要在数据模型、格式化逻辑、UI 三层同时改造，让卡片折叠时真正简洁、展开时真正完整。

同时修复 tool call 前的空气泡问题：`ChatStreamingItem('')` 在每轮 turn 开始时被急切创建，当模型直接调用 tool（tool_use-only 响应）时，空泡在 tool card 下方持续闪烁直到 `sendMessage` 返回才被移除。应改为延迟创建——只在第一个文本 chunk 到达时才创建 streaming item。

## What Changes

- **ToolCallActivity 模型扩展**: 新增结构化 `resultSections` 字段，每条结果独立存储 title/url/content，UI 按条渲染而非拼凑字符串
- **ToolCallCard UI 重写**: 折叠模式显示一行摘要（"N results from M providers"），展开模式逐条渲染每项结果，URL 可点击、内容可独立控制
- **web_search 格式化逻辑分离**: 当前 `_formatSearchResultForDisplay` 是为 AI 摘要设计的（只取第一条），保留该逻辑用于 AI context；为 UI 展示新增专用格式化路径
- **web_fetch 同样受益**: fetch 结果也使用相同的结构化渲染
- **空气泡消除**: `ChatStreamingItem` 从急切创建改为延迟创建——只在首个 `onChunk` 文本到达时才加入消息列表，tool_use-only 响应不再出现空泡泡

## Capabilities

### New Capabilities
- `tool-call-result-display`: 结构化渲染 tool call 结果，支持折叠/展开/逐条展示/URL 可点击

### Modified Capabilities
- `chat-ui`: Tool call 卡片的行为和外观变更——折叠语义从"截断字符串"变为"摘要"，展开语义从"显示截断后的字符串"变为"渲染完整结构化结果"

## Impact

- **模型层**: `lib/models/tool_call_activity.dart` — 新增 `resultSections` 字段
- **格式化层**: `lib/main.dart` — `_formatSearchResultForDisplay` 拆分为 AI 路径和 UI 路径
- **UI 层**: `lib/ui/tool_call_card.dart` — 几乎重写，支持结构化渲染
- **消息流层**: `lib/main.dart` — `ChatStreamingItem` 创建时机从 turn 开始改为首个 onChunk
- **配置层**: `pubspec.yaml` — 新增 `url_launcher` 依赖
- **持久化层**: `lib/main.dart` — 修复 tool result 数据在 session 重载后丢失的问题（当前 `toolCallsJson` 只存原始 API tool_use，不含 result/status/resultSections）
- **不涉及**: sidecar C++ 层、FFI bridge
