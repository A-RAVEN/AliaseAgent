# Basic Tools — Spec

## ADDED Requirements

### Requirement: Read file tool
The C++ Sidecar SHALL implement a `read_file` tool that reads the content of a file at a given path and returns it as a string. The path SHALL be restricted to the current workspace directory.

#### Scenario: Read existing text file
- **WHEN** `read_file` is invoked with a valid path to a text file within the workspace
- **THEN** the file content is returned as a string

#### Scenario: File not found
- **WHEN** `read_file` is invoked with a path that does not exist
- **THEN** an error message "File not found: <path>" is returned

#### Scenario: Path outside workspace
- **WHEN** `read_file` is invoked with a path that resolves outside the designated workspace directory
- **THEN** an error message "Access denied: path outside workspace" is returned

#### Scenario: Binary file
- **WHEN** `read_file` is invoked on a binary file
- **THEN** an error message "Cannot read binary file" is returned (or content is truncated with warning)

### Requirement: List directory tool
The C++ Sidecar SHALL implement a `list_dir` tool that lists the contents of a directory at a given path, returning file/directory names with type indicators. The path SHALL be restricted to the current workspace directory.

#### Scenario: List directory contents
- **WHEN** `list_dir` is invoked with a valid directory path within the workspace
- **THEN** a list of entries is returned, each with name and type (file or directory)

#### Scenario: Directory not found
- **WHEN** `list_dir` is invoked with a path that does not exist
- **THEN** an error message "Directory not found: <path>" is returned

#### Scenario: Path is a file
- **WHEN** `list_dir` is invoked on a path that is a file, not a directory
- **THEN** an error message "Not a directory: <path>" is returned

#### Scenario: Path outside workspace
- **WHEN** `list_dir` is invoked with a path that resolves outside the designated workspace directory
- **THEN** an error message "Access denied: path outside workspace" is returned

### Requirement: Tool execution isolation
Tool execution in the C++ Sidecar SHALL NOT block the HTTP streaming or UI. Tool results SHALL be returned synchronously to the caller (Dart or internal tool-use loop).

#### Scenario: File read completes quickly
- **WHEN** `read_file` is invoked on a small file
- **THEN** the result is returned within a reasonable time (< 100ms for files under 1MB)

### Requirement: Workspace path configuration
The workspace directory used for tool path restriction SHALL be passed from Dart to C++ at initialization time.

#### Scenario: Workspace set at startup
- **WHEN** the C++ Sidecar is initialized
- **THEN** the workspace directory path is stored and used for all subsequent tool path validations

#### Scenario: Workspace can be changed
- **WHEN** Dart calls `set_workspace` with a new path
- **THEN** the workspace directory is updated for subsequent tool calls