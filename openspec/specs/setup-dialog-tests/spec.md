## ADDED Requirements

### Requirement: Setup dialog renders
The system SHALL render a setup dialog with API key input field and Start button when no config exists.

#### Scenario: Dialog shows on first launch
- **WHEN** the app has no config file and shows the SetupDialog
- **THEN** a TextField for API key entry is displayed
- **AND** a "Start" button is displayed

### Requirement: Setup dialog validates input
The system SHALL not allow submission with an empty API key.

#### Scenario: Empty API key blocked
- **WHEN** the user taps Start with an empty API key field
- **THEN** the dialog does not dismiss
- **AND** a validation error ("Please enter an API key") is shown

### Requirement: Setup dialog creates config on valid submit
The system SHALL call the onComplete callback when a valid API key is submitted.

#### Scenario: Valid API key submitted
- **WHEN** user enters a non-empty API key and taps Start
- **THEN** the onComplete callback is invoked
- **AND** ConfigService.save() is called with a config containing the entered API key

### Requirement: Setup dialog is non-dismissible
The system SHALL prevent dismissing the setup dialog by tapping outside (barrierDismissible: false).

#### Scenario: Cannot dismiss by tapping outside
- **WHEN** the setup dialog is displayed via showDialog with barrierDismissible: false
- **THEN** tapping outside the dialog does not close it
