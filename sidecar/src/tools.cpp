#include "tools.h"
#include "logger.h"

#include <string>
#include <vector>
#include <fstream>
#include <sstream>
#include <algorithm>
#include <cstring>
#include <nlohmann/json.hpp>

#ifdef _WIN32
#include <windows.h>
#include <direct.h>
#define mkdir_impl(p) _mkdir(p)
#else
#include <limits.h>
#include <stdlib.h>
#include <dirent.h>
#include <sys/stat.h>
#define mkdir_impl(p) mkdir(p, 0755)
#endif

using json = nlohmann::json;

namespace tools {

// ---------------------------------------------------------------------------
// Internal state
// ---------------------------------------------------------------------------

static std::string g_workspace; // canonical form

// ---------------------------------------------------------------------------
// Path utilities
// ---------------------------------------------------------------------------

#ifdef _WIN32

static std::string canonical(const std::string& path) {
  char buf[MAX_PATH];
  DWORD len = GetFullPathNameA(path.c_str(), MAX_PATH, buf, nullptr);
  if (len == 0 || len > MAX_PATH) return "";
  // Normalize backslashes to forward slashes for consistency
  std::string result(buf, len);
  for (auto& c : result) if (c == '\\') c = '/';
  // Remove trailing slash
  while (result.size() > 1 && result.back() == '/') result.pop_back();
  return result;
}

static bool path_exists(const std::string& path) {
  DWORD attr = GetFileAttributesA(path.c_str());
  return attr != INVALID_FILE_ATTRIBUTES;
}

static bool is_dir(const std::string& path) {
  DWORD attr = GetFileAttributesA(path.c_str());
  return attr != INVALID_FILE_ATTRIBUTES && (attr & FILE_ATTRIBUTE_DIRECTORY);
}

#else

static std::string canonical(const std::string& path) {
  char buf[PATH_MAX];
  if (!realpath(path.c_str(), buf)) return "";
  std::string result(buf);
  while (result.size() > 1 && result.back() == '/') result.pop_back();
  return result;
}

static bool path_exists(const std::string& path) {
  struct stat st;
  return stat(path.c_str(), &st) == 0;
}

static bool is_dir(const std::string& path) {
  struct stat st;
  return stat(path.c_str(), &st) == 0 && S_ISDIR(st.st_mode);
}

#endif

// ---------------------------------------------------------------------------
// Workspace
// ---------------------------------------------------------------------------

std::string set_workspace(const std::string& path) {
  LOG_TRACE("tools::set_workspace entry: " + path);
  if (path.empty()) {
    g_workspace.clear();
    return "Workspace path is empty";
  }
  std::string canon = canonical(path);
  if (canon.empty()) {
    g_workspace.clear();
    return "Invalid workspace path: " + path;
  }
  if (!is_dir(canon)) {
    g_workspace.clear();
    return "Workspace is not a directory: " + path;
  }
  g_workspace = canon;
  LOG_INFO("Workspace set to: " + g_workspace);
  return ""; // success
}

const std::string& workspace() {
  return g_workspace;
}

// ---------------------------------------------------------------------------
// Path resolution & sandboxing
// ---------------------------------------------------------------------------

std::string resolve(const std::string& path) {
  if (path.empty()) return "";
  std::string resolved;
  if (
#ifdef _WIN32
      path.size() >= 2 && path[1] == ':'
#else
      !path.empty() && path[0] == '/'
#endif
  ) {
    // Absolute path
    resolved = canonical(path);
  } else {
    // Relative to workspace
    if (g_workspace.empty()) return "";
    resolved = canonical(g_workspace + "/" + path);
  }
  return resolved;
}

bool is_within_workspace(const std::string& resolved) {
  if (g_workspace.empty()) return true; // no workspace set = allow all
  if (resolved.empty()) return false;

  // Workspace boundary: resolved path must start with workspace path
  // followed by either end-of-string or a path separator
  if (resolved.size() < g_workspace.size()) return false;
  if (resolved.compare(0, g_workspace.size(), g_workspace) != 0) return false;
  if (resolved.size() == g_workspace.size()) return true;
  return resolved[g_workspace.size()] == '/';
}

// ---------------------------------------------------------------------------
// JSON helpers (lightweight string-level escape — nlohmann used for parsing/construction)
// ---------------------------------------------------------------------------

std::string json_escape(const std::string& s) {
  std::string out;
  out.reserve(s.size() + 16);
  for (char c : s) {
    switch (c) {
      case '"':  out += "\\\""; break;
      case '\\': out += "\\\\"; break;
      case '\n': out += "\\n";  break;
      case '\r': out += "\\r";  break;
      case '\t': out += "\\t";  break;
      default:
        if (static_cast<unsigned char>(c) < 0x20) {
          // Escape control characters as \u00XX (RFC 7159)
          char buf[8];
          snprintf(buf, sizeof(buf), "\\u%04x", static_cast<unsigned char>(c));
          out += buf;
        } else {
          out += c;
        }
    }
  }
  return out;
}

static std::string ok_result(const std::string& content) {
  return "{\"ok\":true,\"content\":\"" + json_escape(content) + "\"}";
}

static std::string error_result(const std::string& msg) {
  return "{\"ok\":false,\"error\":\"" + json_escape(msg) + "\"}";
}

// ---------------------------------------------------------------------------
// Binary detection
// ---------------------------------------------------------------------------

static bool is_binary(const std::string& path) {
  std::ifstream f(path, std::ios::binary);
  if (!f) return false;
  char buf[8192];
  f.read(buf, sizeof(buf));
  auto n = f.gcount();
  if (n == 0) return false;
  // Check for null bytes — strong binary indicator
  for (std::streamsize i = 0; i < n; ++i) {
    if (buf[i] == '\0') return true;
  }
  // Check for high proportion of non-printable characters (excluding whitespace)
  int non_printable = 0;
  for (std::streamsize i = 0; i < n; ++i) {
    unsigned char c = static_cast<unsigned char>(buf[i]);
    if (c < 0x20 && c != '\n' && c != '\r' && c != '\t') non_printable++;
  }
  return non_printable > n * 0.30;
}

// ---------------------------------------------------------------------------
// check_path — common validation: resolve and sandbox only.
// Callers must perform their own existence and is-file/is-dir checks.
// ---------------------------------------------------------------------------

static std::string check_path(const std::string& path, std::string& resolved) {
  resolved = resolve(path);
  if (resolved.empty()) {
    if (g_workspace.empty()) return "No workspace set";
    return "Cannot resolve path: " + path;
  }
  if (!is_within_workspace(resolved)) {
    return "Access denied: path outside workspace";
  }
  return ""; // success — resolved is set
}

// ---------------------------------------------------------------------------
// read_file (enhanced: line numbers + offset/limit + 2000-line cap)
// ---------------------------------------------------------------------------

std::string read_file(const std::string& request_json) {
  LOG_TRACE("tools::read_file entry");

  // Parse request JSON
  std::string path;
  int offset = 1;
  int limit = 2000;

  try {
    // Support both plain path string and JSON object for backward compat
    if (!request_json.empty() && request_json[0] == '{') {
      auto req = json::parse(request_json);
      path = req.value("path", "");
      if (req.contains("offset")) {
        if (req["offset"].is_number()) offset = req["offset"].get<int>();
      }
      if (req.contains("limit")) {
        if (req["limit"].is_number()) limit = req["limit"].get<int>();
      }
    } else {
      // Plain path string (backward compat)
      path = request_json;
    }
  } catch (const json::parse_error&) {
    // If JSON parsing fails, treat as plain path
    path = request_json;
  }

  // Validate offset
  if (offset <= 0) {
    return error_result("offset must be >= 1");
  }
  if (limit <= 0) {
    return error_result("limit must be >= 1");
  }

  // Resolve and sandbox
  std::string resolved;
  std::string err = check_path(path, resolved);
  if (!err.empty()) return error_result(err);

  // Check existence
  if (!path_exists(resolved)) {
    return error_result("File not found: " + path);
  }

  // Check is file (not directory)
  if (is_dir(resolved)) {
    return error_result("Path is a directory, not a file: " + path);
  }

  // Binary check
  if (is_binary(resolved)) {
    return error_result("Cannot read binary file");
  }

  // Check file size (10 MB limit, same as CURLOPT_MAXFILESIZE)
  {
    std::ifstream fs(resolved, std::ios::binary | std::ios::ate);
    if (fs) {
      auto sz = fs.tellg();
      if (sz > 10 * 1024 * 1024) {
        return error_result("File too large for read_file (>10MB). Use offset/limit or a text editor.");
      }
    }
  }

  // Read content
  std::ifstream f(resolved, std::ios::binary);
  if (!f) {
    return error_result("Cannot open file: " + path);
  }
  std::ostringstream ss;
  ss << f.rdbuf();
  std::string content = ss.str();

  // Split into lines
  std::vector<std::string> lines;
  std::string line;
  for (size_t i = 0; i < content.size(); ++i) {
    if (content[i] == '\n') {
      lines.push_back(line);
      line.clear();
    } else if (content[i] == '\r') {
      // Handle CRLF: skip \r, the \n will be processed next
      if (i + 1 < content.size() && content[i + 1] == '\n') {
        lines.push_back(line);
        line.clear();
        ++i; // skip the \n
      } else {
        // Bare \r
        lines.push_back(line);
        line.clear();
      }
    } else {
      line += content[i];
    }
  }
  // Don't add a trailing empty line for files ending with \n
  if (!line.empty() || (!content.empty() && content.back() != '\n' && content.back() != '\r')) {
    lines.push_back(line);
  }

  int total_lines = static_cast<int>(lines.size());

  // Empty file: return empty content without misleading notice
  if (total_lines == 0) {
    json resp;
    resp["ok"] = true;
    resp["content"] = "";
    resp["total_lines"] = 0;
    resp["start_line"] = 0;
    resp["end_line"] = 0;
    LOG_INFO("read_file: " + resolved + " (empty file)");
    return resp.dump();
  }

  // Validate offset range
  if (offset > total_lines) {
    json resp;
    resp["ok"] = true;
    resp["content"] = "";
    resp["total_lines"] = total_lines;
    resp["start_line"] = 0;
    resp["end_line"] = 0;
    resp["notice"] = "offset exceeds file length (" + std::to_string(total_lines) + " lines)";
    return resp.dump();
  }

  // Sanity bound: cap limit to prevent integer overflow with extreme offset+limit
  if (limit > 100000) limit = 100000;

  // Calculate range
  int start = offset - 1; // 0-indexed
  int end = std::min(start + limit, total_lines);

  // Build output with line numbers (cat -n format)
  // Format: 6-char right-aligned line number + tab + line content
  std::ostringstream out;
  for (int i = start; i < end; ++i) {
    char num_buf[8];
    snprintf(num_buf, sizeof(num_buf), "%6d\t", i + 1);
    out << num_buf << lines[i] << '\n';
  }

  std::string result_content = out.str();
  bool truncated = (total_lines > 2000 && offset == 1 && limit == 2000);

  json resp;
  resp["ok"] = true;
  resp["content"] = result_content;
  resp["total_lines"] = total_lines;
  resp["start_line"] = offset;
  resp["end_line"] = end;

  if (truncated) {
    resp["truncated"] = true;
    std::ostringstream notice;
    notice << "File has " << total_lines << " lines, showing 1-2000. "
           << "Use offset/limit to read more.";
    resp["notice"] = notice.str();
  }

  LOG_INFO("read_file: " + resolved + " (" + std::to_string(content.size()) + " bytes, lines " + std::to_string(offset) + "-" + std::to_string(end) + ")");
  return resp.dump();
}

// ---------------------------------------------------------------------------
// write_file
// ---------------------------------------------------------------------------

std::string write_file(const std::string& request_json) {
  LOG_TRACE("tools::write_file entry");

  std::string path;
  std::string content;
  try {
    auto req = json::parse(request_json);
    path = req.value("path", "");
    content = req.value("content", "");
  } catch (const json::parse_error& e) {
    return error_result("Invalid request JSON: " + std::string(e.what()));
  }

  if (path.empty()) {
    return error_result("path is required");
  }

  // Resolve and sandbox
  std::string resolved;
  std::string err = check_path(path, resolved);
  if (!err.empty()) return error_result(err);

  // If resolved path is a directory, reject
  if (path_exists(resolved) && is_dir(resolved)) {
    return error_result("Path is a directory, not a file: " + path);
  }

  bool created = !path_exists(resolved);

  // Create parent directories if needed
  {
    size_t last_slash = resolved.rfind('/');
    if (last_slash != std::string::npos) {
      std::string parent = resolved.substr(0, last_slash);
      // Recursively create parent dirs
      std::string current;
      for (size_t i = 0; i < parent.size(); ++i) {
        current += parent[i];
        if (parent[i] == '/' || i == parent.size() - 1) {
          if (!current.empty() && current.back() == '/')
            current.pop_back();
          if (!current.empty()) {
#ifdef _WIN32
            if (current.size() == 2 && current[1] == ':') {
              if (i < parent.size()) current += '/';
              continue;
            }
#endif
            mkdir_impl(current.c_str());
          }
          if (i < parent.size()) current += '/';
        }
      }
    }
  }

  // Write file
  {
    std::ofstream f(resolved, std::ios::binary | std::ios::trunc);
    if (!f) {
      return error_result("Cannot write file: " + path);
    }
    f.write(content.data(), content.size());
    if (!f) {
      return error_result("Write failed (disk full?): " + path);
    }
    f.close();
  }

  json resp;
  resp["ok"] = true;
  resp["path"] = resolved;
  resp["bytes_written"] = static_cast<int>(content.size());
  resp["created"] = created;

  LOG_INFO("write_file: " + resolved + " (" + std::to_string(content.size()) + " bytes, created=" + (created ? "true" : "false") + ")");
  return resp.dump();
}

// ---------------------------------------------------------------------------
// File metadata detection
// ---------------------------------------------------------------------------

struct FileMeta {
  std::string indent_style = "spaces"; // "tabs" or "spaces"
  int indent_width = 4;
  std::string line_ending = "LF"; // "LF" or "CRLF"
};

static FileMeta detect_file_meta(const std::string& content) {
  FileMeta meta;

  // Detect line ending
  size_t crlf_count = 0;
  size_t lf_count = 0;
  for (size_t i = 0; i < content.size(); ++i) {
    if (content[i] == '\r' && i + 1 < content.size() && content[i + 1] == '\n') {
      crlf_count++;
      i++;
    } else if (content[i] == '\n') {
      lf_count++;
    }
  }
  if (crlf_count > lf_count) {
    meta.line_ending = "CRLF";
  }

  // Detect indent style (scan first 50 lines)
  int tab_lines = 0;
  int space_lines = 0;
  std::vector<int> space_widths;
  int lines_scanned = 0;

  std::istringstream stream(content);
  std::string line;
  while (std::getline(stream, line) && lines_scanned < 50) {
    lines_scanned++;
    if (line.empty()) continue;
    if (line[0] == '\t') {
      tab_lines++;
    } else if (line[0] == ' ') {
      space_lines++;
      // Count leading spaces
      int count = 0;
      while (count < static_cast<int>(line.size()) && line[count] == ' ') count++;
      if (count > 0 && count <= 8) space_widths.push_back(count);
    }
  }

  if (tab_lines > space_lines) {
    meta.indent_style = "tabs";
    meta.indent_width = 1;
  } else if (!space_widths.empty()) {
    meta.indent_style = "spaces";
    // Find most common indent width
    std::sort(space_widths.begin(), space_widths.end());
    int best_width = 4;
    int best_count = 0;
    // Check common widths: 2, 4, 8
    for (int w : {2, 4, 8}) {
      int c = static_cast<int>(std::count(space_widths.begin(), space_widths.end(), w));
      if (c > best_count) {
        best_count = c;
        best_width = w;
      }
    }
    meta.indent_width = best_width;
  }

  return meta;
}

// ---------------------------------------------------------------------------
// Whitespace normalization
// ---------------------------------------------------------------------------

static std::string normalize_whitespace(const std::string& text, const FileMeta& meta) {
  std::string result;
  result.reserve(text.size());

  for (size_t i = 0; i < text.size(); ++i) {
    char c = text[i];
    // CRLF → LF
    if (c == '\r' && i + 1 < text.size() && text[i + 1] == '\n') {
      result += '\n';
      i++;
      continue;
    }
    // Bare CR → LF
    if (c == '\r') {
      result += '\n';
      continue;
    }
    // Tab → spaces (using detected indent width)
    if (c == '\t' && meta.indent_style == "spaces") {
      result.append(meta.indent_width, ' ');
      continue;
    }
    result += c;
  }

  // Strip trailing whitespace from each line
  std::string stripped;
  std::istringstream stream(result);
  std::string line;
  bool first = true;
  while (std::getline(stream, line)) {
    if (!first) stripped += '\n';
    first = false;
    // Remove trailing whitespace
    while (!line.empty() && (line.back() == ' ' || line.back() == '\t')) {
      line.pop_back();
    }
    stripped += line;
  }
  // Handle trailing newline in original
  if (!result.empty() && result.back() == '\n') {
    stripped += '\n';
  }

  return stripped;
}

// ---------------------------------------------------------------------------
// Levenshtein distance
// ---------------------------------------------------------------------------

static int levenshtein_distance(const std::string& a, const std::string& b) {
  size_t m = a.size();
  size_t n = b.size();
  if (m == 0) return static_cast<int>(n);
  if (n == 0) return static_cast<int>(m);

  std::vector<int> prev(n + 1);
  std::vector<int> curr(n + 1);

  for (size_t j = 0; j <= n; ++j) prev[j] = static_cast<int>(j);

  for (size_t i = 0; i < m; ++i) {
    curr[0] = static_cast<int>(i) + 1;
    for (size_t j = 0; j < n; ++j) {
      int cost = (a[i] == b[j]) ? 0 : 1;
      curr[j + 1] = std::min({
        curr[j] + 1,        // insertion
        prev[j + 1] + 1,    // deletion
        prev[j] + cost      // substitution
      });
    }
    prev.swap(curr);
  }

  return prev[n];
}

// ---------------------------------------------------------------------------
// Diagnostic match — sliding window Levenshtein to find closest match
// ---------------------------------------------------------------------------

static json diagnostic_match(const std::string& content, const std::string& old_text,
                              const FileMeta& meta) {
  // Build line list for the content
  std::vector<std::pair<int, std::string>> content_lines; // (line_number, text)
  std::istringstream stream(content);
  std::string line;
  int line_num = 1;
  while (std::getline(stream, line)) {
    content_lines.push_back({line_num++, line});
  }

  // Normalize old_text for comparison
  std::string norm_old = normalize_whitespace(old_text, meta);

  // Scan through content with a sliding window (±5 lines around each line)
  int best_line = 0;
  std::string best_text;
  int best_dist = INT_MAX;

  for (const auto& [ln, text] : content_lines) {
    std::string norm_text = normalize_whitespace(text, meta);
    int dist = levenshtein_distance(norm_text, norm_old);
    if (dist < best_dist) {
      best_dist = dist;
      best_line = ln;
      best_text = text;
    }
  }

  // Generate difference list
  std::vector<std::string> differences;
  if (meta.indent_style == "tabs") {
    // Check if old_text uses spaces instead of tabs
    if (old_text.find("  ") != std::string::npos) {
      differences.push_back("indentation: file uses tabs, you used spaces");
    }
  } else {
    // Check indentation width
    int old_indent = 0;
    for (char c : old_text) {
      if (c == ' ') old_indent++;
      else if (c == '\t') { old_indent += meta.indent_width; }
      else break;
    }
    if (old_indent > 0 && old_indent != meta.indent_width) {
      differences.push_back("indentation: file uses " + std::to_string(meta.indent_width) +
                            " spaces, you used " + std::to_string(old_indent));
    }
  }

  if (meta.line_ending == "CRLF" && old_text.find("\r\n") == std::string::npos) {
    differences.push_back("line ending: file uses CRLF, you used LF");
  } else if (meta.line_ending == "LF" && old_text.find("\r\n") != std::string::npos) {
    differences.push_back("line ending: file uses LF, you used CRLF");
  }

  json diagnosis;
  diagnosis["file_indent"] = meta.indent_style == "tabs" ? "tabs" : (std::to_string(meta.indent_width) + " spaces");
  diagnosis["file_line_ending"] = meta.line_ending;

  json closest;
  closest["line"] = best_line;
  closest["actual_text"] = best_text;
  closest["your_text"] = old_text;

  if (!differences.empty()) {
    closest["differences"] = differences;
  }

  diagnosis["closest_match"] = closest;
  return diagnosis;
}

// ---------------------------------------------------------------------------
// edit_file — three-tier matching
// ---------------------------------------------------------------------------

std::string edit_file(const std::string& request_json) {
  LOG_TRACE("tools::edit_file entry");

  std::string path;
  std::string old_text;
  std::string new_text;
  bool replace_all = false;

  try {
    auto req = json::parse(request_json);
    path = req.value("path", "");
    old_text = req.value("old_text", "");
    new_text = req.value("new_text", "");
    replace_all = req.value("replace_all", false);
  } catch (const json::parse_error& e) {
    return error_result("Invalid request JSON: " + std::string(e.what()));
  }

  if (path.empty()) return error_result("path is required");

  // ---- Empty old_text guard (D2) ----
  if (old_text.empty()) {
    return error_result("old_text must not be empty");
  }

  // ---- Resolve and sandbox ----
  std::string resolved;
  std::string err = check_path(path, resolved);
  if (!err.empty()) return error_result(err);

  // Check existence
  if (!path_exists(resolved)) {
    return error_result("File not found: " + path);
  }
  if (is_dir(resolved)) {
    return error_result("Path is a directory, not a file: " + path);
  }

  // ---- Non-text / large file protection (1.7) ----
  // Check file size (1MB limit)
  {
    std::ifstream fs(resolved, std::ios::binary | std::ios::ate);
    if (fs) {
      auto sz = fs.tellg();
      if (sz > 1024 * 1024) {
        return error_result("File too large for edit_file (>1MB)");
      }
    }
  }

  // Check binary (NUL in first 512 bytes)
  {
    std::ifstream fs(resolved, std::ios::binary);
    if (fs) {
      char buf[512] = {};
      fs.read(buf, sizeof(buf));
      auto n = fs.gcount();
      for (std::streamsize i = 0; i < n; ++i) {
        if (buf[i] == '\0') {
          return error_result("Cannot edit binary or non-text file");
        }
      }
    }
  }

  // ---- Read file content ----
  std::ifstream f(resolved, std::ios::binary);
  if (!f) {
    return error_result("Cannot open file: " + path);
  }
  std::ostringstream ss;
  ss << f.rdbuf();
  std::string content = ss.str();
  f.close();

  // ---- Detect file metadata (1.3) ----
  FileMeta meta = detect_file_meta(content);

  // ---- Tier 1: Exact match ----
  {
    std::vector<size_t> positions;
    size_t pos = 0;
    while ((pos = content.find(old_text, pos)) != std::string::npos) {
      positions.push_back(pos);
      pos += old_text.size();
    }

    if (!positions.empty()) {
      if (positions.size() > 1 && !replace_all) {
        // Multiple matches — reject with line numbers
        std::vector<int> match_lines;
        for (size_t p : positions) {
          int line_num = 1;
          for (size_t i = 0; i < p && i < content.size(); ++i) {
            if (content[i] == '\n') line_num++;
          }
          match_lines.push_back(line_num);
        }
        json resp;
        resp["ok"] = false;
        resp["error"] = "old_text matches " + std::to_string(positions.size()) + " locations";
        resp["matches"] = match_lines;
        resp["hint"] = "Use replace_all:true to replace all, or provide more context to make old_text unique";
        return resp.dump();
      }

      // Single match or replace_all — perform replacement
      int replacements = 0;
      std::string result;
      if (replace_all) {
        size_t last = 0;
        while ((pos = content.find(old_text, last)) != std::string::npos) {
          result.append(content, last, pos - last);
          result.append(new_text);
          last = pos + old_text.size();
          replacements++;
        }
        result.append(content, last, content.size() - last);
      } else {
        pos = positions[0];
        result = content.substr(0, pos) + new_text + content.substr(pos + old_text.size());
        replacements = 1;
      }

      // Write back
      {
        std::ofstream out(resolved, std::ios::binary | std::ios::trunc);
        if (!out) return error_result("Cannot write file: " + path);
        out.write(result.data(), result.size());
      }

      LOG_INFO("edit_file: " + resolved + " exact match, " + std::to_string(replacements) + " replacements");
      json resp;
      resp["ok"] = true;
      resp["replacements"] = replacements;
      return resp.dump();
    }
  }

  // ---- Tier 2: Whitespace-normalized match (1.5) ----
  {
    std::string norm_content = normalize_whitespace(content, meta);
    std::string norm_old = normalize_whitespace(old_text, meta);

    std::vector<size_t> norm_positions;
    size_t pos = 0;
    while ((pos = norm_content.find(norm_old, pos)) != std::string::npos) {
      norm_positions.push_back(pos);
      pos += norm_old.size();
    }

    if (!norm_positions.empty()) {
      if (norm_positions.size() > 1 && !replace_all) {
        // Multiple normalized matches — reject with line numbers
        std::vector<int> match_lines;
        for (size_t np : norm_positions) {
          int line_num = 1;
          for (size_t i = 0; i < np && i < norm_content.size(); ++i) {
            if (norm_content[i] == '\n') line_num++;
          }
          match_lines.push_back(line_num);
        }
        json resp;
        resp["ok"] = false;
        resp["error"] = "old_text matches " + std::to_string(norm_positions.size()) + " locations (with whitespace normalization)";
        resp["matches"] = match_lines;
        resp["hint"] = "Use replace_all:true to replace all, or provide more context to make old_text unique";
        resp["matched_with"] = "whitespace normalization";
        return resp.dump();
      }

      // Map normalized positions back to original content by simulating
      // normalization and tracking both positions simultaneously.
      auto map_norm_to_orig = [&](size_t target_norm_pos) -> size_t {
        size_t oi = 0, ni = 0;
        while (oi < content.size() && ni < target_norm_pos) {
          char c = content[oi];
          if (c == '\r' && oi + 1 < content.size() && content[oi + 1] == '\n') {
            oi += 2; ni += 1;           // CRLF → LF
          } else if (c == '\r') {
            oi += 1; ni += 1;           // bare CR → LF
          } else if (c == ' ' || c == '\t') {
            // Trailing whitespace check MUST come before tab→spaces expansion:
            // peek ahead to see if this space/tab block is followed by newline
            // or EOF, which means normalize_whitespace would strip it entirely.
            size_t peek = oi;
            while (peek < content.size() &&
                   (content[peek] == ' ' || content[peek] == '\t')) {
              peek++;
            }
            if (peek >= content.size() || content[peek] == '\n' ||
                (content[peek] == '\r' && peek + 1 < content.size() && content[peek + 1] == '\n')) {
              // Trailing whitespace — stripped in normalized form
              oi = peek; // skip all trailing whitespace, no ni advance
              if (peek < content.size() && content[peek] == '\r') { oi += 2; ni += 1; }
              else if (peek < content.size()) { oi += 1; ni += 1; }
            } else if (c == '\t' && meta.indent_style == "spaces") {
              oi += 1; ni += meta.indent_width; // non-trailing tab → N spaces
            } else {
              oi += 1; ni += 1;
            }
          } else {
            oi += 1; ni += 1;
          }
        }
        return oi;
      };

      // Build replacement ranges in original content (mapped from normalized matches)
      struct Range { size_t start; size_t end; };
      std::vector<Range> ranges;
      for (size_t np : norm_positions) {
        ranges.push_back({map_norm_to_orig(np), map_norm_to_orig(np + norm_old.size())});
      }

      // Deduplicate overlapping ranges (can happen with whitespace stripping)
      std::vector<Range> merged;
      for (auto& r : ranges) {
        if (!merged.empty() && r.start <= merged.back().end) {
          merged.back().end = std::max(merged.back().end, r.end);
        } else {
          merged.push_back(r);
        }
      }

      if (!replace_all) {
        // Single replacement
        auto& r = merged[0];
        if (r.start == 0 && r.end == 0) {
          // Mapping failed entirely — fall back to exact-match failure path
          // (shouldn't normally happen, but don't corrupt the file)
        } else {
          std::string result = content.substr(0, r.start) + new_text + content.substr(r.end);
          {
            std::ofstream out(resolved, std::ios::binary | std::ios::trunc);
            if (!out) return error_result("Cannot write file: " + path);
            out.write(result.data(), result.size());
          }

          LOG_INFO("edit_file: " + resolved + " normalized match, 1 replacement");
          json resp;
          resp["ok"] = true;
          resp["replacements"] = 1;
          resp["matched_with"] = "whitespace normalization";
          return resp.dump();
        }
      } else {
        // replace_all: apply replacements right-to-left to preserve positions
        std::string result = content;
        for (int i = static_cast<int>(merged.size()) - 1; i >= 0; --i) {
          auto& r = merged[i];
          result.replace(r.start, r.end - r.start, new_text);
        }

        {
          std::ofstream out(resolved, std::ios::binary | std::ios::trunc);
          if (!out) return error_result("Cannot write file: " + path);
          out.write(result.data(), result.size());
        }

        LOG_INFO("edit_file: " + resolved + " normalized match, " +
                 std::to_string(merged.size()) + " replacements (replace_all)");
        json resp;
        resp["ok"] = true;
        resp["replacements"] = static_cast<int>(merged.size());
        resp["matched_with"] = "whitespace normalization";
        return resp.dump();
      }
    }
  }

  // ---- Tier 3: Diagnostic error (1.6) ----
  {
    json diagnosis = diagnostic_match(content, old_text, meta);

    json resp;
    resp["ok"] = false;
    resp["error"] = "old_text not found in file";
    resp["diagnosis"] = diagnosis;
    return resp.dump();
  }
}

// ---------------------------------------------------------------------------
// list_dir
// ---------------------------------------------------------------------------

std::string list_dir(const std::string& path) {
  LOG_TRACE("tools::list_dir entry: " + path);
  // Resolve and sandbox
  std::string resolved;
  std::string err = check_path(path, resolved);
  if (!err.empty()) return error_result(err);

  // Check existence
  if (!path_exists(resolved)) {
    return error_result("Directory not found: " + path);
  }

  // Check is directory
  if (!is_dir(resolved)) {
    return error_result("Not a directory: " + path);
  }

  // Enumerate
  std::ostringstream entries;

#ifdef _WIN32
  std::string search_path = resolved + "\\*";
  WIN32_FIND_DATAA fd;
  HANDLE h = FindFirstFileA(search_path.c_str(), &fd);
  if (h == INVALID_HANDLE_VALUE) {
    return error_result("Cannot read directory: " + path);
  }
  bool first = true;
  do {
    if (std::strcmp(fd.cFileName, ".") == 0 || std::strcmp(fd.cFileName, "..") == 0) continue;
    if (!first) entries << ",";
    first = false;
    entries << "{\"name\":\"" << json_escape(fd.cFileName) << "\",\"type\":\""
            << ((fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) ? "directory" : "file")
            << "\"}";
  } while (FindNextFileA(h, &fd));
  FindClose(h);
#else
  DIR* d = opendir(resolved.c_str());
  if (!d) {
    return error_result("Cannot read directory: " + path);
  }
  bool first = true;
  struct dirent* entry;
  while ((entry = readdir(d)) != nullptr) {
    if (std::strcmp(entry->d_name, ".") == 0 || std::strcmp(entry->d_name, "..") == 0) continue;
    if (!first) entries << ",";
    first = false;
    std::string full_path = resolved + "/" + entry->d_name;
    entries << "{\"name\":\"" << json_escape(entry->d_name) << "\",\"type\":\""
            << (is_dir(full_path) ? "directory" : "file")
            << "\"}";
  }
  closedir(d);
#endif

  std::string entries_json = "[" + entries.str() + "]";
  std::string result = ok_result(entries_json);
  LOG_INFO("list_dir: " + resolved + " (" + result + ")");
  return result;
}

} // namespace tools
