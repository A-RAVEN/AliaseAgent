## ADDED Requirements

### Requirement: Dependency verification
The system SHALL verify that all required tools (`flutter`, `dart`, `powershell`, `sqlite3`) are available on PATH before executing any verification steps.

#### Scenario: All dependencies present
- **WHEN** `check_deps()` is called
- **AND** all required tools are found on PATH
- **THEN** the function exits with code 0

#### Scenario: Missing dependency
- **WHEN** any required tool is not found on PATH
- **THEN** the function prints the missing tool name to stderr
- **AND** exits with code 1
- **AND** the smoke test run aborts before any verification steps

### Requirement: Unified smoke test entry point
The system SHALL provide a single script `test/smoke/run_all.sh` that executes all verification steps in sequence and reports pass/fail for each step.

#### Scenario: All steps pass
- **WHEN** `bash test/smoke/run_all.sh` is executed
- **AND** all verification steps succeed
- **THEN** the script exits with code 0
- **AND** outputs "ALL_PASS" as final status

#### Scenario: One step fails
- **WHEN** any verification step returns non-zero exit code
- **THEN** the script continues to remaining steps
- **AND** exits with code 1 at the end
- **AND** reports which step(s) failed

### Requirement: Build verification step
The system SHALL verify the application compiles successfully by running `flutter build windows --debug`.

#### Scenario: Build succeeds
- **WHEN** source code has no compile errors
- **THEN** the step exits with code 0

#### Scenario: Build fails
- **WHEN** source code has compile errors
- **THEN** the step exits with code 1
- **AND** build error output is preserved in the run log

### Requirement: Static analysis step
The system SHALL verify the application has no static analysis warnings by running `dart analyze lib/`.

#### Scenario: Analysis clean
- **WHEN** dart analyze reports no issues
- **THEN** the step exits with code 0

### Requirement: Existing checkpoint integration
The system SHALL execute all existing `test/checkpoint_X_verify.dart` scripts and report their aggregate status.

#### Scenario: All checkpoints pass
- **WHEN** every checkpoint script exits with code 0
- **THEN** the step exits with code 0

#### Scenario: Checkpoint fails
- **WHEN** any checkpoint script exits with non-zero code
- **THEN** the step continues to remaining checkpoints
- **AND** exits with code 1 after all complete
- **AND** the failing checkpoint name is recorded in the run log

### Requirement: Application launch verification
The system SHALL launch the built executable, wait for the window to appear, and confirm the process is alive.

#### Scenario: App launches successfully
- **WHEN** `alias_agent.exe` is started
- **THEN** the process is detected in `tasklist` within 10 seconds
- **AND** the main window title is confirmed via PowerShell

#### Scenario: Launch times out
- **WHEN** `alias_agent.exe` is started but the window does not appear within the timeout
- **THEN** the step exits with code 1
- **AND** the timeout duration and process status are recorded in the run log

### Requirement: Sidecar log verification
The system SHALL check the sidecar log file for ERROR and unrecognized event entries.

#### Scenario: No errors in log
- **WHEN** sidecar.log has been written during the session
- **THEN** `grep -c "ERROR\|unrecognized"` returns 0
- **AND** the step exits with code 0

#### Scenario: Errors found in log
- **WHEN** sidecar.log contains ERROR lines or unrecognized event warnings
- **THEN** the matching lines are printed to the run log
- **AND** the step exits with code 1

### Requirement: Database state verification
The system SHALL verify the SQLite database has expected tables and at least one session exists.

#### Scenario: Database is valid
- **WHEN** the app has been launched before
- **THEN** `sessions` and `messages` tables exist
- **AND** at least one session row exists

#### Scenario: Database tables missing
- **WHEN** the expected tables do not exist in the database
- **THEN** the step exits with code 1
- **AND** the missing table names are recorded in the run log
