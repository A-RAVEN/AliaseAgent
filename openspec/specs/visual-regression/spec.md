## ADDED Requirements

### Requirement: Automated screenshot capture in test scenarios
The system SHALL capture screenshots at defined points during integration test scenarios using Flutter's `RenderRepaintBoundary.toImage()` API.

#### Scenario: Screenshot after empty state render
- **WHEN** integration test renders ChatScreen in empty state
- **AND** `RepaintBoundary.toImage()` captures the widget tree as a PNG
- **THEN** a PNG screenshot is saved to `test/smoke/output/empty_state.png`
- **AND** the file size is non-zero

#### Scenario: Screenshot after auto-title update
- **WHEN** integration test triggers auto-title update
- **THEN** a PNG screenshot is saved to `test/smoke/output/auto_title.png`

#### Scenario: Screenshot after tool call renders
- **WHEN** integration test triggers a tool call event
- **THEN** a PNG screenshot is saved to `test/smoke/output/tool_card.png`

#### Scenario: Screenshot after error renders
- **WHEN** integration test triggers an error event
- **THEN** a PNG screenshot is saved to `test/smoke/output/error.png`

### Requirement: Baseline generation on first run
The system SHALL treat the absence of reference screenshots as a baseline generation pass, not a failure.

#### Scenario: No reference screenshots exist
- **WHEN** `test/smoke/references/` is empty
- **AND** screenshots are captured to `test/smoke/output/`
- **THEN** the screenshots are copied to `test/smoke/references/` as baseline
- **AND** the step reports "BASELINE_CREATED" instead of pass/fail

### Requirement: Visual regression on subsequent runs
The system SHALL compare newly captured screenshots against reference baselines using file hash comparison and report differences.

#### Scenario: Screenshot matches baseline
- **WHEN** a captured screenshot has the same SHA256 hash as its reference
- **THEN** the visual check passes

#### Scenario: Screenshot differs from baseline
- **WHEN** a captured screenshot has a different SHA256 hash from its reference
- **THEN** the difference is reported with the affected screenshot name
- **AND** the step fails

### Requirement: Integration with unified smoke test runner
The system SHALL integrate visual regression as step 5 in the smoke test pipeline.

#### Scenario: run_all.sh includes visual regression
- **WHEN** `bash test/smoke/run_all.sh` is executed
- **THEN** after step 4 (launch & verify), step 5 runs integration tests with visual capture
- **AND** the final report includes visual regression pass/fail status
