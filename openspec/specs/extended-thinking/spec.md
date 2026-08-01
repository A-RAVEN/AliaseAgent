# Extended Thinking — Spec

## ADDED Requirements

### Requirement: Extended thinking enablement via adaptive API
When an agent type config specifies a valid `thinking_effort` (`"low"`, `"medium"`, `"high"`, `"xhigh"`, or `"max"`), the C++ Sidecar SHALL include `"thinking":{"type":"adaptive","display":"summarized"}` and `"output_config":{"effort":"<level>"}` in the API request body. The system SHALL set `max_tokens` to 16000 to accommodate both thinking and output tokens. When `thinking_effort` is absent or unrecognized, no thinking parameter SHALL be sent and `max_tokens` SHALL remain at 4096.

#### Scenario: Thinking enabled with effort level
- **WHEN** `send_message` is called with `thinking_mode = "adaptive"` and `thinking_effort = "high"`
- **THEN** the request body includes `"thinking":{"type":"adaptive","display":"summarized"}`, `"output_config":{"effort":"high"}`, and `"max_tokens":16000`

#### Scenario: Thinking disabled (absent config)
- **WHEN** an agent type config does not specify `thinking_effort`
- **THEN** the request body does NOT include a `thinking` field, and `max_tokens` is set to 4096

#### Scenario: Thinking disabled (unrecognized effort)
- **WHEN** an agent type config has an unrecognized `thinking_effort` value
- **THEN** the system treats it as disabled (same as absent)

### Requirement: Thinking display configuration
The system SHALL set `display: "summarized"` in the thinking configuration to ensure thinking content is visible on all supported models. Without this, Opus 4.7+ models default to `display: "omitted"` which returns empty thinking text.

#### Scenario: Display summarized ensures visible thinking
- **WHEN** the API request includes thinking configuration
- **THEN** `"display":"summarized"` is always set alongside `"type":"adaptive"`

### Requirement: Thinking block UI rendering
The system SHALL display thinking content blocks as collapsible `ThinkingCard` widgets within the chat message list, interleaved chronologically with tool call cards and assistant messages. Thinking blocks arrive as complete units from C++ (dispatched at `content_block_stop`). Each thinking card SHALL show a header with an icon, "Thinking" label, and content length summary.

#### Scenario: Thinking card appears on block completion
- **WHEN** the `on_thinking` callback fires with a complete thinking block
- **THEN** a `ChatThinkingItem` is created and a `ThinkingCard` widget appears in the chat area, default collapsed with a character count summary in the header

#### Scenario: Multiple thinking blocks per turn
- **WHEN** the model produces thinking blocks interleaved with tool calls (e.g., thinking → tool_use → thinking → text)
- **THEN** each thinking block appears as a separate `ThinkingCard` at its chronological position in the chat list

### Requirement: Thinking card expand/collapse interaction
Each thinking card SHALL default to collapsed (header only), and SHALL toggle between collapsed and expanded when the user clicks the card header. The program SHALL NOT auto-expand during streaming or auto-collapse after completion. Manual expansion state SHALL persist for the current session lifetime.

#### Scenario: Click to expand
- **WHEN** user clicks the header of a collapsed thinking card
- **THEN** the card expands to show the full thinking content

#### Scenario: Click to collapse
- **WHEN** user clicks the header of an expanded thinking card
- **THEN** the card collapses to show only the header

#### Scenario: Thinking card header updates on completion
- **WHEN** all thinking content has been received and the turn completes
- **THEN** the header switches from animated dots to "· N chars" character count; the expand/collapse state is unchanged

### Requirement: Thinking parse failure handling
When the `on_thinking` callback receives malformed JSON, the system SHALL log the error and skip the failed block. The stream SHALL continue processing subsequent blocks. A skipped thinking block SHALL NOT produce a `ChatThinkingItem` in the UI.

#### Scenario: Malformed thinking JSON
- **WHEN** `on_thinking` receives data that fails `jsonDecode`
- **THEN** the error is logged via `debugPrint`, no `ChatThinkingItem` is created, and the stream continues to completion

### Requirement: Thinking persistence in database
The system SHALL store thinking blocks as a JSON array in a `thinking_json` column on the messages table. The schema SHALL be versioned at v3.

#### Scenario: Thinking blocks saved with message
- **WHEN** an assistant turn includes one or more thinking blocks
- **THEN** the message row's `thinking_json` column contains a JSON array like `[{"type":"thinking","thinking":"...","signature":"..."}, ...]`

#### Scenario: Thinking blocks loaded from database
- **WHEN** a conversation with thinking blocks is reloaded from the database
- **THEN** the thinking blocks are reconstructed into `ChatThinkingItem` widgets in the correct chronological order, prepended before tool call cards and message text

#### Scenario: No thinking in message
- **WHEN** an assistant turn has no thinking blocks
- **THEN** the `thinking_json` column is NULL

### Requirement: Thinking blocks in API context reconstruction
When rebuilding API conversation messages from persisted data (`_buildApiMessages`), the system SHALL prepend stored thinking blocks to the assistant content array before the text block, preserving all fields including `signature` verbatim. Malformed `thinking_json` SHALL be caught and skipped.

#### Scenario: Thinking blocks reconstructed in API messages
- **WHEN** `_buildApiMessages` processes an assistant message with `thinking_json = [{"type":"thinking","thinking":"...","signature":"sig123"}]`
- **THEN** the content array starts with `[{"type":"thinking","thinking":"...","signature":"sig123"}, {"type":"text","text":"..."}]`

#### Scenario: No thinking blocks in reconstruction
- **WHEN** `_buildApiMessages` processes an assistant message with NULL `thinking_json`
- **THEN** the content array starts with `[{"type":"text","text":"..."}]` as before

#### Scenario: Malformed thinking_json in reconstruction
- **WHEN** `_buildApiMessages` encounters a message with invalid JSON in `thinking_json`
- **THEN** the error is logged and thinking blocks are skipped, but the text and tool_use content is still reconstructed normally
