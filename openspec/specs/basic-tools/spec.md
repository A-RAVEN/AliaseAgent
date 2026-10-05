# Basic Tools — Spec

## Purpose
本文件规定最基础的三个文件工具（读文件、列目录、工具执行隔离）的行为与边界。
## Requirements
### Requirement: Read file tool
The C++ Sidecar SHALL implement a `read_file` tool that reads the content of a file at a given path and returns it as a string. The path SHALL be restricted to the current workspace directory.

**行数上限的处置**（只改这一处措辞与它的可见性，不改工具行为）：缺省一次返回 2000 行，调用方可以用 `offset` / `limit` 取更后面的段落（`limit` 上限 100000）。超过缺省量时返回的文本 SHALL 在结尾给出一句**可执行的**续读说明：文件总行数、本次给出的是哪一段、下一段该用什么参数取（例如"见 1-2000 行，继续读用 offset=2001"）。SHALL NOT 只说"被截断了"而不给续读参数。

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

#### Scenario: 超过缺省行数时的续读说明

- **WHEN** `read_file` 读的文件超过 2000 行且调用方没有给 `offset` / `limit`
- **THEN** 返回文本的结尾 SHALL 含文件总行数、本次给出的行区间、以及一个能直接照抄的续读参数（形如 `offset=<下一段起始行>`）；把这三样里任何一样去掉 SHALL 让对应用例失败

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

### Requirement: Tool definitions
The Dart-side `_toolDefs` SHALL include `get_current_time`, a zero-parameter tool that returns the current local date and time. This tool SHALL be always available (not conditional on search provider configuration).

#### Scenario: get_current_time is registered
- **WHEN** `_toolDefs` is built
- **THEN** `get_current_time` SHALL be present with name, description, and empty input_schema

