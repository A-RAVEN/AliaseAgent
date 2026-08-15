#ifndef TOOLS_H
#define TOOLS_H

#include <string>
#include <nlohmann/json.hpp>

namespace tools {

/// Escape special characters for JSON string embedding.
/// Handles: " \ \n \r \t and control characters (0x00-0x1F → \uXXXX)
std::string json_escape(const std::string& s);

/// Initialize the workspace and validate it exists.
/// Returns empty string on success, error message on failure.
std::string set_workspace(const std::string& path);

/// Get the current workspace path (canonical form).
const std::string& workspace();

/// Resolve a relative/absolute path to canonical absolute form.
/// The input path is resolved relative to the current workspace.
/// Returns empty string if resolution fails.
std::string resolve(const std::string& path);

/// Check whether a resolved path is within the workspace boundary.
bool is_within_workspace(const std::string& resolved);

/// Read a text file with line numbers, returning its content.
/// Request JSON: {"path":"...", "offset":N, "limit":M}
///   offset (optional, 1-indexed, default 1)
///   limit  (optional, default 2000)
/// Returns JSON:
///   {"ok":true,"content":"...","total_lines":N,"start_line":M,"end_line":K}
///   or {"ok":false,"error":"..."}
/// Content uses cat -n format: right-aligned 6-digit line number + tab + text.
/// Files >2000 lines are truncated with a notice when read without offset/limit.
std::string read_file(const std::string& request_json);

/// Create or overwrite a file within the workspace.
/// Request JSON: {"path":"...", "content":"..."}
/// Returns JSON:
///   {"ok":true,"path":"...","bytes_written":N,"created":true|false}
///   or {"ok":false,"error":"..."}
std::string write_file(const std::string& request_json);

/// Edit a file by replacing text using three-tier matching.
/// Request JSON: {"path":"...", "old_text":"...", "new_text":"...", "replace_all":false}
/// Returns JSON:
///   {"ok":true,"replacements":N}  (N >= 1)
///   or {"ok":false,"error":"...", "diagnosis":{...}}
/// Matches: exact → whitespace-normalized → diagnostic error.
std::string edit_file(const std::string& request_json);

/// List directory contents.
/// Returns JSON: {"ok":true,"content":"[{\"name\":\"...\",\"type\":\"file|directory\"},...]"}
/// or {"ok":false,"error":"..."}
std::string list_dir(const std::string& path);

/// Find files within the workspace matching a glob pattern (ripgrep-backed).
/// Request JSON: {"pattern":"...", "max_results":N}
/// Returns JSON: {"ok":true,"paths":["..."],"count":N,"truncated":true|false}
/// or {"ok":false,"error":"..."}
std::string glob_file(const std::string& request_json);

/// Search file contents with a regular expression (ripgrep-backed).
/// Request JSON: {"pattern":"...", "glob":"...", "ignore_case":bool, "max_results":N}
/// Returns JSON: {"ok":true,"matches":[{"path":"...","line":N,"text":"..."}],
///                "count":N,"truncated":true|false}
/// or {"ok":false,"error":"..."}
std::string grep_file(const std::string& request_json);

// ============================================================================
// Testable helpers (exposed for unit tests, like web_fetch.h)
// ============================================================================

/// Classify rg's exit-2 stderr: true = regex parse error ("invalid regex"),
/// false = other/soft error ("search failed"). rg exit 2 covers both
/// (Docs/ripgrepDoc.md section 4).
bool classify_grep_regex_error(const std::string& stderr_data);

/// Build a grep match entry {path, line?, text?} from an --json match message's
/// `data` object, de-rooting the path. Degrades when fields are absent
/// (path/lines via base64 `bytes`, missing line_number omitted).
/// Schema per Docs/ripgrepDoc.md section 1.1.
nlohmann::json build_match_entry(const nlohmann::json& data, const std::string& root);

} // namespace tools

#endif
