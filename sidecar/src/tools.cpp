#include "tools.h"
#include "logger.h"
#include "subprocess.h"

#include <string>
#include <vector>
#include <fstream>
#include <sstream>
#include <algorithm>
#include <cstring>
#include <cctype>
#include <nlohmann/json.hpp>

#ifdef _WIN32
#include <windows.h>
#include <direct.h>
#define mkdir_impl(p) _mkdir(p)
#else
#include <limits.h>
#include <stdlib.h>
#include <unistd.h>
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
// edit_file batch — per-pair resolution & helpers
// ---------------------------------------------------------------------------

struct EditPair {
  std::string old_text;
  std::string new_text;
  bool replace_all = false;
};

enum class MatchTier { None, Exact, Normalized };

struct HitRange {
  size_t start;
  size_t end;
};

/// Line number (1-based) of a byte offset within content.
static int line_of(const std::string& content, size_t offset) {
  int line = 1;
  for (size_t i = 0; i < offset && i < content.size(); ++i) {
    if (content[i] == '\n') line++;
  }
  return line;
}

/// Resolve `old_text` against `content`, returning hit ranges in ORIGINAL byte
/// coordinates. Exact matches are used when present; otherwise whitespace
/// normalization is tried. Returns the tier that matched (None if neither).
/// Empty `old_text` is guaranteed rejected by the caller before this runs.
static MatchTier resolve_edit_hits(const std::string& content,
                                   const std::string& old_text,
                                   const FileMeta& meta,
                                   std::vector<HitRange>& ranges) {
  ranges.clear();

  // ---- Tier 1: Exact match ----
  std::vector<size_t> positions;
  size_t pos = 0;
  while ((pos = content.find(old_text, pos)) != std::string::npos) {
    positions.push_back(pos);
    pos += old_text.size();
  }
  if (!positions.empty()) {
    for (size_t p : positions) ranges.push_back({p, p + old_text.size()});
    return MatchTier::Exact;
  }

  // ---- Tier 2: Whitespace-normalized match ----
  std::string norm_content = normalize_whitespace(content, meta);
  std::string norm_old = normalize_whitespace(old_text, meta);
  if (norm_old.empty()) return MatchTier::None;

  std::vector<size_t> norm_positions;
  pos = 0;
  while ((pos = norm_content.find(norm_old, pos)) != std::string::npos) {
    norm_positions.push_back(pos);
    pos += norm_old.size();
  }
  if (norm_positions.empty()) return MatchTier::None;

  // Map normalized positions back to original content coordinates by
  // simulating normalization and tracking both positions simultaneously.
  auto map_norm_to_orig = [&](size_t target_norm_pos) -> size_t {
    size_t oi = 0, ni = 0;
    while (oi < content.size() && ni < target_norm_pos) {
      char c = content[oi];
      if (c == '\r' && oi + 1 < content.size() && content[oi + 1] == '\n') {
        oi += 2; ni += 1;           // CRLF → LF
      } else if (c == '\r') {
        oi += 1; ni += 1;           // bare CR → LF
      } else if (c == ' ' || c == '\t') {
        // Trailing-whitespace check MUST come before tab→spaces expansion:
        // peek ahead to see if this space/tab block is followed by a line
        // boundary or EOF, which means normalize_whitespace would strip it
        // entirely. A bare \r counts as a boundary too: normalize_whitespace
        // converts bare \r to \n FIRST and then strips trailing whitespace.
        size_t peek = oi;
        while (peek < content.size() &&
               (content[peek] == ' ' || content[peek] == '\t')) {
          peek++;
        }
        if (peek >= content.size() || content[peek] == '\n' ||
            content[peek] == '\r') {
          oi = peek; // skip all trailing whitespace, no ni advance
          if (peek < content.size() && content[peek] == '\r') {
            if (peek + 1 < content.size() && content[peek + 1] == '\n') {
              oi += 2; ni += 1;  // CRLF → \n
            } else {
              oi += 1; ni += 1;  // bare \r → \n
            }
          } else if (peek < content.size()) {
            oi += 1; ni += 1;    // \n
          }
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

  for (size_t np : norm_positions) {
    size_t s = map_norm_to_orig(np);
    size_t e = map_norm_to_orig(np + norm_old.size());
    if (e > s) ranges.push_back({s, e});
  }

  // Merge overlapping ranges (can happen with whitespace stripping).
  if (ranges.size() > 1) {
    std::sort(ranges.begin(), ranges.end(),
              [](const HitRange& a, const HitRange& b) { return a.start < b.start; });
    std::vector<HitRange> merged;
    for (const auto& r : ranges) {
      if (!merged.empty() && r.start <= merged.back().end) {
        merged.back().end = std::max(merged.back().end, r.end);
      } else {
        merged.push_back(r);
      }
    }
    ranges = std::move(merged);
  }
  return MatchTier::Normalized;
}

// ---------------------------------------------------------------------------
// edit_file — batch edits array, three-tier matching
// ---------------------------------------------------------------------------

std::string edit_file(const std::string& request_json) {
  LOG_TRACE("tools::edit_file entry");

  std::string path;
  std::vector<EditPair> pairs;

  try {
    auto req = json::parse(request_json);
    path = req.value("path", "");
    if (!req.contains("edits") || !req["edits"].is_array() || req["edits"].empty()) {
      return error_result("edits must contain at least one replacement");
    }
    const auto& edits = req["edits"];
    constexpr int kMaxEdits = 100;
    if (edits.size() > kMaxEdits) {
      json resp;
      resp["ok"] = false;
      resp["error"] = "too many edits (max " + std::to_string(kMaxEdits) + ")";
      return resp.dump();
    }
    for (const auto& e : edits) {
      if (!e.is_object()) {
        return error_result("edits entries must be objects");
      }
      EditPair p;
      p.old_text = e.value("old_text", "");
      p.new_text = e.value("new_text", "");
      p.replace_all = e.value("replace_all", false);
      pairs.push_back(std::move(p));
    }
  } catch (const json::parse_error& e) {
    return error_result("Invalid request JSON: " + std::string(e.what()));
  }

  if (path.empty()) return error_result("path is required");

  // ---- Per-pair structural validation: empty old_text → immediate reject ----
  // (prevents find() empty-string infinite loop; each hit advances by
  // old_text.size(), which is 0 for an empty old_text)
  for (size_t i = 0; i < pairs.size(); ++i) {
    if (pairs[i].old_text.empty()) {
      json resp;
      resp["ok"] = false;
      resp["error"] = "old_text must not be empty";
      resp["pair"] = i;
      return resp.dump();
    }
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

  // ---- Non-text / large file protection (whole request level) ----
  {
    std::ifstream fs(resolved, std::ios::binary | std::ios::ate);
    if (fs) {
      auto sz = fs.tellg();
      if (sz > 1024 * 1024) {
        return error_result("File too large for edit_file (>1MB)");
      }
    }
  }

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

  // ---- Detect file metadata ----
  FileMeta meta = detect_file_meta(content);

  // ---- Validation phase: resolve every pair against ORIGINAL content ----
  struct AppliedHit {
    size_t start;
    size_t end;
    size_t pair;
  };

  std::vector<HitRange> ranges;
  std::vector<AppliedHit> hits;
  bool any_normalized = false;

  for (size_t i = 0; i < pairs.size(); ++i) {
    const EditPair& p = pairs[i];
    MatchTier tier = resolve_edit_hits(content, p.old_text, meta, ranges);
    if (tier == MatchTier::None) {
      // Tier 3: diagnostic error identifying the failing pair
      json diagnosis = diagnostic_match(content, p.old_text, meta);
      json resp;
      resp["ok"] = false;
      resp["error"] = "old_text not found in file";
      resp["pair"] = i;
      resp["diagnosis"] = diagnosis;
      return resp.dump();
    }
    if (tier == MatchTier::Normalized) {
      any_normalized = true;
    }
    if (!p.replace_all && ranges.size() > 1) {
      // Multiple matches — reject with line numbers
      std::vector<int> match_lines;
      for (const auto& r : ranges) {
        match_lines.push_back(line_of(content, r.start));
      }
      json resp;
      resp["ok"] = false;
      resp["error"] = "old_text matches " + std::to_string(ranges.size()) + " locations";
      resp["pair"] = i;
      resp["matches"] = match_lines;
      resp["hint"] = "Use replace_all:true to replace all, or provide more context to make old_text unique";
      if (tier == MatchTier::Normalized) {
        resp["matched_with"] = "whitespace normalization";
      }
      return resp.dump();
    }
    size_t n = p.replace_all ? ranges.size() : 1;
    for (size_t k = 0; k < n; ++k) {
      hits.push_back({ranges[k].start, ranges[k].end, i});
    }
  }

  // ---- Overlap detection: different pairs' hit ranges must not overlap ----
  if (hits.size() > 1) {
    std::vector<AppliedHit> sorted = hits;
    std::sort(sorted.begin(), sorted.end(),
              [](const AppliedHit& a, const AppliedHit& b) {
                if (a.start != b.start) return a.start < b.start;
                return a.end < b.end;
              });
    // Interval lemma: sorted by start, ANY overlap implies some ADJACENT pair
    // overlaps. Same-pair ranges never overlap (find-advance / merged), so an
    // adjacent overlap here necessarily crosses pairs.
    for (size_t i = 1; i < sorted.size(); ++i) {
      if (sorted[i].start < sorted[i - 1].end) {
        json resp;
        resp["ok"] = false;
        resp["error"] = "edits overlap";
        return resp.dump();
      }
    }
  }

  // ---- Apply: per-hit, global reverse byte-offset order ----
  std::sort(hits.begin(), hits.end(),
            [](const AppliedHit& a, const AppliedHit& b) {
              if (a.start != b.start) return a.start > b.start;
              return a.end > b.end;
            });

  std::string result = content;
  int replacements = 0;
  for (const auto& h : hits) {
    result.replace(h.start, h.end - h.start, pairs[h.pair].new_text);
    replacements++;
  }

  {
    std::ofstream out(resolved, std::ios::binary | std::ios::trunc);
    if (!out) return error_result("Cannot write file: " + path);
    out.write(result.data(), result.size());
  }

  LOG_INFO("edit_file: " + resolved + " " + std::to_string(hits.size()) + " replacements (batch)");
  json resp;
  resp["ok"] = true;
  resp["replacements"] = replacements;
  if (any_normalized) resp["matched_with"] = "whitespace normalization";
  return resp.dump();
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

// ---------------------------------------------------------------------------
// ripgrep-backed search tools (glob_file / grep_file)
// ---------------------------------------------------------------------------

// Search subprocess timeout (matches web_fetch SUBPROCESS_TIMEOUT_SEC)
static const int SEARCH_TIMEOUT_SEC = 30;

/// Locate the rg binary. Windows: DLL-relative + CWD-relative candidate paths
/// (no PATH fallback — matching resolve_script_path pattern); POSIX: PATH probe.
static std::string resolve_rg_path() {
#ifdef _WIN32
  char dll_path[MAX_PATH] = {0};
  HMODULE hModule = nullptr;
  static int dummy = 0;
  GetModuleHandleExA(
    GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
    (LPCSTR)&dummy, &hModule);
  if (hModule) {
    GetModuleFileNameA(hModule, dll_path, sizeof(dll_path));
  }
  std::string dir;
  if (dll_path[0] != '\0') {
    dir = dll_path;
    size_t last_sep = dir.find_last_of("\\/");
    if (last_sep != std::string::npos) dir = dir.substr(0, last_sep);
  }
  const char* suffixes[] = {
    "/../tools/rg.exe", "/tools/rg.exe",
    "/../share/aliasagent/tools/rg.exe", "/share/aliasagent/tools/rg.exe",
  };
  for (const auto* suffix : suffixes) {
    std::string candidate = dir + suffix;
    if (path_exists(candidate)) return candidate;
  }
  const char* cwd_suffixes[] = {"tools/rg.exe", "../tools/rg.exe"};
  for (const auto* c : cwd_suffixes) {
    if (path_exists(c)) {
      // Return an ABSOLUTE path: the subprocess runner sets the child's cwd
      // (lpCurrentDirectory), and CreateProcess resolves a relative argv[0]
      // against that cwd — which would fail to find rg.
      std::string abs = canonical(c);
      if (!abs.empty()) return abs;
      return c;
    }
  }
  return "";  // not found — caller returns install guidance
#else
  const char* path_env = getenv("PATH");
  if (path_env) {
    std::string p = path_env;
    size_t start = 0;
    while (start <= p.size()) {
      size_t end = p.find(':', start);
      std::string d = (end == std::string::npos) ? p.substr(start) : p.substr(start, end - start);
      std::string cand = d.empty() ? "rg" : d + "/rg";
      if (access(cand.c_str(), X_OK) == 0) return cand;
      if (end == std::string::npos) break;
      start = end + 1;
    }
  }
  return "";
#endif
}

/// Validate a glob pattern: allowed character set (A-Za-z0-9*?.,_/-[]{}!), no
/// absolute path, no `..` path segment (a `..` inside a filename like `a..b.txt`
/// is legal — the check is per path segment, not substring).
static bool is_valid_glob_pattern(const std::string& pattern, std::string& error) {
  if (pattern.empty()) {
    error = "pattern is required";
    return false;
  }
  if (pattern[0] == '/' || pattern[0] == '\\') {
    error = "absolute path not allowed";
    return false;
  }
#ifdef _WIN32
  if (pattern.size() >= 2 && pattern[1] == ':') {
    error = "absolute path not allowed";
    return false;
  }
#endif
  static const char kAllowed[] =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789*?.,_/-[]{}!";
  for (char c : pattern) {
    if (strchr(kAllowed, c) == nullptr) {
      error = std::string("invalid character in glob pattern: ") + c;
      return false;
    }
  }
  // Reject ".." only as an independent path segment (directory traversal).
  std::string seg;
  for (size_t i = 0; i <= pattern.size(); ++i) {
    if (i == pattern.size() || pattern[i] == '/' || pattern[i] == '\\') {
      if (seg == "..") {
        error = "path traversal not allowed (..)";
        return false;
      }
      seg.clear();
    } else {
      seg += pattern[i];
    }
  }
  return true;
}

/// Convert an rg output path to a workspace-relative path (de-rooting).
/// Handles absolute-under-root (strip prefix + separator), already-relative
/// (use as-is, normalize backslashes), and absolute-outside-root (keep as-is,
/// logged by caller). Path comparison is case-insensitive on Windows.
static std::string strip_root_prefix(const std::string& path, const std::string& root) {
  std::string p = path;
  for (auto& c : p) if (c == '\\') c = '/';

  bool is_abs = false;
#ifdef _WIN32
  is_abs = p.size() >= 2 && p[1] == ':';
#else
  is_abs = !p.empty() && p[0] == '/';
#endif

  if (is_abs && p.size() >= root.size()) {
    bool prefix_match = false;
#ifdef _WIN32
    prefix_match = _strnicmp(p.c_str(), root.c_str(), root.size()) == 0;
#else
    prefix_match = p.compare(0, root.size(), root) == 0;
#endif
    if (prefix_match) {
      if (p.size() == root.size()) return ".";
      if (p[root.size()] == '/') {
        return p.substr(root.size() + 1);
      }
      // Prefix matches but next char is not a separator (e.g. root2) — NOT
      // under the root; fall through and keep the path as-is.
    }
  }
  return p;
}

/// Find files within the workspace matching a glob pattern (ripgrep-backed).
/// Request JSON: {"pattern":"...", "max_results":N}
/// Returns JSON: {"ok":true,"paths":[...],"count":N,"truncated":true|false}
std::string glob_file(const std::string& request_json) {
  LOG_TRACE("tools::glob_file entry");

  std::string pattern;
  int max_results = 200;
  try {
    auto req = json::parse(request_json);
    pattern = req.value("pattern", "");
    if (req.contains("max_results") && req["max_results"].is_number()) {
      max_results = req["max_results"].get<int>();
    }
  } catch (const json::parse_error& e) {
    return error_result("Invalid request JSON: " + std::string(e.what()));
  }

  std::string verr;
  if (!is_valid_glob_pattern(pattern, verr)) return error_result(verr);
  if (max_results <= 0) return error_result("max_results must be >= 1");
  if (g_workspace.empty()) return error_result("No workspace set");

  std::string rg = resolve_rg_path();
  if (rg.empty()) {
    return error_result("rg not found — install ripgrep or place rg.exe in tools/");
  }

  // rg --files --no-require-git -g <pattern> <workspace_root>
  std::vector<std::string> argv;
  argv.push_back(rg);
  argv.push_back("--files");
  argv.push_back("--no-require-git");
  argv.push_back("-g");
  argv.push_back(pattern);
  argv.push_back(g_workspace);

  // Stream-parse the newline-delimited --files output and terminate rg early
  // once max_results paths are collected (D4: "max_results 到达即终止"), so a
  // huge tree does not buffer unboundedly or run to the 30s timeout when the
  // first results were already available.
  std::vector<std::string> paths;  // holds at most max_results entries
  bool truncated = false;
  std::string leftover;

  subprocess::Options opts;
  opts.timeout_seconds = SEARCH_TIMEOUT_SEC;
  opts.cwd = g_workspace;
  opts.on_stdout_chunk = [&](const std::string& chunk) -> bool {
    leftover += chunk;
    size_t nl;
    while ((nl = leftover.find('\n')) != std::string::npos) {
      std::string line = leftover.substr(0, nl);
      leftover.erase(0, nl + 1);
      if (!line.empty() && line.back() == '\r') line.pop_back();
      if (line.empty()) continue;
      if (paths.size() < static_cast<size_t>(max_results)) {
        paths.push_back(strip_root_prefix(line, g_workspace));
      } else {
        truncated = true;
        return true;  // terminate rg — max_results already collected
      }
    }
    return false;
  };

  subprocess::Result res = subprocess::run(argv, opts);

  if (!res.started) return error_result("Failed to start ripgrep");
  if (res.timed_out) return error_result("glob_file timed out after 30 seconds");
  // Exit code: 0 = files found, 1 = no match (normal empty result, success),
  // 2 = error (ripgrepDoc section 4). Skip when the truncation handler
  // terminated the process (killed processes have no meaningful exit code).
  if (!res.stopped_early && res.exit_code == 2) {
    std::string err = res.stderr_data.empty() ? "unknown ripgrep error" : res.stderr_data;
    json resp;
    resp["ok"] = false;
    resp["error"] = "search failed: " + err;
    return resp.dump();
  }

  size_t count = paths.size();

  json resp;
  resp["ok"] = true;
  resp["paths"] = json::array();
  for (size_t i = 0; i < count; ++i) resp["paths"].push_back(paths[i]);
  resp["count"] = count;
  if (truncated) resp["truncated"] = true;

  LOG_INFO("glob_file: pattern=" + pattern + " matched=" + std::to_string(count) +
           " truncated=" + (truncated ? "true" : "false"));
  return resp.dump();
}

// ---------------------------------------------------------------------------
// grep_file — ripgrep --json regex content search
// ---------------------------------------------------------------------------

/// Minimal base64 decoder (rg `--json` encodes non-UTF-8 path/text as `bytes`,
/// which the doc marks UNVERIFIED; accept it leniently when `text` is absent).
static std::string base64_decode(const std::string& in) {
  static const char* tbl =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  int val[256];
  for (int i = 0; i < 256; ++i) val[i] = -1;
  for (int i = 0; i < 64; ++i) val[static_cast<unsigned char>(tbl[i])] = i;
  std::string out;
  int buffer = 0, bits = 0;
  for (unsigned char c : in) {
    if (c == '=' || c == '\n' || c == '\r') continue;
    if (c > 255 || val[c] < 0) continue;
    buffer = (buffer << 6) | val[c];
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out += static_cast<char>((buffer >> bits) & 0xFF);
    }
  }
  return out;
}

/// Classify rg's exit-2 stderr: true when it is a regex parse error (which
/// grep_file reports as "invalid regex"), false for other (soft) errors such as
/// an unreadable file (reported as "search failed"). Exposed for testing.
bool classify_grep_regex_error(const std::string& stderr_data) {
  std::string lower = stderr_data;
  std::transform(lower.begin(), lower.end(), lower.begin(),
                 [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
  return lower.find("regex parse error") != std::string::npos ||
         lower.find("regex parse") != std::string::npos;
}

/// Build a grep match entry `{path, line?, text?}` from an `--json` match
/// message's `data` object, de-rooting the path. Degrades gracefully when
/// fields are absent (path via `bytes` base64, missing line_number omitted).
/// The field schema is verified in Docs/ripgrepDoc.md section 1.1. Exposed for
/// testing the lenient-degradation paths.
json build_match_entry(const json& data, const std::string& root) {
  json entry;
  if (data.is_object()) {
    if (data.contains("path") && data["path"].is_object()) {
      const auto& pathobj = data["path"];
      if (pathobj.contains("text") && pathobj["text"].is_string()) {
        entry["path"] = strip_root_prefix(pathobj["text"].get<std::string>(), root);
      } else if (pathobj.contains("bytes") && pathobj["bytes"].is_string()) {
        entry["path"] = strip_root_prefix(
            base64_decode(pathobj["bytes"].get<std::string>()), root);
      }
    }
    if (data.contains("line_number") && data["line_number"].is_number()) {
      entry["line"] = data["line_number"].get<int>();
    }
    if (data.contains("lines") && data["lines"].is_object()) {
      const auto& linesobj = data["lines"];
      if (linesobj.contains("text") && linesobj["text"].is_string()) {
        entry["text"] = linesobj["text"].get<std::string>();
      } else if (linesobj.contains("bytes") && linesobj["bytes"].is_string()) {
        entry["text"] = base64_decode(linesobj["bytes"].get<std::string>());
      }
    }
  }
  return entry;
}

/// Search file contents within the workspace using a regular expression
/// (ripgrep-backed). Request JSON:
///   {"pattern":"...", "glob":"...", "ignore_case":bool, "max_results":N}
/// Returns JSON:
///   {"ok":true,"matches":[{"path":"...","line":N,"text":"..."}],
///    "count":N,"truncated":true|false}
/// or {"ok":false,"error":"..."}
std::string grep_file(const std::string& request_json) {
  LOG_TRACE("tools::grep_file entry");

  std::string pattern;
  std::string glob;
  bool ignore_case = false;
  int max_results = 100;
  try {
    auto req = json::parse(request_json);
    pattern = req.value("pattern", "");
    glob = req.value("glob", "");
    if (req.contains("ignore_case") && req["ignore_case"].is_boolean()) {
      ignore_case = req["ignore_case"].get<bool>();
    }
    if (req.contains("max_results") && req["max_results"].is_number()) {
      max_results = req["max_results"].get<int>();
    }
  } catch (const json::parse_error& e) {
    return error_result("Invalid request JSON: " + std::string(e.what()));
  }

  if (pattern.empty()) return error_result("pattern is required");
  if (max_results <= 0) return error_result("max_results must be >= 1");
  if (!glob.empty()) {
    std::string verr;
    if (!is_valid_glob_pattern(glob, verr)) return error_result(verr);
  }
  if (g_workspace.empty()) return error_result("No workspace set");

  std::string rg = resolve_rg_path();
  if (rg.empty()) {
    return error_result("rg not found — install ripgrep or place rg.exe in tools/");
  }

  // rg --json -n --no-require-git [--glob <glob>] [-i] [-m N] -- <pattern> <root>
  std::vector<std::string> argv;
  argv.push_back(rg);
  argv.push_back("--json");
  argv.push_back("-n");
  argv.push_back("--no-require-git");
  if (!glob.empty()) {
    argv.push_back("--glob");
    argv.push_back(glob);
  }
  if (ignore_case) argv.push_back("-i");
  // -m is a per-file cap at a relaxed multiple of the global limit so a single
  // file cannot monopolize all results (4x — MAX_COUNT_MULTIPLIER).
  constexpr int MAX_COUNT_MULTIPLIER = 4;
  argv.push_back("-m");
  argv.push_back(std::to_string(static_cast<long long>(max_results) * MAX_COUNT_MULTIPLIER));
  argv.push_back("--");  // isolate pattern so it is never parsed as a flag
  argv.push_back(pattern);
  argv.push_back(g_workspace);

  // Stream-parse the --json message stream and decide truncation by message
  // type (the stream always ends with a `summary` message — ripgrepDoc section
  // 1). After collecting max_results `match` messages, the next message being
  // a `match` → truncated; being a `summary` → total is exactly max_results
  // (or fewer), no truncation.
  json matches = json::array();
  bool truncated = false;
  bool decided = false;
  std::string leftover;

  subprocess::Options opts;
  opts.timeout_seconds = SEARCH_TIMEOUT_SEC;
  opts.cwd = g_workspace;
  opts.on_stdout_chunk = [&](const std::string& chunk) -> bool {
    leftover += chunk;
    size_t nl;
    while ((nl = leftover.find('\n')) != std::string::npos) {
      std::string line = leftover.substr(0, nl);
      leftover.erase(0, nl + 1);
      if (line.empty()) continue;
      if (decided) continue;  // already saw summary — skip any stragglers
      json msg;
      try {
        msg = json::parse(line);
      } catch (...) {
        continue;  // lenient — skip unparseable lines
      }
      if (!msg.is_object() || !msg.contains("type")) continue;
      std::string type = msg["type"].get<std::string>();
      if (type == "match") {
        if (matches.size() < static_cast<size_t>(max_results)) {
          // Lenient extraction (schema verified in ripgrepDoc 1.1; degrade
          // when fields are absent).
          json data = (msg.contains("data") && msg["data"].is_object())
              ? msg["data"]
              : json::object();
          matches.push_back(build_match_entry(data, g_workspace));
        } else {
          truncated = true;
          decided = true;
          return true;  // terminate rg — we have enough
        }
      } else if (type == "summary") {
        // Total is within the limit. Do NOT return true here — stopping the
        // process early would discard its real exit code, hiding soft errors
        // (rg emits summary then exits 2 when some files were unreadable).
        decided = true;
      }
    }
    return false;
  };

  subprocess::Result res = subprocess::run(argv, opts);

  if (!res.started) return error_result("Failed to start ripgrep");
  if (res.timed_out) return error_result("grep_file timed out after 30 seconds");

  // Map exit codes only when the process was NOT terminated early by the
  // truncation handler (a killed process has no meaningful exit code). Exit 0
  // (match) and 1 (no match, normal empty result) are success; exit 2 is an
  // error (regex error or soft error such as an unreadable file — ripgrepDoc
  // section 4) distinguished via stderr. The summary message does NOT suppress
  // the exit-2 check: rg emits summary and still exits 2 on soft errors.
  if (!res.stopped_early) {
    if (res.exit_code == 2) {
      bool regex_error = classify_grep_regex_error(res.stderr_data);
      json resp;
      resp["ok"] = false;
      resp["error"] = regex_error
          ? ("invalid regex: " + res.stderr_data)
          : ("search failed: " + (res.stderr_data.empty() ? "unknown ripgrep error" : res.stderr_data));
      return resp.dump();
    }
  }

  json resp;
  resp["ok"] = true;
  resp["matches"] = matches;
  resp["count"] = matches.size();
  if (truncated) resp["truncated"] = true;
  LOG_INFO("grep_file: pattern=" + pattern + " matches=" + std::to_string(matches.size()) +
           " truncated=" + (truncated ? "true" : "false"));
  return resp.dump();
}

} // namespace tools
