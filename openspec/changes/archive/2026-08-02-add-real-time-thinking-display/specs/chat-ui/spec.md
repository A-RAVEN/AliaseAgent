## ADDED Requirements

### Requirement: Thinking card incremental updates
The UI SHALL update the ThinkingCard content incrementally as thinking deltas arrive, using the block index to locate the correct card. Index lookup SHALL be scoped to the current turn (the SSE index restarts at 0 for each new message): deltas for index N in the current turn SHALL NOT match cards created in earlier turns or cards rebuilt from history.

#### Scenario: First delta creates card
- **WHEN** the first `thinking_delta` event with a new index arrives in the current turn
- **THEN** a ChatThinkingItem with that index is created and a ThinkingCard renders with the partial text, header showing the streaming indicator

#### Scenario: Subsequent deltas append content
- **WHEN** a `thinking_delta` event arrives for an existing index in the current turn
- **THEN** the ChatThinkingItem at that index is replaced with a new instance whose content is the previous content plus the delta

#### Scenario: Final block replaces content
- **WHEN** the final `type:"thinking"` event arrives for an index
- **THEN** the card content is set to the complete thinking text and the signature is stored

#### Scenario: No cross-turn index collision
- **WHEN** a new turn (e.g., a tool-loop follow-up message) streams a thinking delta with index 0
- **THEN** the delta updates the current turn's card only; cards from the previous turn are not modified

### Requirement: Session-switch cancellation does not persist error cards
When an in-flight request is cancelled by a session switch (selecting another session, creating a new chat, or deleting the current session), the system SHALL NOT persist a misleading error card into the abandoned session's history. The cancellation context SHALL be captured at switch time via a request generation counter (epoch): a session switch records the generation of the in-flight call, and any done (success or error) of a call whose generation was invalidated by a switch SHALL be treated as a switch-cancellation — its reply SHALL NOT be persisted, rendered, or allowed to tear down a newer request's streaming state (rapid A→B→A switches included).

#### Scenario: Switch mid-stream
- **WHEN** a request is streaming in session A and the user switches to session B (cancelRequest issued, cancel context recorded for A)
- **THEN** the cancelled done is processed without storing any error card into session A's history

#### Scenario: Rapid switch back before cancel completes
- **WHEN** the user switches A→B→A before the cancellation done arrives
- **THEN** the done is still recognized as a switch-cancellation (context captured at switch time) and no error card is stored

#### Scenario: Cancelled request completes successfully
- **WHEN** a switch-cancelled request finishes with doneCode 0 (lost-cancel window)
- **THEN** the cancel context is cleared (a later real error in that session is still surfaced) and the stale request's completion does not tear down a newer request's streaming state

### Requirement: Collapse state stays user-controlled during streaming
The ThinkingCard SHALL NOT auto-expand or auto-collapse: during streaming, a collapsed card stays collapsed (content accumulates internally), and the program does not change the user's expand/collapse choice at any point (delta arrival, turn completion, or otherwise). This requirement SHALL be enforceable as an explicit spec clause, not merely inherited from prior behavior.

#### Scenario: User collapses a streaming card
- **WHEN** the user collapses a card while its thinking is still streaming
- **THEN** it stays collapsed until the user expands it; content continues to accumulate

#### Scenario: Turn completion does not change state
- **WHEN** a turn completes (streaming indicator switches to character count)
- **THEN** each card keeps the exact collapsed/expanded state it had before
