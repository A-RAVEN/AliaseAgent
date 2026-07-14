## ADDED Requirements

### Requirement: read_file returns file content
The C++ Sidecar SHALL return JSON `{"ok":true,"content":"..."}` for a valid text file within the workspace.

#### Scenario: Read existing text file
- **WHEN** read_file is called with a path to an existing text file within the workspace
- **THEN** returns JSON with ok:true and the file content as string

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

### Requirement: list_dir returns directory entries
The C++ Sidecar SHALL return JSON with entries array for a valid directory within the workspace.

#### Scenario: List directory with files and subdirs
- **WHEN** list_dir is called on a directory containing files and subdirectories
- **THEN** returns JSON with ok:true and entries array with name and type for each entry

### Requirement: list_dir handles not found and not-a-directory
The C++ Sidecar SHALL return appropriate errors for invalid paths.

#### Scenario: Directory not found
- **WHEN** list_dir is called with a non-existent path
- **THEN** returns JSON with ok:false and error "Directory not found: <path>"

#### Scenario: Path is a file
- **WHEN** list_dir is called on a file path
- **THEN** returns JSON with ok:false and error "Not a directory: <path>"
