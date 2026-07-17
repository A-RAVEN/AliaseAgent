## ADDED Requirements

### Requirement: Fake sidecar event queuing
The system SHALL provide a `FakeSidecar` that allows pre-queuing events to be replayed when `sendMessage()` is called.

#### Scenario: Queue chunk event
- **WHEN** `fake.queueChunk("Hello")` is called before `sendMessage()`
- **THEN** the `onChunk` callback is invoked with "Hello" during `sendMessage()` execution

#### Scenario: Queue tool call event
- **WHEN** `fake.queueToolCall('{"name":"read_file","input":{"path":"/f"}}')` is called before `sendMessage()`
- **THEN** the `onToolCall` callback is invoked with the tool call JSON during `sendMessage()` execution

#### Scenario: Queue done event
- **WHEN** `fake.queueDone(code: 0, stopReason: "end_turn")` is called before `sendMessage()`
- **THEN** the `onDone` callback is invoked with `(0, null, "end_turn")` after all previous events

#### Scenario: Queue error done event
- **WHEN** `fake.queueDone(code: 1, error: "API Error")` is called before `sendMessage()`
- **THEN** the `onDone` callback is invoked with `(1, "API Error", null)`

### Requirement: Fake sidecar tool execution stubs
The system SHALL provide `stubReadFile(String json)` and `stubListDir(String json)` to return controlled JSON results when the tool execution loop calls `readFile()` / `listDir()`.

#### Scenario: readFile returns controlled result
- **WHEN** `fake.stubReadFile('{"ok":true,"content":"hello"}')` is set before `sendMessage()`
- **THEN** any call to `fake.readFile(anyPath)` returns `'{"ok":true,"content":"hello"}'`

#### Scenario: listDir returns controlled result
- **WHEN** `fake.stubListDir('{"ok":true,"entries":[{"name":"f.txt"}]}')` is set before `sendMessage()`
- **THEN** any call to `fake.listDir(anyPath)` returns the stubbed JSON

### Requirement: Fake sidecar multi-event sequence
The system SHALL replay all queued events in order when `sendMessage()` is called.

#### Scenario: Message followed by tool call followed by done
- **WHEN** events are queued in order: chunk("Thinking..."), toolCall("read_file"), chunk("Result is..."), done(0, "end_turn")
- **THEN** callbacks are invoked in the exact same order during `sendMessage()`

### Requirement: Fake sidecar setWorkspace
The system SHALL provide a no-op `setWorkspace()` in `FakeSidecar`.

#### Scenario: setWorkspace called
- **WHEN** `fake.setWorkspace("/test/path")` is called
- **THEN** the call completes without error and without side effects
