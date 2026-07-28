## MODIFIED Requirements

### Requirement: Launch and verify application
The smoke test SHALL launch the built application, detect its window, verify the sidecar log has no ERROR entries, verify the database is accessible, and clean up.

#### Scenario: Application launches without error
- **WHEN** `04_launch_and_verify.sh` is executed after a successful build
- **THEN** the app executable launches, the process stays alive for at least 5 seconds, and the test exits with code 0

#### Scenario: Window detection succeeds
- **WHEN** the app is running
- **THEN** PowerShell `Get-Process` detects an `alias_agent` process within 30 seconds

#### Scenario: Sidecar log has no critical errors
- **WHEN** `verify_logs` runs after app launch
- **THEN** if `sidecar.log` exists, lines containing `[ERROR]` are treated as smoke test failure

#### Scenario: Database is accessible
- **WHEN** `verify_db` runs after app launch
- **THEN** `aliasagent.db` exists and contains expected tables
