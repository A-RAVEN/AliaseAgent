## ADDED Requirements

### Requirement: Content block array format for messages
The C++ Sidecar SHALL build message content as arrays of content blocks, never unwrapping single blocks.

#### Scenario: Text-only assistant message
- **WHEN** an assistant message contains only text
- **THEN** content is formatted as `[{"type":"text","text":"..."}]` not a bare string

#### Scenario: Assistant message with tool_use
- **WHEN** an assistant message contains a tool_use block
- **THEN** content includes `{"type":"tool_use","id":"...","name":"...","input":{...}}`

#### Scenario: Tool result message
- **WHEN** a tool result is sent back to the API
- **THEN** content is formatted as `[{"type":"tool_result","tool_use_id":"...","content":"..."}]`

### Requirement: Multi-turn tool use message assembly
The C++ Sidecar SHALL correctly assemble the conversation history for multi-turn tool use.

#### Scenario: User → Assistant (tool_use) → User (tool_result) → Assistant (final)
- **WHEN** building messages for the second API call after tool execution
- **THEN** the messages array contains: user message, assistant message with tool_use, user message with tool_result blocks
