## ADDED Requirements

### Requirement: ISidecar interface definition
The system SHALL define an `ISidecar` abstract interface exposing `sendMessage()`, `setWorkspace()`, `readFile()`, and `listDir()` methods with the same signatures as `SidecarBridge`'s public API.

#### Scenario: SidecarBridge implements ISidecar
- **WHEN** `SidecarBridge` is modified to `implements ISidecar`
- **THEN** all existing call sites compile without changes
- **AND** `SidecarBridge` behavior is unchanged

#### Scenario: FakeSidecar implements ISidecar
- **WHEN** `FakeSidecar` is declared as `implements ISidecar`
- **THEN** it satisfies all method signatures required by the interface
- **AND** Dart analyzer confirms no missing overrides

### Requirement: ChatScreen accepts injectable ISidecar
The system SHALL allow `ChatScreen` to accept an optional `ISidecar` parameter, defaulting to `SidecarBridge.instance` when not provided.

#### Scenario: Default behavior unchanged
- **WHEN** `ChatScreen` is constructed without the `sidecar` parameter
- **THEN** it uses `SidecarBridge.instance` as before
- **AND** all existing functionality works identically

#### Scenario: Fake sidecar injected
- **WHEN** `ChatScreen` is constructed with a `FakeSidecar` instance
- **THEN** message sending goes through the fake instead of the real sidecar
- **AND** the `setWorkspace()` call in `initState` is skipped
