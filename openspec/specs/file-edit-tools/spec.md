## ADDED Requirements

### Requirement: read_file with line numbers and partial reading
The `read_file` tool SHALL return file content with 1-indexed line number prefixes (cat -n format). It SHALL support optional `offset` (start line) and `limit` (line count) parameters for partial reading. Files exceeding 2000 lines SHALL be truncated with a notice when read without offset/limit. Invalid offset values SHALL return an error.

#### Scenario: Full file read with line numbers
- **WHEN** `read_file` is called with only a path
- **THEN** the response content SHALL have each line prefixed with its 1-indexed line number, up to 2000 lines

#### Scenario: Partial read with offset and limit
- **WHEN** `read_file` is called with `{"path": "main.dart", "offset": 100, "limit": 50}`
- **THEN** the response SHALL contain lines 100-149 with their original line numbers

#### Scenario: Large file truncation
- **WHEN** `read_file` is called on a file with more than 2000 lines without offset/limit
- **THEN** the response SHALL contain the first 2000 lines and a notice indicating the total line count and how to read more

#### Scenario: Invalid offset rejected
- **WHEN** `read_file` is called with offset <= 0
- **THEN** the response SHALL return `{"ok":false, "error":"offset must be >= 1"}`

#### Scenario: Offset exceeds file length
- **WHEN** `read_file` is called with offset greater than total file lines
- **THEN** the response SHALL return `"offset exceeds file length (N lines)"` with empty content

### Requirement: write_file creates or overwrites files
The system SHALL provide a `write_file` tool that creates a new file (including parent directories) or overwrites an existing file within the workspace. The response SHALL indicate whether the file was created or overwritten.

#### Scenario: Create new file
- **WHEN** `write_file` is called with a path that does not exist and valid content
- **THEN** the file SHALL be created with the given content, parent directories created if needed, and the response SHALL include `{"ok":true, "bytes_written": N, "created": true}`

#### Scenario: Overwrite existing file
- **WHEN** `write_file` is called with a path that already exists
- **THEN** the file content SHALL be completely replaced with the new content, and the response SHALL include `{"ok":true, "created": false}`

#### Scenario: Path outside workspace rejected
- **WHEN** `write_file` is called with a path that resolves outside the workspace
- **THEN** the response SHALL be `{"ok":false, "error":"Access denied: path outside workspace"}`

### Requirement: edit_file with exact string matching
The `edit_file` tool SHALL accept a required `edits` array of 1..N replacement pairs `{old_text, new_text, replace_all?}`, replacing the former single-pair top-level fields (`old_text`/`new_text`/`replace_all` are removed — BREAKING). Each pair's `old_text` SHALL be non-empty (empty string rejected immediately with `{"ok":false,"error":"old_text must not be empty"}`). All replacements SHALL be validated against the original file content first; if any `old_text` is absent, or matches multiple locations without `replace_all:true`, the entire request SHALL fail with zero modifications. Overlapping match ranges between different edit pairs SHALL be rejected. After all validations pass, replacements SHALL be applied in reverse order of their per-hit byte offsets in the original content (every individual hit position, not per-pair, not array order — a `replace_all` pair contributes all its hit positions) so earlier positions are unaffected. Each pair SHALL independently support `replace_all:true`. The three-tier matching (exact → whitespace-normalized → diagnostic) SHALL apply per pair. The existing protections SHALL remain in effect for the whole request: non-text files (NUL in first 512 bytes) rejected, files larger than 1MB rejected, directories rejected.

#### Scenario: Single replacement
- **WHEN** `edit_file` is called with `{"path": "main.dart", "edits": [{"old_text": "a", "new_text": "b"}]}`
- **THEN** the first exact occurrence is replaced and the response reports 1 replacement

#### Scenario: Multiple replacements in one call
- **WHEN** `edit_file` is called with `edits` containing 3 non-overlapping pairs
- **THEN** all 3 replacements are applied in a single call and the response reports 3 replacements
- **NOTE** the `replacements` count is the total number of applied hit positions (a `replace_all` pair contributing N hits counts N), not the number of pairs (third-round finding F12)

#### Scenario: Any failed match aborts all
- **WHEN** one pair's `old_text` is not found in the file while other pairs would match
- **THEN** the entire request SHALL return `{"ok":false}` with an error identifying the failing pair, and NO edit is applied (zero modifications)

#### Scenario: Non-unique match without replace_all rejected
- **WHEN** a pair's `old_text` matches multiple locations and its `replace_all` is false
- **THEN** the request SHALL fail with match-location details, and no edits are applied

#### Scenario: Overlapping edits rejected
- **WHEN** two pairs' match ranges overlap in the original content
- **THEN** the request SHALL fail with an "edits overlap" error and no edits are applied

#### Scenario: Per-pair replace_all
- **WHEN** one pair has `replace_all:true` and another does not
- **THEN** only the `replace_all` pair replaces all its occurrences; the other replaces only its first occurrence

#### Scenario: Empty edits array rejected
- **WHEN** `edits` is empty or missing
- **THEN** the response SHALL be `{"ok":false, "error":"edits must contain at least one replacement"}`

#### Scenario: Edits array length limit
- **WHEN** `edits` contains more than 100 pairs
- **THEN** the response SHALL be `{"ok":false}` with an error indicating the length limit is exceeded, and no edits are applied

#### Scenario: Empty old_text rejected
- **WHEN** any pair's `old_text` is an empty string
- **THEN** the response SHALL be `{"ok":false, "error":"old_text must not be empty"}` and no edits are applied (prevents an infinite replace loop)

#### Scenario: Existing protections retained
- **WHEN** the target file is binary (NUL in first 512 bytes) or larger than 1MB
- **THEN** the request SHALL fail with the existing error messages (`"Cannot edit binary or non-text file"` / `"File too large for edit_file (>1MB)"`) and no edits are applied

### Requirement: Whitespace-normalized matching
When exact matching fails, the system SHALL attempt matching after normalizing whitespace (CRLF→LF, dominant indent style→spaces, trailing whitespace removal). Multiple normalized matches SHALL be rejected with line numbers, same as exact matching.

#### Scenario: CRLF vs LF mismatch auto-corrected
- **WHEN** the file uses CRLF line endings and `old_text` uses LF
- **THEN** the system SHALL match after normalization and perform the edit, returning a note that whitespace normalization was applied

#### Scenario: Indentation mismatch auto-corrected
- **WHEN** the file uses detected dominant indentation and `old_text` uses a different indentation style
- **THEN** the system SHALL match after normalization if the match is unique

#### Scenario: Normalized match ambiguous returns line numbers
- **WHEN** whitespace normalization produces multiple matches
- **THEN** the edit SHALL be rejected with an error listing the matching line numbers (same behavior as Tier 1 multiple match)

### Requirement: Diagnostic error on match failure
When both exact and normalized matching fail, the system SHALL return diagnostic information to help the AI correct its `old_text`.

#### Scenario: Closest match provided
- **WHEN** `old_text` does not match the file even after normalization
- **THEN** the response SHALL include the closest matching text (by edit distance), its line number, and a list of specific differences (indentation, missing characters, line endings)

#### Scenario: File metadata provided
- **WHEN** an edit fails
- **THEN** the response SHALL include the file's detected indentation style and line ending format

### Requirement: Non-text file protection
The system SHALL reject `edit_file` operations on files that appear to be non-text (NUL bytes in the first 512 bytes) or are too large for efficient matching (>1MB).

#### Scenario: Non-text file edit rejected
- **WHEN** `edit_file` is called on a file containing NUL bytes within the first 512 bytes
- **THEN** the response SHALL be `{"ok":false, "error":"Cannot edit binary or non-text file"}`. UTF-16 text files (NUL at every other byte) SHALL be rejected.

#### Scenario: Large file edit rejected
- **WHEN** `edit_file` is called on a file larger than 1MB
- **THEN** the response SHALL be `{"ok":false, "error":"File too large for edit_file (>1MB)"}`

### Requirement: File edit tools always available
The `write_file` and `edit_file` tools SHALL be registered unconditionally, alongside `read_file` and `list_dir`.

#### Scenario: Tools available without search providers
- **WHEN** no search providers are configured
- **THEN** `write_file` and `edit_file` SHALL still appear in the tool definitions sent to the AI
