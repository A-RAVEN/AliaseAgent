## ADDED Requirements

### Requirement: set_workspace configures the workspace root
The C++ Sidecar SHALL validate and set the workspace directory, returning an error message on failure or empty string on success.

#### Scenario: Valid directory
- **WHEN** set_workspace is called with an existing directory path
- **THEN** returns empty string ""
- **AND** g_workspace is set to the canonical path

#### Scenario: Empty path
- **WHEN** set_workspace is called with an empty string
- **THEN** returns "Workspace path is empty"
- **AND** g_workspace is cleared

#### Scenario: Invalid path
- **WHEN** set_workspace is called with a path that cannot be canonicalized
- **THEN** returns "Invalid workspace path: <path>"
- **AND** g_workspace is cleared

#### Scenario: Path is not a directory
- **WHEN** set_workspace is called with a path to a file
- **THEN** returns "Workspace is not a directory: <path>"
- **AND** g_workspace is cleared

### Requirement: read_file returns file content
The C++ Sidecar SHALL return JSON `{"ok":true,"content":"..."}` for a valid text file within the workspace.

#### Scenario: Read existing text file
- **WHEN** read_file is called with a path to an existing text file within the workspace
- **THEN** returns JSON with ok:true and the file content as string in the "content" field

#### Scenario: Read empty file
- **WHEN** read_file is called with a path to an empty file
- **THEN** returns `{"ok":true,"content":""}`

### Requirement: read_file handles file not found
The C++ Sidecar SHALL return an error when the file does not exist.

#### Scenario: File does not exist
- **WHEN** read_file is called with a non-existent path
- **THEN** returns JSON with ok:false and error "File not found: <path>"

### Requirement: read_file handles path outside workspace
The C++ Sidecar SHALL reject paths that resolve outside the workspace directory.

#### Scenario: Path traversal attempt
- **WHEN** read_file is called with a path containing ".." that escapes the workspace
- **THEN** returns JSON with ok:false and error "Access denied: path outside workspace"

### Requirement: read_file handles binary files
The C++ Sidecar SHALL detect and reject binary files.

#### Scenario: Binary file
- **WHEN** read_file is called with a path to a binary file (null bytes or >30% non-printable characters)
- **THEN** returns JSON with ok:false and error "Cannot read binary file"

### Requirement: read_file handles path-is-directory
The C++ Sidecar SHALL reject paths that point to directories.

#### Scenario: Path is a directory
- **WHEN** read_file is called with a path to a directory
- **THEN** returns JSON with ok:false and error "Path is a directory, not a file: <path>"

### Requirement: read_file handles no workspace set
The C++ Sidecar SHALL return an error when no workspace has been configured.

#### Scenario: No workspace set
- **WHEN** read_file is called but g_workspace is empty
- **THEN** returns JSON with ok:false and error "No workspace set"

### Requirement: read_file handles unresolvable path
The C++ Sidecar SHALL return an error when a path cannot be canonicalized.

#### Scenario: Cannot resolve path *(best-effort)*
- **WHEN** read_file is called with a path that canonical() cannot resolve (workspace is set)
- **THEN** returns JSON with ok:false and error "Cannot resolve path: <path>"
- **NOTE**: Platform-dependent. Unix: `realpath()` fails for non-existent paths under a valid workspace; Windows: `GetFullPathNameA` succeeds for most inputs. Test is best-effort — skip with `WARN` if platform cannot trigger.

### Requirement: list_dir returns directory entries
The C++ Sidecar SHALL return JSON with entries as a JSON-escaped string in the "content" field for a valid directory within the workspace.
NOTE: The implementation uses the shared `ok_result()` helper, so the entries JSON array is a JSON-escaped string inside `"content"`, NOT a direct `"entries"` key.

#### Scenario: List directory with files and subdirs
- **WHEN** list_dir is called on a directory containing files and subdirectories
- **THEN** returns `{"ok":true,"content":"[{\"name\":\"...\",\"type\":\"file\"},{\"name\":\"...\",\"type\":\"directory\"}]"}` where the array is a JSON-escaped string

#### Scenario: List empty directory
- **WHEN** list_dir is called on an empty directory (only . and ..)
- **THEN** returns `{"ok":true,"content":"[]"}`

### Requirement: list_dir handles not found and not-a-directory
The C++ Sidecar SHALL return appropriate errors for invalid paths.

#### Scenario: Directory not found
- **WHEN** list_dir is called with a non-existent path
- **THEN** returns JSON with ok:false and error "Directory not found: <path>"

#### Scenario: Path is a file
- **WHEN** list_dir is called on a file path
- **THEN** returns JSON with ok:false and error "Not a directory: <path>"

### Requirement: list_dir handles access denied
The C++ Sidecar SHALL reject paths outside the workspace.

#### Scenario: Path traversal attempt
- **WHEN** list_dir is called with a path containing ".." that escapes the workspace
- **THEN** returns JSON with ok:false and error "Access denied: path outside workspace"

### Requirement: list_dir handles cannot-read and no-workspace
The C++ Sidecar SHALL return appropriate errors for unreadable directories and missing workspace.

#### Scenario: Cannot read directory (permissions) *(best-effort)*
- **WHEN** list_dir is called on a directory that passes path_exists/is_dir but cannot be opened (OS-level permissions)
- **THEN** returns JSON with ok:false and error "Cannot read directory: <path>"
- **NOTE**: Requires OS-level permission restriction (e.g., ACLs on Windows, chmod on Unix). Best-effort — skip with `WARN` if test environment cannot set up the precondition.

#### Scenario: No workspace set
- **WHEN** list_dir is called but g_workspace is empty
- **THEN** returns JSON with ok:false and error "No workspace set"

#### Scenario: Cannot resolve path *(best-effort)*
- **WHEN** list_dir is called with a path that canonical() cannot resolve (workspace is set)
- **THEN** returns JSON with ok:false and error "Cannot resolve path: <path>"
- **NOTE**: Same platform constraints as `read_file` Cannot resolve path — best-effort.
