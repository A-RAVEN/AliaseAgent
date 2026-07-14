## ADDED Requirements

### Requirement: AppShell shows loading state
The system SHALL display a loading indicator while config is being loaded.

#### Scenario: Loading spinner on startup
- **WHEN** the app starts and config loading is in progress (first frame, before configLoader result)
- **THEN** a CircularProgressIndicator is displayed

### Requirement: AppShell shows config error
The system SHALL display an error message when the config file is malformed.

#### Scenario: Malformed config error display
- **WHEN** ConfigService.load() returns ConfigStatus.malformed
- **THEN** an error message is displayed in the app body (Scaffold with AppBar "Configuration Error")

### Requirement: AppShell triggers setup on missing config
The system SHALL display the setup dialog when no config file exists.

#### Scenario: No config triggers setup
- **WHEN** ConfigService.load() returns ConfigStatus.notFound
- **THEN** the SetupDialog is displayed via showDialog (after the postFrameCallback fires — requires second pump() in tests)

### Requirement: AppShell supports DI for testing
The system SHALL accept an optional config loading function to enable testing of boot states.

#### Scenario: Injected config loader used
- **WHEN** AppShell is constructed with an optional `ConfigResult Function()? configLoader` parameter
- **THEN** that loader is used instead of ConfigService.load()
- **AND** when not provided, defaults to ConfigService.load
