#include "command_tool.h"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

#include <nlohmann/json.hpp>

#include "subprocess.h"
#include "tools.h"

#ifdef _WIN32
#include <windows.h>
#else
#include <sys/stat.h>
#include <unistd.h>
#endif

using nlohmann::json;

namespace command_tool {

namespace {

// ---------------------------------------------------------------------------
// 缺省值与下限（规范：四个配置项与缺省值）
// ---------------------------------------------------------------------------

/// 命令缺省超时毫秒数。
constexpr long long kDefaultTimeoutMs = 120000;
/// 超时上限：调用方给得比它大就按它执行。
constexpr long long kDefaultMaxTimeoutMs = 600000;
/// 每条流在内存里保留的字符上限。与 `lib/main.dart` 的
/// `kToolResultElisionThreshold`（8000）对齐 —— 大于它的话，工具刚拼好的
/// "截断了、全文在哪"会被发给模型之前那道通用截断掐掉中间。
constexpr size_t kDefaultMaxOutputChars = 8000;
/// 字符上限的下限：再小就连截断说明和全文路径都放不下。
constexpr size_t kMinMaxOutputChars = 1000;
/// 写临时文件的完整输出上限，超过它就不落文件、只标截断。
constexpr size_t kDefaultFullOutputChars = 2000000;

/// UTF-8 输出钉成不带 BOM 的 UTF-8；用 `; ` 与命令接在同一行，好让 PowerShell
/// 报错时的行号仍对应调用方命令的行号（前缀与命令之间**不许插换行**）。
const char* kEncodingPreamble =
    "[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false); "
    "$OutputEncoding = [System.Text.UTF8Encoding]::new($false); ";

// ---------------------------------------------------------------------------
// 可执行文件解析
// ---------------------------------------------------------------------------

#ifdef _WIN32
/// UTF-8 → UTF-16。**复用 `subprocess` 里那一份，不要在这里另写一个** ——
/// 我手写过一版（把每个字节当成一个码元），它是错的，表现是"目录明明存在却报
/// 不存在"，查了很久。工作区里完全可能有中文路径，而 `GetFileAttributesA`
/// 这类 ANSI 接口在中文名下会失败。
std::wstring to_wide(const std::string& s) { return subprocess::utf8_to_wide(s); }

/// 正斜杠换成原生反斜杠：`GetFileAttributesW` / `CreateProcess` 这类接口只认
/// Windows 原生分隔符，而 `tools::resolve` 给的是正斜杠规范形。
std::string to_native(const std::string& path) {
  std::string out = path;
  for (auto& c : out)
    if (c == '/') c = '\\';
  return out;
}
#endif

bool file_exists(const std::string& path) {
#ifdef _WIN32
  const std::wstring w = to_wide(to_native(path));
  return !w.empty() && GetFileAttributesW(w.c_str()) != INVALID_FILE_ATTRIBUTES;
#else
  return access(path.c_str(), X_OK) == 0;
#endif
}

bool is_directory(const std::string& path) {
#ifdef _WIN32
  const std::wstring w = to_wide(to_native(path));
  if (w.empty()) return false;
  const DWORD attr = GetFileAttributesW(w.c_str());
  if (attr != INVALID_FILE_ATTRIBUTES) {
    return (attr & FILE_ATTRIBUTE_DIRECTORY) != 0;
  }
  // 备用探针：极少数情况下 `GetFileAttributesW` 会对一个确实存在的目录返回
  // "不存在"，而同一个路径用 `CreateFileW` 打开是成功的。多问一句不花钱，能少一类
  // "目录明明在却被拒"的假阴性（本机排查这一类问题时被它误导过很久）。
  HANDLE h = CreateFileW(w.c_str(), 0, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                         OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, nullptr);
  if (h == INVALID_HANDLE_VALUE) return false;
  BY_HANDLE_FILE_INFORMATION info = {};
  const bool ok = GetFileInformationByHandle(h, &info) != 0;
  CloseHandle(h);
  return ok && (info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
#else
  struct stat st;
  return stat(path.c_str(), &st) == 0 && S_ISDIR(st.st_mode);
#endif
}

/// 按固定顺序找一个 PowerShell：先 PowerShell 7 的两处安装位置，再 PATH 里的
/// `pwsh.exe`，最后是 Windows PowerShell 5.1。四处都没有就返回空串
/// （**不许**换成 cmd 或 bash —— 方言固定是 PowerShell）。
std::string resolve_powershell() {
#ifdef _WIN32
  auto env = [](const char* name) -> std::string {
    char buf[32768];
    const DWORD n = GetEnvironmentVariableA(name, buf, sizeof(buf));
    return n > 0 && n < sizeof(buf) ? std::string(buf, n) : std::string();
  };
  const std::string pf = env("ProgramFiles");
  const std::string pf86 = env("ProgramFiles(x86)");
  if (!pf.empty() && file_exists(pf + "\\PowerShell\\7\\pwsh.exe")) {
    return pf + "\\PowerShell\\7\\pwsh.exe";
  }
  if (!pf86.empty() && file_exists(pf86 + "\\PowerShell\\7\\pwsh.exe")) {
    return pf86 + "\\PowerShell\\7\\pwsh.exe";
  }
  const std::string path = env("PATH");
  size_t start = 0;
  while (start <= path.size()) {
    const size_t sep = path.find(';', start);
    const std::string dir =
        path.substr(start, sep == std::string::npos ? std::string::npos : sep - start);
    if (!dir.empty()) {
      const std::string cand = dir + "\\pwsh.exe";
      if (file_exists(cand)) return cand;
    }
    if (sep == std::string::npos) break;
    start = sep + 1;
  }
  const std::string system_root = env("SystemRoot");
  const std::string fallback =
      (system_root.empty() ? std::string("C:\\Windows") : system_root) +
      "\\System32\\WindowsPowerShell\\v1.0\\powershell.exe";
  if (file_exists(fallback)) return fallback;
  return "";
#else
  for (const char* c : {"/usr/bin/pwsh", "/usr/local/bin/pwsh", "/usr/bin/powershell"}) {
    if (file_exists(c)) return c;
  }
  return "";
#endif
}

// ---------------------------------------------------------------------------
// 小工具：取配置值、取临时目录、清洗 UTF-8、按字符取尾部
// ---------------------------------------------------------------------------

long long int_field(const json& req, const char* key, long long fallback,
                    long long minimum = 1) {
  if (!req.contains(key)) return fallback;
  const json& v = req[key];
  if (!v.is_number_integer() && !v.is_number_float()) return fallback;
  const long long n = v.get<long long>();
  return n < minimum ? fallback : n;
}

std::string temp_dir() {
#ifdef _WIN32
  char buf[MAX_PATH];
  const DWORD n = GetTempPathA(MAX_PATH, buf);
  std::string dir = (n > 0 && n < MAX_PATH) ? std::string(buf, n) : std::string(".");
  while (dir.size() > 1 && (dir.back() == '\\' || dir.back() == '/')) dir.pop_back();
  return dir;
#else
  const char* t = getenv("TMPDIR");
  return t && *t ? std::string(t) : std::string("/tmp");
#endif
}

/// 把不合法的 UTF-8 字节换成替换字符；顺便把 CRLF 归一成 LF（发给模型的文本用
/// LF 更省 token，也免得同一段内容出现两种换行）。**不丢内容、不崩**。
std::string sanitize_utf8(const std::string& in) {
  std::string out;
  out.reserve(in.size());
  size_t i = 0;
  auto is_cont = [](unsigned char b) { return (b & 0xC0) == 0x80; };
  while (i < in.size()) {
    const unsigned char b = static_cast<unsigned char>(in[i]);
    size_t len = 0;
    if (b < 0x80) {
      len = 1;
    } else if ((b & 0xE0) == 0xC0) {
      len = 2;
    } else if ((b & 0xF0) == 0xE0) {
      len = 3;
    } else if ((b & 0xF8) == 0xF0) {
      len = 4;
    }
    bool ok = len > 0 && i + len <= in.size();
    if (ok) {
      for (size_t k = 1; k < len; ++k) {
        if (!is_cont(static_cast<unsigned char>(in[i + k]))) {
          ok = false;
          break;
        }
      }
      if (ok && len == 2 && b < 0xC2) ok = false;  // 过长编码不接受
      if (ok && len == 3 && b == 0xE0 && static_cast<unsigned char>(in[i + 1]) < 0xA0) ok = false;
      if (ok && len == 4 && b == 0xF0 && static_cast<unsigned char>(in[i + 1]) < 0x90) ok = false;
    }
    if (ok) {
      out.append(in, i, len);
      i += len;
    } else {
      out += "\xEF\xBF\xBD";  // U+FFFD
      i += 1;
    }
  }
  std::string normalized;
  normalized.reserve(out.size());
  for (size_t k = 0; k < out.size(); ++k) {
    if (out[k] == '\r' && k + 1 < out.size() && out[k + 1] == '\n') continue;
    normalized += out[k];
  }
  return normalized;
}

/// 按字符数（不是字节数）取尾部。UTF-8 里一个字符最多 4 字节，所以按字节从后往前
/// 扫、遇到字符起始字节就计一个字符，保证不会把多字节字符切成半个。
/// 总字符数不超过上限时**原样返回**（早先这里写错过一次：短输出返回了空串，
/// 症状是"命令明明有输出、返回的 stdout 却是空的"）。
std::string tail_chars(const std::string& s, size_t max_chars, size_t* total_chars) {
  size_t total = 0;
  for (size_t i = 0; i < s.size(); ++i) {
    if ((static_cast<unsigned char>(s[i]) & 0xC0) != 0x80) ++total;
  }
  if (total_chars) *total_chars = total;
  if (total <= max_chars) return s;

  size_t seen = 0;
  for (size_t i = s.size(); i > 0;) {
    --i;
    if ((static_cast<unsigned char>(s[i]) & 0xC0) != 0x80) {
      ++seen;
      if (seen == max_chars) return s.substr(i);
    }
  }
  return s;  // 到不了这里（total > max_chars 时必然找得到切点）
}

/// 把一条流的完整内容写进系统临时目录。返回路径；写不了则返回空串。
std::string write_full_output(const std::string& content, const char* tag) {
  static unsigned counter = 0;
  ++counter;
#ifdef _WIN32
  const unsigned long pid = GetCurrentProcessId();
#else
  const unsigned long pid = static_cast<unsigned long>(getpid());
#endif
  char name[512];
  std::snprintf(name, sizeof(name), "%s\\aliasagent_run_command_%lu_%u_%s.log",
                temp_dir().c_str(), pid, counter, tag);
  FILE* f = std::fopen(name, "wb");
  if (!f) return "";
  const size_t written = std::fwrite(content.data(), 1, content.size(), f);
  std::fclose(f);
  if (written != content.size()) return "";
  return name;
}

/// 一条流的取舍结果。
struct StreamResult {
  std::string text;       // 交给模型的尾部
  bool truncated = false;
  size_t original_chars = 0;
  size_t kept_chars = 0;
  std::string full_path;  // 写了完整输出文件时非空
};

StreamResult shape_stream(const std::string& raw, size_t max_chars, size_t full_limit,
                          const char* tag) {
  StreamResult r;
  const std::string cleaned = sanitize_utf8(raw);
  size_t total_chars = 0;
  r.text = tail_chars(cleaned, max_chars, &total_chars);
  r.original_chars = total_chars;
  r.kept_chars = (total_chars > max_chars) ? max_chars : total_chars;
  r.truncated = total_chars > max_chars;
  if (r.truncated && cleaned.size() <= full_limit) {
    r.full_path = write_full_output(cleaned, tag);
  }
  return r;
}

void merge_stream(json& out, const StreamResult& s, const char* key) {
  out[key] = s.text;
  if (!s.truncated) return;
  out[std::string(key) + "_original_chars"] = s.original_chars;
  out[std::string(key) + "_kept_chars"] = s.kept_chars;
}

}  // namespace

std::vector<std::string> build_invocation(const std::string& shell,
                                          const std::string& command) {
  return {shell, "-NoLogo", "-NoProfile", "-NonInteractive", "-Command",
          std::string(kEncodingPreamble) + command};
}

std::string run_command(const std::string& request_json) {
  json req;
  try {
    req = json::parse(request_json.empty() ? "{}" : request_json);
  } catch (const std::exception& e) {
    return json{{"ok", false},
                {"error", std::string("请求不是合法的 JSON：") + e.what()}}
        .dump();
  }
  if (!req.is_object()) {
    return json{{"ok", false}, {"error", "请求必须是一个 JSON 对象"}}.dump();
  }

  const std::string command = req.value("command", std::string());
  if (command.empty()) {
    return json{{"ok", false}, {"error", "command 不能为空"}}.dump();
  }

  // ---- 工作目录：相对当前工作区解析，越界拒绝（连命令都不执行）----
  std::string workdir = tools::workspace();
#ifdef _WIN32
  workdir = to_native(workdir);
#endif
  const std::string requested_dir = req.value("workdir", std::string());
  if (!requested_dir.empty()) {
    std::string requested_native = requested_dir;
#ifdef _WIN32
    requested_native = to_native(requested_native);
#endif
    const std::string resolved = tools::resolve(requested_native);
    if (resolved.empty()) {
      return json{{"ok", false},
                  {"error", "工作目录无法解析：" + requested_dir +
                                "（相对路径按当前工作区解析）"}}
          .dump();
    }
    if (!tools::is_within_workspace(resolved)) {
      return json{{"ok", false},
                  {"error", "工作目录不允许在工作区之外：" + requested_dir}}
          .dump();
    }
    if (!is_directory(resolved)) {
      return json{{"ok", false}, {"error", "工作目录不存在或不是目录：" + resolved}}.dump();
    }
    workdir = resolved;
#ifdef _WIN32
    workdir = to_native(workdir);
#endif
  }

  // ---- 可执行文件 ----
  const std::string shell = resolve_powershell();
  if (shell.empty()) {
    return json{{"ok", false},
                {"error",
                 "找不到 PowerShell：已依次查找 PowerShell 7 的两处安装位置、PATH 里的 "
                 "pwsh.exe、以及 Windows PowerShell 5.1，四处都不存在。本工具只执行 "
                 "PowerShell 方言的命令，不会改用别的解释器。"}}
        .dump();
  }

  // ---- 配置值（缺省 / 非法回落 / 上限截断 / 下限抬升）----
  const long long timeout_ms = int_field(req, "timeout_ms", kDefaultTimeoutMs);
  long long max_timeout_ms = int_field(req, "max_timeout_ms", kDefaultMaxTimeoutMs);
  if (max_timeout_ms < 1) max_timeout_ms = kDefaultMaxTimeoutMs;
  const long long effective_timeout = std::min(timeout_ms, max_timeout_ms);

  long long max_output_chars =
      int_field(req, "max_output_chars", static_cast<long long>(kDefaultMaxOutputChars));
  if (max_output_chars < static_cast<long long>(kMinMaxOutputChars)) {
    max_output_chars = static_cast<long long>(kMinMaxOutputChars);
  }
  const long long full_output_chars =
      int_field(req, "full_output_chars", static_cast<long long>(kDefaultFullOutputChars));

  // ---- 起进程 ----
  subprocess::Options opts;
  opts.timeout_ms = static_cast<int>(effective_timeout);
  opts.cwd = workdir;
  opts.extra_env = {{"NO_COLOR", "1"}, {"PAGER", "cat"}, {"GIT_PAGER", "cat"}};

  const auto t0 = std::chrono::steady_clock::now();
  subprocess::Result res = subprocess::run(build_invocation(shell, command), opts);
  const long long duration_ms =
      std::chrono::duration_cast<std::chrono::milliseconds>(
          std::chrono::steady_clock::now() - t0)
          .count();

  if (!res.started) {
    return json{{"ok", false},
                {"error", "命令没能启动：解释器或工作目录无法使用（解释器=" + shell +
                              "，工作目录=" + workdir + "）。"}}
        .dump();
  }

  const StreamResult out = shape_stream(res.stdout_data, static_cast<size_t>(max_output_chars),
                                        static_cast<size_t>(full_output_chars), "stdout");
  const StreamResult err = shape_stream(res.stderr_data, static_cast<size_t>(max_output_chars),
                                        static_cast<size_t>(full_output_chars), "stderr");

  json result;
  result["ok"] = true;
  result["exit_code"] = res.exit_code;
  result["timed_out"] = res.timed_out;
  result["duration_ms"] = duration_ms;
  merge_stream(result, out, "stdout");
  merge_stream(result, err, "stderr");
  result["truncated"] = {{"stdout", out.truncated}, {"stderr", err.truncated}};
  if (!out.full_path.empty() || !err.full_path.empty()) {
    json paths = json::object();
    if (!out.full_path.empty()) paths["stdout"] = out.full_path;
    if (!err.full_path.empty()) paths["stderr"] = err.full_path;
    result["full_output_paths"] = paths;
  }
  return result.dump();
}

}  // namespace command_tool
