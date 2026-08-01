## Why

The Anthropic API's extended thinking feature gives Claude the ability to reason through complex problems before responding — dramatically improving accuracy on coding, math, and multi-step analysis tasks. The SSE parsing pipeline and FFI bridge for thinking blocks have already been built (receiving complete thinking blocks at `content_block_stop`); only the request-side "switch" and UI rendering are missing. Enabling it is a low-cost, high-impact change.

## What Changes

- **BREAKING**: `send_message` FFI function signature gains a `thinking_mode` parameter (string: `"disabled"` or `"adaptive"`) and optional `thinking_effort` (string)
- API request body includes `"thinking":{"type":"adaptive","display":"summarized"}` with `"output_config":{"effort":"<level>"}` when thinking is active
- Adaptive thinking: `max_tokens` set to a generous value (16000) to accommodate both thinking and output tokens
- Agent Type config gains optional `thinking_effort` field — one of `"low"`, `"medium"`, `"high"`, `"xhigh"`, `"max"`; absent or any unrecognized value = disabled
- New `ChatThinkingItem` widget renders thinking content as a collapsible card in the chat flow
- Thinking blocks arrive as complete units from C++ (on `content_block_stop`), rendered immediately as collapsed cards with a character count header
- Thinking content is stored in the database and restored when reloading conversation history
- `_buildApiMessages` and `_buildChatItems` reconstruct thinking blocks from persisted data for API context continuity and UI display
- `display: "summarized"` ensures thinking content is visible on Opus 4.7+ models (default is `"omitted"` which returns empty thinking text)

## Capabilities

### New Capabilities
- `extended-thinking`: Enable Claude's extended thinking via the adaptive thinking API, render thinking content as collapsible cards in the UI, and persist thinking blocks alongside messages for history browsing

### Modified Capabilities
- `model-gateway`: Request body construction accepts thinking mode/effort and includes `display:"summarized"` for visible thinking content
- `ffi-bridge`: `send_message` signature updated to accept `thinking_mode` and `thinking_effort`
- `chat-ui`: Message list supports `ChatThinkingItem` — a new collapsible card type interleaved with messages and tool cards
- `session-persistence`: Messages table gains a `thinking_json` column; load/save round-trips thinking blocks; onUpgrade fixed to handle v2→v3 without data loss
- `agent-config`: Agent Type configuration gains optional `thinking_effort` field

## Impact

- **C++ sidecar**: `model_gateway.h/.cpp`, `sidecar_api.h/.cpp` — request body + FFI signature
- **Dart FFI bridge**: `sidecar_bridge.dart` — new parameters in `sendMessage`, isolate forwarding
- **Dart UI**: `chat_item.dart` (new subclass), new `thinking_card.dart` widget, `chat_area.dart` (new switch case), `main.dart` (streaming + persistence integration, `_buildChatItems` thinking reconstruction)
- **Dart models**: `app_config.dart` (AgentTypeConfig), `message.dart` (+thinking_json)
- **Dart services**: `database_service.dart` (schema migration v2→v3 fix + query/insert update)
- **Tests**: C++ (request body + signature validation, 15 existing call sites updated), Dart (thinking card rendering, persistence round-trip, FFI signature, schema migration)
- **Live test**: New integration test verifying thinking card appears in real AI conversation flow
