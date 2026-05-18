#ifndef TOOLS_H
#define TOOLS_H

#include <string>

namespace tools {

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

/// Read a text file, returning its content.
/// Returns JSON: {"ok":true,"content":"..."} or {"ok":false,"error":"..."}
std::string read_file(const std::string& path);

/// List directory contents.
/// Returns JSON: {"ok":true,"entries":[{"name":"...","type":"file|directory"},...]}
/// or {"ok":false,"error":"..."}
std::string list_dir(const std::string& path);

} // namespace tools

#endif
