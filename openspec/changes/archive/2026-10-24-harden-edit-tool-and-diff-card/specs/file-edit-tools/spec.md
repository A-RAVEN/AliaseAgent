## ADDED Requirements

### Requirement: File writes are atomic

`write_file` and `edit_file` SHALL publish their result by writing the complete new content to a temporary file in the **same directory** as the target, flushing it, and then replacing the target by a rename (`MoveFileExW` with `MOVEFILE_REPLACE_EXISTING` on Windows, `rename` elsewhere). If any step fails, the target file SHALL retain its previous content byte-for-byte and the temporary file SHALL be removed. A successful write SHALL leave no temporary file behind.

#### Scenario: Successful edit leaves no temporary file

- **WHEN** `edit_file` succeeds on `notes.txt`
- **THEN** the file content equals the expected edited content, and the containing directory contains no entry whose name starts with `notes.txt.tmp`

#### Scenario: Failed publication keeps the original content

- **WHEN** the final rename fails (for example the target is read-only)
- **THEN** `edit_file` SHALL return `{"ok":false}` with an error mentioning that the file could not be replaced, the target file's bytes SHALL equal the bytes before the call, and no temporary file SHALL remain

#### Scenario: write_file uses the same atomic publication

- **WHEN** `write_file` overwrites an existing file
- **THEN** the overwrite SHALL go through the same temporary-file-and-rename path, and the pre-existing content SHALL be recoverable by the operating system's file system guarantees if the write never completes

### Requirement: edit_file requires a prior observation of the file

The `edit_file` tool SHALL refuse to edit a file that this process has not observed. A file counts as observed after a successful `read_file`, a successful `write_file`, or a successful `edit_file` on the same resolved absolute path. The refusal SHALL be reported with `{"ok":false, "code":"not_observed"}` and SHALL include an instruction to read the file first. No file content SHALL be modified when this refusal occurs.

Observation is per path, not per line range: a `read_file` that returned only the first 2000 lines of a longer file, or only an empty body because `offset` lay past the end, still counts as observing the whole file. This boundary SHALL be documented for users rather than silently implied.

#### Scenario: Editing a never-read file is refused

- **WHEN** `edit_file` is called on a path that no earlier tool call in this process has read or written
- **THEN** the response SHALL be `{"ok":false, "code":"not_observed"}` whose error text tells the caller to read the file first, and the file on disk SHALL be unchanged

#### Scenario: A file read earlier in the same process may be edited

- **WHEN** `read_file` succeeded on `a.txt` and `edit_file` is then called on `a.txt` with `old_text` present in that content
- **THEN** the edit SHALL be applied and the response SHALL be `{"ok":true, ...}`

#### Scenario: A file created by write_file may be edited immediately

- **WHEN** `write_file` created `new.txt` and `edit_file` is then called on `new.txt`
- **THEN** the edit SHALL be applied without requiring an intervening `read_file`

#### Scenario: The same file through a different spelling counts as observed

- **WHEN** `read_file` succeeded on `dir/a.txt` and `edit_file` is called on `dir/../dir/a.txt`
- **THEN** the observation SHALL apply (comparison uses the resolved absolute path) and the edit SHALL proceed

#### Scenario: Unreadable targets keep their existing error rather than reporting not_observed

- **WHEN** `edit_file` is called on a directory, on a file larger than 1MB, or on a file whose first 512 bytes contain a NUL byte, and that target was never observed
- **THEN** the response SHALL be the existing error for that condition (`Path is a directory, not a file: …`, `File too large for edit_file (>1MB)`, or `Cannot edit binary or non-text file`) and SHALL NOT be `not_observed`

#### Scenario: Reading an empty file counts as an observation

- **WHEN** `read_file` returns `ok:true` for an empty file and `edit_file` is then called on that path
- **THEN** the response SHALL NOT be `not_observed` (whatever the match outcome)

### Requirement: edit_file rejects a stale observation

The system SHALL record each observed file's modification time and byte size, and `edit_file` SHALL compare the target's current modification time and size with the recorded values **before** reading the content and **before** attempting to match `old_text`. When they differ, the tool SHALL refuse with `{"ok":false, "code":"stale"}`, SHALL instruct the caller to read the file again, and SHALL NOT modify the file. This check SHALL run **after** the existing existence, directory, size and binary protections — so an unreadable or oversized target still reports its existing error — and **before** matching, so that an edit based on old content reports staleness rather than a misleading "not found".

This requirement takes precedence over the existing "Diagnostic error on match failure" requirement in the case where the recorded version no longer matches: that requirement continues to apply when the version still matches and the text simply does not. Likewise, every other `edit_file` scenario in this capability assumes the target was observed first; where a scenario does not say so, reading the file first is implied.

#### Scenario: External modification is detected

- **WHEN** `read_file` succeeded on `a.txt`, the file is then modified outside the tools (content and size changed), and `edit_file` is called with `old_text` that still exists in the new content
- **THEN** the response SHALL be `{"ok":false, "code":"stale"}`, the file SHALL be unchanged, and the error text SHALL tell the caller to read the file again

#### Scenario: Staleness wins over a match failure

- **WHEN** the file changed after being read and the supplied `old_text` no longer exists in the current content
- **THEN** the response SHALL be `{"ok":false, "code":"stale"}` rather than a "not found" diagnostic, because the caller's content basis is outdated

#### Scenario: Reading again clears the staleness

- **WHEN** a `stale` refusal occurred and `read_file` then succeeds on the same path with no further external change
- **THEN** a following `edit_file` with content from that new read SHALL apply successfully

#### Scenario: An edit the tool itself performed counts as an observation

- **WHEN** `read_file` succeeded on `a.txt`, `edit_file` replaced `aaa` with `bbb`, and a second `edit_file` then replaces `bbb` with `ccc` **without** an intervening `read_file`
- **THEN** the second edit SHALL apply without reporting `stale` or `not_observed` (a successful edit records the new version)

#### Scenario: A read that only reports an offset past the end still counts

- **WHEN** `read_file` returned `ok:true` with the `offset exceeds file length` notice and `edit_file` is then called on that path
- **THEN** the response SHALL NOT be `not_observed`

### Requirement: edit_file reports the applied hunks

A successful `edit_file` response SHALL include a `hunks` array describing what was actually replaced. Each element SHALL be `{start_line, old_text, new_text}` where `start_line` is the 1-based line number of the replacement's start in the original file, `old_text` is the exact byte sequence removed from disk, and `new_text` is the text written in its place. There SHALL be one element per applied hit position (a `replace_all` pair contributing N hits produces N elements), ordered by ascending start offset. When whitespace-normalized matching produced the hit, `old_text` SHALL be the bytes actually replaced, not the caller's original `old_text`. The existing `replacements` count and optional `matched_with` field SHALL be unchanged. When the serialized `hunks` would exceed **1MB** (the same bound `edit_file` already applies to the file itself), the response SHALL omit `hunks` and instead carry `"hunks_omitted": "too large"` together with the unchanged `replacements` count — the omission SHALL be stated, never silent.

#### Scenario: Line numbers and exact replaced bytes

- **WHEN** `edit_file` replaces `bar` with `BAR` on the third line of a file
- **THEN** the response SHALL contain `hunks` with exactly one element whose `start_line` is `3`, `old_text` is `bar`, and `new_text` is `BAR`, and the file SHALL contain `BAR` at that position

#### Scenario: One element per applied hit

- **WHEN** one pair uses `replace_all:true` and matches 3 occurrences at lines 2, 7 and 9
- **THEN** `hunks` SHALL contain 3 elements ordered by line (2, 7, 9) and `replacements` SHALL be 3

#### Scenario: Normalized match reports the bytes actually replaced

- **WHEN** the file contains a Tab where `old_text` used spaces and the hit is found through whitespace normalization
- **THEN** that hunk's `old_text` SHALL contain the Tab as it exists on disk, and `matched_with` SHALL still be reported

#### Scenario: Multi-line replacement reports its starting line

- **WHEN** a pair replaces three consecutive lines starting at line 10
- **THEN** that hunk's `start_line` SHALL be `10` and `old_text` SHALL contain the three removed lines joined by `\n`

#### Scenario: Failure responses carry no hunks

- **WHEN** any `edit_file` validation fails (empty array, empty `old_text`, overlap, ambiguous match, I/O error)
- **THEN** the response SHALL be `{"ok":false, ...}` with no `hunks` key and the file SHALL be unchanged

#### Scenario: Oversized hunks are omitted with a stated reason

- **WHEN** a successful edit produces hunks whose serialized form would exceed 1MB (for example a single-character `replace_all` over a large file)
- **THEN** the response SHALL carry `{"ok":true, "replacements": N, "hunks_omitted":"too large"}` with no `hunks` key, and the file SHALL contain the fully applied edit
