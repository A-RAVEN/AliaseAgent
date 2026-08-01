## ADDED Requirements

### Requirement: Thinking card incremental updates
The UI SHALL update the ThinkingCard content incrementally as thinking deltas arrive, using the block index to locate the correct card.

#### Scenario: First delta creates card
- **WHEN** the first `thinking_delta` event with a new index arrives
- **THEN** a ChatThinkingItem with that index is created and a ThinkingCard renders with the partial text, header showing the streaming indicator

#### Scenario: Subsequent deltas append content
- **WHEN** a `thinking_delta` event arrives for an existing index
- **THEN** the ChatThinkingItem at that index is replaced with a new instance whose content is the previous content plus the delta

#### Scenario: Final block replaces content
- **WHEN** the final `type:"thinking"` event arrives for an index
- **THEN** the card content is set to the complete thinking text and the signature is stored
