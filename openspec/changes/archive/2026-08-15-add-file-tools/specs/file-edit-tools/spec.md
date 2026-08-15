## MODIFIED Requirements

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
