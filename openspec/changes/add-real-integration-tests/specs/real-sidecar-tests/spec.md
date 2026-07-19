## ADDED Requirements

### Requirement: set_workspace FFI call succeeds
The system SHALL verify that `set_workspace` FFI function can be called and returns a valid result.

#### Scenario: set valid workspace directory
- **WHEN** `set_workspace` is called with a valid directory path
- **THEN** the function returns without crash and the return value is a non-null string

### Requirement: read_file FFI call returns correct content
The system SHALL verify that `read_file` FFI function can read a known file and return correct content.

#### Scenario: read existing text file
- **WHEN** `read_file` is called with the path to `pubspec.yaml`
- **THEN** the return JSON contains `"ok":true` and content contains the string "alias_agent"

### Requirement: list_dir FFI call returns JSON array
The system SHALL verify that `list_dir` FFI function can list a known directory.

#### Scenario: list project test directory
- **WHEN** `list_dir` is called with the path to `test/unit/`
- **THEN** the return JSON contains `"ok":true` and content is a valid JSON array containing `sidecar_bridge_test.dart`

### Requirement: ensure_search_infra returns ok without hanging
The system SHALL verify that `ensure_search_infra("{}")` completes within 5 seconds and returns success.

#### Scenario: empty config returns ok
- **WHEN** `ensure_search_infra` is called with empty config `"{}"`
- **THEN** the function returns within 5 seconds and the response JSON contains `"ok":true`

### Requirement: get_search_providers returns valid JSON
The system SHALL verify that `get_search_providers` returns a parseable JSON array.

#### Scenario: get providers after init
- **WHEN** `get_search_providers` is called after `ensure_search_infra("{}")`
- **THEN** the function returns a valid JSON array (may be empty if no providers configured)

### Requirement: sidecar DLL loads without missing dependencies
The system SHALL verify that `DynamicLibrary.open('sidecar.dll')` succeeds.

#### Scenario: DLL loads successfully
- **WHEN** `DynamicLibrary.open` is called with the path to `sidecar.dll`
- **THEN** no `ArgumentError` is thrown, indicating all DLL dependencies are resolved, and `read_file` symbol can be looked up
