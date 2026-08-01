## ADDED Requirements

### Requirement: Thinking card display
The system SHALL display thinking content blocks as collapsible `ThinkingCard` widgets in the message list, interleaved chronologically with tool call cards and assistant messages. Each thinking card SHALL include a header row with a thinking icon (e.g., 💭), "Thinking" label, expand/collapse chevron, and a content summary ("· N chars" when collapsed). Thinking blocks arrive as complete units from C++ at `content_block_stop`.

#### Scenario: Thinking card appears inline
- **WHEN** an `on_thinking` callback fires with a complete thinking block and a `ChatThinkingItem` is added to `_chatItems`
- **THEN** a `ThinkingCard` widget appears at its chronological position in the chat list, styled distinctly from both `ToolCallCard` and `MessageBubble`, default collapsed

#### Scenario: Thinking card header during turn
- **WHEN** a thinking block has been received but the overall turn is still in progress
- **THEN** the thinking card header shows an animated "Thinking..." indicator with dots

#### Scenario: Thinking card header after turn completion
- **WHEN** the turn completes (on_done callback fires)
- **THEN** all thinking card headers switch from animated dots to "· N chars" character count; expand/collapse state is unchanged

#### Scenario: Click to toggle expansion
- **WHEN** user clicks a thinking card header
- **THEN** the card toggles between expanded (showing full thinking text) and collapsed (header only)

#### Scenario: Multiple thinking cards interleaved
- **WHEN** a turn produces thinking → tool_use → thinking → text
- **THEN** the chat list renders in order: ThinkingCard → ToolCallCard → ThinkingCard → MessageBubble

### Requirement: Thinking card visual distinction
The `ThinkingCard` widget SHALL use a visual style that is clearly distinct from both tool call cards and assistant message bubbles, using a muted color palette and smaller font. The thinking body SHALL be scrollable with a max-height constraint to handle long thinking content without layout overflow.

#### Scenario: Visual style
- **WHEN** a `ThinkingCard` is rendered
- **THEN** it uses a muted background color (distinct from tool card blue and message bubble), smaller or italic body text, and a thinking-specific icon

#### Scenario: Long thinking content
- **WHEN** thinking content exceeds the body max-height (e.g., 400px)
- **THEN** the body uses a scrollable container to prevent layout overflow, matching existing `ToolCallCard` scroll pattern
