## ADDED Requirements

### Requirement: glob_file pattern-based file lookup
The system SHALL provide a `glob_file` tool that finds files within the workspace matching a glob pattern, with recursive traversal. The pattern SHALL support `*` (within a segment), `**` (across directories), `?` (single character), and `!` negation (gitignore-style globs — `Docs/ripgrepDoc.md` section 2 documents the gitignore-style semantics and `!` negation; the exact `*`/`?`/`**` matching rules are documented only by inference from "match .gitignore globs" and are UNVERIFIED, to be confirmed by live testing during implementation). The response SHALL list matching file paths relative to the search root (the workspace root by default), truncated to a configurable `max_results` (default 200); when truncated, the response SHALL include `"truncated":true`. The implementation SHALL be backed by ripgrep subprocess (`rg --files --no-require-git -g <pattern> <root>`, with `--no-require-git` ensuring gitignore rules are honored outside a git repository — `Docs/ripgrepDoc.md` section 8); if ripgrep is unavailable, the tool SHALL return a clear error stating how to install/place it. Exit codes SHALL be mapped per `Docs/ripgrepDoc.md` section 4: exit 0 (files found) and exit 1 (no files matched — a normal empty result, SHALL return an empty list, NOT an error) are successful; exit 2 (error) SHALL return `{"ok":false}` with a stderr-based message. Glob patterns SHALL be validated against an allowed character set before being passed to the subprocess; patterns containing a `..` path segment (a directory-traversal segment) or absolute paths SHALL be rejected (a `..` that is part of a single filename, e.g. `a..b.txt`, SHALL NOT be rejected). The subprocess SHALL be terminated after a 30s timeout.

#### Scenario: Find files by extension
- **WHEN** `glob_file` is called with `{"pattern": "lib/**/*.dart"}`
- **THEN** all `.dart` files under `lib/` are returned as relative paths, including nested directories
- **NOTE** the `**` (across directories) semantics are UNVERIFIED in `Docs/ripgrepDoc.md` (inferred from gitignore-style globs, same as `?`); live confirmation is required during implementation, and any discrepancy SHALL be reported to the user before adjusting this acceptance criterion

#### Scenario: Pattern without slash does not traverse segments
- **WHEN** `glob_file` is called with `{"pattern": "foo"}` and a file `foo/bar` exists
- **THEN** `foo/bar` is NOT returned (per ripgrep man page: "`foo/bar` does not match the glob `foo`"); matching subdirectories requires an explicit `foo/**` pattern

#### Scenario: Question mark matches single character
- **WHEN** `glob_file` is called with `{"pattern": "test/??_*.dart"}`
- **THEN** only files whose name starts with two arbitrary characters followed by `_` match
- **NOTE** this scenario's semantics are UNVERIFIED in `Docs/ripgrepDoc.md` (inferred from gitignore-style globs); live confirmation is required during implementation. If actual rg behavior differs from this scenario, the implementation SHALL record the discrepancy and report it to the user — adjusting this acceptance criterion requires explicit user approval (per project rules)

#### Scenario: Glob negation
- **WHEN** `glob_file` is called with a single pattern string beginning with `!` (e.g. `{"pattern": "!**/*.log"}`)
- **THEN** files matching the negated glob are excluded (single-pattern form only; the tool signature takes one pattern string, so multi-glob "later globs override earlier ones" precedence is NOT expressible through this tool — `Docs/ripgrepDoc.md` section 2)

#### Scenario: Search confined to workspace
- **WHEN** `glob_file` is called
- **THEN** the search root SHALL be the workspace root (no root parameter is exposed to the caller); the existing path sandbox (`check_path`) SHALL confine the search

#### Scenario: Result truncation
- **WHEN** more matches exist than `max_results`
- **THEN** the response SHALL contain at most `max_results` entries and include `"truncated":true`
- **NOTE** the implementation SHALL determine truncation by attempting to read one additional entry beyond `max_results` (if the total count is exactly `max_results`, no truncation is reported — avoiding a false `truncated:true` when the process is stopped at the limit)

#### Scenario: Path traversal rejected
- **WHEN** the pattern contains a `..` path segment or is an absolute path
- **THEN** the request SHALL be rejected before subprocess invocation
- **AND** a pattern whose `..` is inside a single filename segment (e.g. `a..b.txt`) SHALL NOT be rejected

#### Scenario: No files matched is success
- **WHEN** `glob_file` matches nothing (rg exit code 1)
- **THEN** the response SHALL be `{"ok":true}` with an empty list — NOT an error (exit 1 is a normal no-match result per `Docs/ripgrepDoc.md` section 4)

#### Scenario: Subprocess timeout
- **WHEN** the rg subprocess does not complete within 30s
- **THEN** the subprocess SHALL be terminated and the response SHALL be `{"ok":false}` with a timeout error

#### Scenario: rg missing
- **WHEN** ripgrep binary is not found
- **THEN** the response SHALL be `{"ok":false, "error":"..."}` explaining that ripgrep is required and how to install it

### Requirement: grep_file regex content search
The system SHALL provide a `grep_file` tool that searches file contents within the workspace using a regular expression, returning matches as `path:line:text` entries with line numbers, with paths returned relative to the workspace root (matching the registration requirement's "workspace-relative paths"). The line-number base is UNVERIFIED — `Docs/ripgrepDoc.md` does not document the `--json` schema; implementation SHALL confirm the actual field structure live and, if actual behavior differs from this requirement's scenarios, SHALL record the discrepancy and report it to the user — adjusting this acceptance criterion requires explicit user approval (per project rules). It SHALL support optional `glob` filtering (search only files matching a glob; the glob SHALL pass the same character-set validation as `glob_file`), `ignore_case` (default false, maps to rg `-i`), and `max_results` (default 100; when truncated the response SHALL include `"truncated":true`). Gitignore handling SHALL follow ripgrep's documented semantics: gitignore rules are honored with `--no-require-git` so they apply even outside a git repository, and `.ignore`/`.rgignore` are always honored (`Docs/ripgrepDoc.md` section 8); note that a non-empty `glob` overrides ignore logic per rg's documented `-g` semantics ("always overrides any other ignore logic"), so files matching the glob are searched even if gitignored. Whether rg skips binary files is UNVERIFIED in `Docs/ripgrepDoc.md` — the implementation SHALL rely on rg's actual behavior and record the result in the doc; this spec SHALL NOT promise binary skipping as a requirement. The implementation SHALL be backed by ripgrep subprocess (`rg --json -n --no-require-git --glob <glob> -- <pattern> <root>`, with the `--` separator isolating the pattern so it is never parsed as a flag; note `--json` combined with `--files` is an error, so the two tools use distinct command shapes). Exit codes SHALL be mapped per `Docs/ripgrepDoc.md` section 4: exit 0 (at least one match) and exit 1 (no match — a normal empty result, SHALL return an empty match list, NOT an error) are successful; exit 2 (error, covering both regex errors and soft errors such as unreadable files) SHALL be mapped by inspecting stderr: regex parse errors → `{"ok":false,"error":"invalid regex: ..."}`; other errors → `{"ok":false,"error":"search failed: <stderr summary>"}`. The subprocess SHALL be terminated after a 30s timeout, and missing rg SHALL return the same install guidance as `glob_file`.

#### Scenario: Find symbol references
- **WHEN** `grep_file` is called with `{"pattern": "request_mutex"}`
- **THEN** every matching line across the workspace is returned as `path:line:text` with its line number

#### Scenario: Glob-filtered search
- **WHEN** `grep_file` is called with `{"pattern": "TODO", "glob": "sidecar/src/*.cpp"}`
- **THEN** only `sidecar/src/*.cpp` files are searched for matches

#### Scenario: Case-insensitive search
- **WHEN** `grep_file` is called with `{"pattern": "TODAY", "ignore_case": true}`
- **THEN** matches include `today`, `Today`, and `TODAY`

#### Scenario: Invalid regex error
- **WHEN** `grep_file` is called with an invalid regular expression
- **THEN** the response SHALL be `{"ok":false}` with an error naming the regex problem (rg exit code 2)

#### Scenario: Pattern starting with dash is literal
- **WHEN** `grep_file` is called with `{"pattern": "-foo"}`
- **THEN** the pattern is treated as a literal search pattern, not a flag (the `--` separator isolates it)

#### Scenario: Glob with path traversal rejected
- **WHEN** `grep_file` is called with a `glob` containing a `..` path segment or an absolute path
- **THEN** the request SHALL be rejected before subprocess invocation
- **AND** a `glob` whose `..` is inside a single filename segment (e.g. `a..b.txt`) SHALL NOT be rejected

#### Scenario: Search confined to workspace
- **WHEN** `grep_file` is called
- **THEN** the search root SHALL be the workspace root (no root parameter is exposed to the caller); the existing path sandbox (`check_path`) SHALL confine the search

#### Scenario: Result truncation
- **WHEN** more matches exist than `max_results`
- **THEN** the response SHALL contain at most `max_results` entries and include `"truncated":true`
- **NOTE** with `--json` output the stream always ends with a `summary` message (never a bare EOF at the max_results+1 boundary — `Docs/ripgrepDoc.md` section 1); truncation SHALL be determined by message type: after collecting `max_results` match messages, keep reading — if the next message is another `match`, truncate with `"truncated":true`; if the next message is `summary` (or the stream ends), report exactly `max_results` without truncation (no false `truncated:true` when the total is exactly `max_results`)

#### Scenario: No matches is success
- **WHEN** `grep_file` is called with a pattern that matches nothing (rg exit code 1)
- **THEN** the response SHALL be `{"ok":true}` with an empty match list — NOT an error (exit 1 is a normal no-match result per `Docs/ripgrepDoc.md` section 4)

#### Scenario: Subprocess timeout
- **WHEN** the rg subprocess does not complete within 30s
- **THEN** the subprocess SHALL be terminated and the response SHALL be `{"ok":false}` with a timeout error

### Requirement: Search tools registration
The `glob_file` and `grep_file` tools SHALL be registered in the tool definitions sent to the AI, alongside the existing file tools, unconditionally (independent of search-provider configuration). Their descriptions SHALL state the sandbox scope (workspace-relative paths), the glob syntax, and the result limits.
