## MODIFIED Requirements

### Requirement: Tool definitions
The Dart-side `_toolDefs` SHALL include `get_current_time`, a zero-parameter tool that returns the current local date and time. This tool SHALL be always available (not conditional on search provider configuration).

#### Scenario: get_current_time is registered
- **WHEN** `_toolDefs` is built
- **THEN** `get_current_time` SHALL be present with name, description, and empty input_schema
