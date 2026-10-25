## Purpose

约束工具执行：工作区限制、参数校验、结果形状与错误分支。

## Requirements

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

### Requirement: run_command 的结果头尾都留，且引用可读

`run_command` SHALL 按 `tool-output-spill` 的契约交付结果：stdout 与 stderr 的完整输出各先落盘（`<会话>/<6 位序号>-<流>.txt`），超限时内联头尾各 `preview_chars` 个字符（缺省 1000）并给出引用。

SHALL NOT 再保留"只截到尾部 + 系统临时文件路径"的旧行为。

> **2026-10-25 修改（对抗验证后）**：初稿这里写的是"也 SHALL NOT 在 Dart 侧对结果做第二次截断"，那条与实现正好相反 —— `lib/main.dart` 的 `elideOversizedToolResult` 对**每个**工具结果（含 `run_command`）都生效，正文超过 8000 字符就保头保尾砍中段。本变更真正保证的是：**引用与省略量留在正文最后一行，所以那道通用截断掐不到它们**（判据见 `tasks.md` 的 3.2 / 9.1 / 9.2），而不是"不截"。

#### Scenario: 构建失败的头一条错误可见
- **WHEN** 执行一条先打印 500 行日志、再在头部第 2 行打出 `error C2065` 的命令
- **THEN** 结果里 SHALL 能看到那条 `error C2065`（因为它落在头部 1000 字符内），且 SHALL 给出 spill 引用

#### Scenario: 尾部也在
- **WHEN** 同一条命令的最后一行是 `Build FAILED.`
- **THEN** 结果里 SHALL 也能看到 `Build FAILED.`（落在尾部 1000 字符内）

#### Scenario: 通用截断发生时引用仍可见
- **WHEN** 把 `preview_chars` 配到 4000（头尾合计 8000），使整段结果必然超过 `kToolResultElisionThreshold`
- **THEN** 结果的最后一行 SHALL 仍含 spill 引用与省略量（它们不落在被砍掉的中段里），且 `read_spill` 能按该引用读回文件里的任意合法区间

#### Scenario: 两条流同时超限时各给一个引用
- **WHEN** 一条命令的 stdout 与 stderr 都远超预览阈值
- **THEN** 两条流的截断字段 SHALL 都为真，且 SHALL 各给一个引用；两个引用 SHALL 指向**不同**文件，两个文件 SHALL 各自等于该条流的完整输出字节数

