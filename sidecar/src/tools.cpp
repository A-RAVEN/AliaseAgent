#include "tools.h"
#include "logger.h"

#include <string>
#include <vector>
#include <fstream>
#include <sstream>
#include <algorithm>
#include <cstring>

#ifdef _WIN32
#include <windows.h>
#else
#include <limits.h>
#include <stdlib.h>
#include <dirent.h>
#include <sys/stat.h>
#endif

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
// Path resolution & sandboxing (6.4)
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
// JSON helpers (minimal — avoid pulling in nlohmann for two functions)
// ---------------------------------------------------------------------------

static std::string json_escape(const std::string& s) {
  std::string out;
  out.reserve(s.size() + 16);
  for (char c : s) {
    switch (c) {
      case '"':  out += "\\\""; break;
      case '\\': out += "\\\\"; break;
      case '\n': out += "\\n";  break;
      case '\r': out += "\\r";  break;
      case '\t': out += "\\t";  break;
      default:   out += c;
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
// read_file (6.2)
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

std::string read_file(const std::string& path) {
  // Resolve and sandbox
  std::string resolved = resolve(path);
  if (resolved.empty()) {
    if (g_workspace.empty()) return error_result("No workspace set");
    return error_result("Cannot resolve path: " + path);
  }
  if (!is_within_workspace(resolved)) {
    LOG_WARN("read_file access denied: " + resolved);
    return error_result("Access denied: path outside workspace");
  }

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

  // Read content
  std::ifstream f(resolved, std::ios::binary);
  if (!f) {
    return error_result("Cannot open file: " + path);
  }
  std::ostringstream ss;
  ss << f.rdbuf();
  std::string content = ss.str();

  LOG_INFO("read_file: " + resolved + " (" + std::to_string(content.size()) + " bytes)");
  return ok_result(content);
}

// ---------------------------------------------------------------------------
// list_dir (6.3)
// ---------------------------------------------------------------------------

std::string list_dir(const std::string& path) {
  // Resolve and sandbox
  std::string resolved = resolve(path);
  if (resolved.empty()) {
    if (g_workspace.empty()) return error_result("No workspace set");
    return error_result("Cannot resolve path: " + path);
  }
  if (!is_within_workspace(resolved)) {
    LOG_WARN("list_dir access denied: " + resolved);
    return error_result("Access denied: path outside workspace");
  }

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

  std::string result = "{\"ok\":true,\"entries\":[" + entries.str() + "]}";
  LOG_INFO("list_dir: " + resolved + " (" + result + ")");
  return result;
}

} // namespace tools
