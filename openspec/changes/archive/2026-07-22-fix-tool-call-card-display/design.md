## Context

当前 `ToolCallActivity` 模型只有一个扁平的 `result` 字符串和一个截断的 `resultPreview` 字符串。`ToolCallCard` 用折叠/展开控制显示哪个字符串——但 `_formatSearchResultForDisplay` 只格式化第一条结果（为 AI context 设计），导致展开也无法看到全部数据。需要三层拆解：模型层结构化、格式化层双路径、UI 层重写。

另外，`ChatStreamingItem('')` 在每轮 turn 开始时被急切创建（`main.dart:494-495`），当模型直接调用 tool 而没有文本输出时，空泡在 tool card 下方持续显示直到 `sendMessage` 返回才被移除。需要改为延迟创建。

## Goals / Non-Goals

**Goals:**
- 折叠状态显示简洁摘要（如 "5 results from search-prime"），不泄露搜索结果内容
- 展开状态逐条渲染每一项搜索结果（title + URL + content preview）
- URL 在展开状态下可点击，方便用户手动打开
- web_search 和 web_fetch 结果都使用结构化渲染
- 其他工具（read_file、list_dir、get_current_time）保持现有行为不变
- Session 持久化不受影响——ToolCallActivity 保存结构化数据，重新加载后仍可渲染
- 消除 tool call 前的空 streaming 气泡：只有当模型真正输出文本时才显示 streaming item

**Non-Goals:**
- 不修改工具执行管道（_executeTool 不变）
- 不修改 sidecar C++ 返回的数据格式
- 不添加 HTML 富文本渲染（搜索结果用纯文本显示）
- 不修改对话流中的 AI context（_formatSearchResultForDisplay 的 AI 路径保持当前逻辑）
- 不修改 MessageBubble 渲染逻辑（仅改变 ChatStreamingItem 的创建时机）

## Decisions

### D1: `resultSections` 数据模型

在 `ToolCallActivity` 新增 `resultSections` 字段:

```dart
class ToolCallActivity {
  // ... existing fields ...
  final List<ResultSection>? resultSections;  // null for non-structured tools
}

class ResultSection {
  final String label;        // provider name / section title
  final String? error;       // if this provider returned error
  final List<ResultItem> items;

  const ResultSection({required this.label, this.error, this.items = const []});
}

class ResultItem {
  final String? title;
  final String? url;
  final String? content;

  const ResultItem({this.title, this.url, this.content});
}
```

**Why**: 结构化数据让 UI 层按项渲染，不再依赖字符串截断。`resultSections` 为 null 表示该工具无结构化结果，UI 回退到现有字符串模式。`resultSections` 为 `[]` 表示搜索完成但无结果（空列表），UI 应显示 "No results found" 而非回退到字符串模式。

**Alternatives considered**:
- 将 result 改为 JSON 字符串让 UI 解析 → 耦合太强，JSON 解析可能失败
- 用 `dynamic` 字段 → 失去类型安全
- 在 UI 层直接调用 repo 获取原始结果 → 过度设计，UI 不应直接访问业务数据

### D2: 格式化逻辑拆分

`_formatSearchResultForDisplay` 保持当前行为（AI context），新增 `_buildResultSections`:

```
_executeTool → resultJson (原始 JSON)
  ├── _formatSearchResultForDisplay() → content 字符串 → AI context (不变)
  └── _buildResultSections() → List<ResultSection> → ToolCallCard UI
```

`_buildResultSections`:
- 输入: 原始 tool result JSON（含 `results` map）
- 输出: `List<ResultSection>`，每个 section 对应一个 provider；无结果时返回 `[]`；非搜索工具不调用此方法（`resultSections` 保持 null）
- 不做长度截断（截断交给 UI 的 content preview）
- 边缘情况处理:
  - `ok: false` 或缺少 `results` key → 返回 `[]`（空列表）
  - `results` 为空 map `{}` → 返回 `[]`
  - provider 返回 error（`nsData['error']`）→ 创建 `ResultSection` 并设置 `error` 字段，`items` 为空
  - provider 正常 → 遍历所有 items，不做"只取第一条"的截断
- web_fetch: 输出单个 section，label="Fetched page"，单 item（title=URL, content=页面内容）；如果 `ok: false` 返回 `[]`

### D3: ToolCallCard UI 重写

```
折叠态:
┌──────────────────────────────────────────┐
│ 🔧 web_search(深度学习)    ✓ Done        │
│ ▼ 3 providers, 15 results                │ ← 一行摘要
└──────────────────────────────────────────┘

展开态:
┌──────────────────────────────────────────┐
│ 🔧 web_search(深度学习)    ✓ Done        │
├──────────────────────────────────────────┤
│ ▲ Collapse                               │
│ ┌─ search-prime ─ 5 results ───────────┐ │
│ │ #1 深度学习综述                         │ │
│ │ https://arxiv.org/abs/...  ↖ 可点击    │ │
│ │ 深度学习是机器学习的一个分支...          │ │
│ ├───────────────────────────────────────┤ │
│ │ #2 Transformer 架构详解                │ │
│ │ https://example.com/...                │ │
│ │ Transformer 是一种基于注意力...        │ │
│ └───────────────────────────────────────┘ │
│ ┌─ bing ─ 5 results ───────────────────┐ │
│ │ #1 ...                                │ │
│ └───────────────────────────────────────┘ │
│ ┌─ baidu ─ 5 results ──────────────────┐ │
│ │ #1 ...                                │ │
│ └───────────────────────────────────────┘ │
└──────────────────────────────────────────┘
```

每个 provider 为一个 section，section 内每条结果独立卡片：
- title 加粗，url 可点击（启动外部浏览器）
- content 限制显示行数（如 3 行）或长度

### D4: URL 可点击

需要添加 `url_launcher` 依赖（当前 `pubspec.yaml` 中不存在）。使用 `url_launcher` 的 `launchUrl` 打开链接。搜索结果中的 URL 在展开状态下渲染为可点击文本或带 link 图标的按钮。

### D5: ChatStreamingItem 延迟创建

当前逻辑在 `sendMessage` 调用前无条件添加 `ChatStreamingItem('')`。改为：

```dart
// 删除 turn 开始时的:
// setState(() => _chatItems.add(const ChatStreamingItem('')));

// onChunk 回调中改为:
onChunk: (text) {
  turnText += text;
  if (_currentId == sessionId && mounted) {
    setState(() {
      final lastIdx = _chatItems.length - 1;
      if (lastIdx >= 0 && _chatItems[lastIdx] is ChatStreamingItem) {
        _chatItems[lastIdx] = ChatStreamingItem(turnText);
      } else {
        // 首个文本 chunk: 延迟创建 streaming item
        _chatItems.add(ChatStreamingItem(turnText));
      }
    });
  }
},
```

**Why**: 避免 tool_use-only 响应中出现空泡。只有当模型真正输出文本时才需要 streaming item。

**注意**: `sendMessage` 返回后的清理逻辑 (`removeWhere((i) => i is ChatStreamingItem)`) 保持不变，安全执行——如果没有 streaming item 则 no-op。

### D6: Session 持久化修复

当前 `turnToolCalls` 存储的是原始 API tool_use JSON（`{type, id, name, input}`），不含 result 数据。`ToolCallActivity` 的 `result`、`status`、`resultPreview` 以及新增的 `resultSections` 在 session 重载后全部丢失。需修复：tool 执行完成后将 `ToolCallActivity.toJson()` 回写到 `turnToolCalls` 对应的 entry，使 `toolCallsJson` 持久化完整数据。

### D7: _buildChatItems 跳过空 content 的 assistant message

纯 tool_use 轮次中 `turnText` 始终为空字符串，导致持久化的 intermediate message 具有 `content: ''` + `toolCallsJson: [...]`。Session 重载时 `_buildChatItems` 无条件添加 `ChatMessageItem(msg)`，渲染出一个只有 padding 的空白 "Assistant" 气泡（D5 只修复了 live streaming 的 `ChatStreamingItem`，没覆盖 reload 路径）。

修复：`_buildChatItems` 中当 `msg.content` 为空且 `msg.toolCallsJson` 非空时，跳过 `ChatMessageItem`——工具卡片已充分代表此次回复。消息本身仍需保留在数据库中（用于 API context 重建），仅 UI 层不渲染。

### D8: Live 路径 intermediateMsg 跳过空 ChatMessageItem

D7 修复了 reload 路径，但 live 路径中 `intermediateMsg` 也被无条件加入 `_chatItems`（line 611）——当 `turnText` 为空时，产生同样空气泡。修复：加 `turnText.isNotEmpty` 判断，仅在 assistant 有实际文本输出时才在 UI 中添加 `ChatMessageItem`。数据库写入不受影响。

### D9: fromJson 向后兼容 `name` → `toolName`

旧 session 数据中 `toolCallsJson` 使用 API 原生 key `name`，但 `ToolCallActivity.fromJson` 只读 `toolName`。重载旧 session 时 tool card 显示 `unknown (Executing...)` 永久转圈。修复：`fromJson` 增加 `json['name']` fallback：`json['toolName'] ?? json['name'] ?? 'unknown'`。

## Risks / Trade-offs

- [Memory] 结构化数据比字符串内存占用大 → 单次搜索最多 50 条结果，每条仅存 title/url/content snippet，内存增量可忽略
- [Persistence] `ToolCallActivity` 序列化/反序列化需更新 → `toJson`/`fromJson` 正确处理 `resultSections: null`（向后兼容）；同时需将执行后的完整 activity 数据回写到 `turnToolCalls`（D6）
- [Scroll perf] 展开 50 条结果一次性渲染 → 使用 `ListView.builder`（而非 Column）或限制单次展开条数（但 50 条的简单文本卡片不构成性能问题）

## Open Questions

- 每个结果的内容 snippet 显示多长？决定用 200 字符
- Provider 错误渲染：section header 显示 provider 名 + 红色 error 标记（利用 `ResultSection.error` 字段）
