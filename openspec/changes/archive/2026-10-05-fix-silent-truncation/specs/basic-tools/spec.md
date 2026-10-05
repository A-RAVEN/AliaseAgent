# basic-tools Specification

## MODIFIED Requirements

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
