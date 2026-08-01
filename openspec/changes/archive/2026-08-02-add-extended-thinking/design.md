## Context

The SSE parsing pipeline and FFI bridge for thinking blocks have already been implemented. The C++ parser accumulates `thinking_delta` and `signature_delta` per block index, then dispatches a complete `THINKING` event at `content_block_stop`. The two remaining gaps are:

1. **Request side**: The API request body never includes the `thinking` parameter, so the API never enters extended thinking mode.
2. **UI side**: Thinking blocks from `on_thinking` callbacks are collected into `turnThinkingBlocks` and passed back to the API, but never displayed to the user or persisted.

**Important constraint**: Thinking blocks arrive at Dart as complete JSON objects (not incremental deltas). The C++ parser does NOT forward individual `thinking_delta` events — it only emits on `content_block_stop`. The UI design must work with complete-block delivery.

## Goals / Non-Goals

**Goals:**
- Send thinking parameter using the current adaptive thinking API (`type: "adaptive"`, `display: "summarized"`, `output_config.effort`)
- Set `max_tokens` to a generous value (16000) when thinking is enabled to accommodate both thinking and output tokens
- Render thinking content as `ChatThinkingItem` cards when complete blocks arrive from C++
- Display thinking cards as collapsible widgets: default collapsed, expandable on click; expansion state entirely user-controlled
- Persist thinking blocks in the database so they survive session reload
- Reconstruct thinking blocks in `_buildApiMessages` for API context continuity AND in `_buildChatItems` for UI display on session reload
- Fix schema `onUpgrade` to handle v2→v3 without data loss (replace destructive else-branch with specific version checks)

**Non-Goals:**
- Per-message thinking effort adjustment — effort is configured at the agent type level
- Thinking block editing or annotation
- Thinking analytics (token usage breakdown, etc.)
- Multi-model thinking support (e.g., OpenAI reasoning) — Anthropic-only for now
- Real-time streaming of thinking deltas — thinking blocks arrive as complete units from C++
- `redacted_thinking` block handling (Anthropic safety feature — can be added in a follow-up change)

## Decisions

### D1: Thinking effort stored in AgentTypeConfig

**Choice**: Add optional `thinkingEffort` field (String?) to `AgentTypeConfig` → `config.json`. Valid values: `"low"`, `"medium"`, `"high"`, `"xhigh"`, `"max"`. Absent or any unrecognized value means thinking is disabled.

**Rationale**: The Anthropic API's adaptive thinking mode uses effort levels rather than fixed token budgets. This is more future-proof — the model decides its own thinking budget within the effort constraint. Agent types already bundle model + system_prompt + tools; adding thinking effort here is consistent.

**Alternatives considered**:
- Token budget (`budget_tokens`): Removed/deprecated on current-gen models (Fable 5, Opus 4.8/4.7). Returns HTTP 400.
- Hardcoded default: too inflexible — users may want different effort levels per agent type

### D2: New `thinking_json` column in messages table

**Choice**: Add `thinking_json TEXT` column via `ALTER TABLE ADD COLUMN` migration (schema v2→v3).

**Critical**: The existing `onUpgrade` handler uses `if (oldV == 1) ... else { DROP TABLE }`. When `_schemaVersion` is bumped from 2 to 3, `oldV=2` hits the else-branch and destroys all data. The migration MUST be changed to handle specific version pairs:

```dart
onUpgrade: (db, oldV, newV) async {
  if (oldV == 1) {
    await db.execute('ALTER TABLE messages ADD COLUMN tool_calls TEXT');
  }
  if (oldV == 2) {
    await db.execute('ALTER TABLE messages ADD COLUMN thinking_json TEXT');
  }
  // Drop only for truly unknown versions
  if (oldV < 1 || oldV > _schemaVersion) {
    await db.execute('DROP TABLE IF EXISTS messages');
    await db.execute('DROP TABLE IF EXISTS sessions');
  }
}
```

**Rationale**: Thinking blocks are structurally different from both message content and tool calls. A dedicated column:
- Keeps the migration simple (single `ALTER TABLE`)
- Stores a JSON array: `[{"type":"thinking","thinking":"...","signature":"..."}, ...]`
- Is backward-compatible (NULL for all existing rows)

**Both `onCreate` branches** (main `_init` + test `openAt`) must include the new column.

### D3: ChatThinkingItem — immutable sealed subclass, complete-block delivery

**Choice**: Add `ChatThinkingItem` to the sealed `ChatItem` family, inserted into `_chatItems` when the complete thinking block arrives from C++.

**Data flow** (corrected from initial design):
```
C++: thinking_delta ×N → accumulate silently → content_block_stop
  → single SseEventKind::THINKING dispatched
  → FFI: on_thinking(complete_json_string)
  → Dart: jsonDecode → ChatThinkingItem(thinking, signature)
  → setState → _chatItems.add(item)
  → Header shows "Thinking · N chars" (complete, collapsed)
```

**Important**: ChatThinkingItem is immutable (like all ChatItem subclasses). When implementing multi-block thinking support, each block index creates a NEW ChatThinkingItem — never mutates an existing one.

**Display order in chat list**:
```
[User Message]
[💭 Thinking · 156 chars]  ← ChatThinkingItem (collapsed)
[🔧 web_search]            ← ChatToolCallItem
[💭 Thinking · 89 chars]   ← ChatThinkingItem (collapsed)
[Assistant Reply]          ← ChatMessageItem
```

Thinking blocks are always prepended before text and tool_use in the content array, matching the Anthropic API's guaranteed ordering (thinking always precedes text/tool_use). This assumption is explicit — if Anthropic ever changes ordering, reconstruction must be updated.

### D4: Thinking card widget — user-controlled collapsible

**Choice**: New `ThinkingCard` widget with:
- Header: 💭 icon + "Thinking" label + chevron + (isStreaming ? animated dots : "· N chars")
- Body: light italic text on muted background, scrollable for long content (max-height ~400px matching ToolCallCard pattern)
- Always starts collapsed; expand/collapse is entirely user-controlled — the program never auto-expands or auto-collapses
- During streaming: header shows animated dots; on completion: header switches to char count
- User click toggles expanded state (persists for session lifetime)

**Visual hierarchy** (vs ToolCallCard and MessageBubble):
- More subtle than tool cards — lighter background, smaller font, italic
- Clearly distinct from final assistant text
- Color: muted purple/grey tone, not the primary blue of tool cards

### D5: Thinking blocks in API context reconstruction

**Choice**: `_buildApiMessages` reads `msg.thinkingJson`, parses it, and prepends blocks before text and tool_use in the content array. MUST include try-catch for malformed JSON (consistent with existing toolCallsJson pattern).

```dart
// Reconstructed content order:
// [thinking blocks...] → [text block] → [tool_use blocks...]
if (msg.thinkingJson != null && msg.thinkingJson!.isNotEmpty) {
  try {
    final thinkingBlocks = jsonDecode(msg.thinkingJson!) as List<dynamic>;
    content.insertAll(0, thinkingBlocks.cast<Map<String, dynamic>>());
  } catch (e) {
    debugPrint('[AliasAgent] Failed to parse thinkingJson: $e');
  }
}
```

This matches the live-streaming order used in `main.dart:672-678`. The `signature` field from each thinking block is preserved verbatim through the entire pipeline (C++ SSE → FFI → Dart → DB → API reconstruction).

Similarly, `_buildChatItems` MUST parse `msg.thinkingJson` and insert `ChatThinkingItem` widgets before tool call cards and message text (matching API content array order).

### D6: FFI signature — `thinking_mode` + `thinking_effort`

**Choice**: Add `const char* thinking_mode` and `const char* thinking_effort` parameters to `send_message` (C) and `sendMessage` (Dart). Follow existing grouping convention: all string params before callback params.

New signature:
```c
int send_message(
  const char* api_key, const char* base_url, const char* model,
  const char* system_prompt, const char* messages_json, const char* tools_json,
  const char* thinking_mode,      // NEW: "disabled" or "adaptive"
  const char* thinking_effort,    // NEW: "low"|"medium"|"high"|"xhigh"|"max" | ""
  OnChunkCallback, OnToolCallCallback, OnThinkingCallback, OnDoneCallback
);
```

Request body logic in `model_gateway.cpp`:
```cpp
if (thinking_mode && std::string(thinking_mode) == "adaptive") {
  body["thinking"]["type"] = "adaptive";
  body["thinking"]["display"] = "summarized";
  if (thinking_effort && std::strlen(thinking_effort) > 0) {
    body["output_config"]["effort"] = thinking_effort;
  }
  body["max_tokens"] = 16000;  // generous for thinking + output
} else {
  body["max_tokens"] = 4096;   // unchanged default
}
```

**Why `display: "summarized"` is critical**: On Opus 4.7+, the default is `"omitted"` which returns EMPTY thinking text (no `thinking_delta` events). Without setting `"summarized"` explicitly, the ThinkingCard widget would render blank/empty cards. Setting `"summarized"` is safe on all models (pre-4.7 it's already the default, so it's a no-op).

**Why 16000 tokens**: Adaptive thinking doesn't use a fixed budget — the model manages its own thinking allocation within `max_tokens`. 16000 is a reasonable ceiling that accommodates complex multi-turn conversations with tool calls. This replaces the old `budget_tokens + 4096` formula which would frequently truncate output.

### D7: Migration fix — specific version checks

**Choice**: Replace the destructive `if (oldV == 1) ... else { DROP TABLE }` pattern with specific version checks. Both `_init` and `openAt` branches must be updated.

**Rationale**: The current pattern is a silent data-loss trap: `_schemaVersion = 2` → bump to 3 → `onUpgrade(db, 2, 3)` → `oldV != 1` → else-branch drops all tables. Every schema version bump would trigger this bug.

## Risks / Trade-offs

- **[Breaking FFI change]**: Old Flutter app with new sidecar.dll (or vice versa) will crash due to signature mismatch. Dart FFI `lookupFunction` performs zero signature validation — mismatched function pointer casts fail silently (stack corruption, not a clean error). → Mitigated: both are built together from the same repo; no independent deployment. AliasAgent has no field-update mechanism for the DLL.
- **[Token cost]**: Adaptive thinking tokens are billed as output tokens. The model self-manages its thinking budget within `max_tokens`. → Mitigated: configurable effort level per agent type; users can disable or choose lower effort.
- **[Latency]**: Thinking phase adds latency before text generation begins. → Mitigated: thinking card header appears immediately with animated dots, giving user visible progress feedback.
- **[Schema migration]**: v2→v3 migration requires fixing the `onUpgrade` else-branch. Without the fix, all user data is destroyed. → Mitigated: fixed in D7 using specific version checks. Both `onCreate` branches updated for fresh installs.
- **[Model compatibility]**: Adaptive thinking requires Opus 4.6+ / Sonnet 4.6+. On older models, thinking is silently disabled (empty or unrecognized effort → no thinking parameter sent). No beta headers needed on 4.6+.
- **[Signature preservation]**: Thinking blocks have an optional `signature` field. The Anthropic API requires signatures to be passed back verbatim in subsequent requests. → Mitigated: D5's verbatim `jsonDecode` + `insertAll` preserves all fields including signature; task explicitly verifies this in tests.
- **[Thinking parse failure]**: If `onThinking` receives malformed JSON (unlikely with valid API but possible with network corruption), the current code silently catches and skips. → Mitigated: explicit spec requirement documenting this behavior; logged via `debugPrint` for diagnostics. Pattern is consistent with existing `onToolCall` parse handling.
- **[max_tokens ceiling]**: 16000 max_tokens with adaptive thinking may still truncate very long agentic responses with many tool calls. → Acceptable trade-off; can be made configurable in a follow-up if needed.
