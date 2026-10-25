#include "command_tool.h"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

#include <nlohmann/json.hpp>

#include "subprocess.h"
#include "spill.h"
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
// 缺省值（规范：`spill.preview_chars` 与两个超时）
// ---------------------------------------------------------------------------

/// 命令缺省超时毫秒数。
constexpr long long kDefaultTimeoutMs = 120000;
/// 超时上限：调用方给得比它大就按它执行。
constexpr long long kDefaultMaxTimeoutMs = 600000;
/// 头尾各留多少字符（`preview_chars` 的缺省值）。用户 2026-10-25 的决定：原话
/// 「4000字听起来也好多，改成1000字吧」。可配，配置键 `spill.preview_chars`。
/// 判断"要不要省略"的阈值是它的 2 倍（头 + 尾），算术推论，不是第二个魔数。
constexpr long long kDefaultPreviewChars = 1000;

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
// 小工具：取配置值、清洗 UTF-8、按字符切头尾、把一条流落盘并算出交付形状
// ---------------------------------------------------------------------------

long long int_field(const json& req, const char* key, long long fallback,
                    long long minimum = 1) {
  if (!req.contains(key)) return fallback;
  const json& v = req[key];
  if (!v.is_number_integer() && !v.is_number_float()) return fallback;
  const long long n = v.get<long long>();
  return n < minimum ? fallback : n;
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

/// 一条流的交付形状。
///
/// 三条不变量（`spill-large-tool-output` 的判据就钉在这三条上）：
///   ① `head` / `tail` 是 spill 文件里的**原始字节切片**（只在码点边界落刀），
///      所以 `|head| + |tail| + omitted_bytes == total_bytes` 恒成立；
///   ② 给模型看的 `inline_text` 由 `sanitize_utf8(head/tail)` 拼出来 —— 换行归一
///      与坏字节替换**只发生在这一步**，不落到文件上；
///   ③ `ref` 就是那个文件的绝对路径，`read_spill` 能按字节读回中间段。
struct StreamShape {
  std::string inline_text;  // 交给模型的那份
  bool truncated = false;
  json envelope = json::object();  // {ref,total_bytes,omitted_bytes,head,tail}
};

/// 把一条流先落盘，再按 `preview_chars × 2` 决定内联全文还是头尾 + 引用。
///
/// 落盘失败时不返回 `ok:false` —— 由调用方按"输出是否超过预览阈值"决定兜底方式
/// （小的直接内联，大的必须报错，见规范"写盘失败必须可见"）。
StreamShape shape_stream(const std::string& raw, size_t preview_chars,
                         const std::string& session, const char* tag,
                         spill::Written* written_out) {
  StreamShape r;
  const spill::Written w = spill::write(session, tag, raw);
  if (written_out) *written_out = w;
  if (!w.ok) {
    // 写盘失败：先把能给的给出去，形态交给调用方判断。
    r.inline_text = sanitize_utf8(raw);
    return r;
  }
  const size_t total = w.bytes;
  const size_t chars = spill::char_count(raw);
  if (chars <= preview_chars * 2) {
    // 内联全文：不出现任何"省略"字样（否则省略量会是 0 或负数）
    r.inline_text = sanitize_utf8(raw);
    r.truncated = false;
    r.envelope = {{"ref", w.path},
                  {"total_bytes", total},
                  {"omitted_bytes", 0},
                  {"head", raw},
                  {"tail", ""}};
    return r;
  }

  const std::string head = spill::head_chars(raw, preview_chars);
  const std::string tail = spill::tail_chars(raw, preview_chars);
  const size_t covered = head.size() + tail.size();
  const size_t omitted = total > covered ? total - covered : 0;
  r.truncated = true;
  r.envelope = {{"ref", w.path},
                {"total_bytes", total},
                {"omitted_bytes", omitted},
                {"head", head},
                {"tail", tail}};

  // 省略说明写在**头尾之间**：说清略去了多少、全文在哪、怎么读回。
  char how[256];
  std::snprintf(how, sizeof(how),
                "[... %zu bytes omitted of %zu; full output: %s — read it back with "
                "read_spill (ref, offset=%zu, limit=%zu)]",
                omitted, total, w.path.c_str(), head.size(), omitted);
  r.inline_text = sanitize_utf8(head) + "\n" + how + "\n" + sanitize_utf8(tail);
  return r;
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

  // 头尾各留多少字符：单一配置项 `spill.preview_chars`（配置由 Dart 侧读好随请求
  // 传进来，执行侧不读配置文件 —— 与超时那几个值的做法一致）。
  const long long preview_chars = int_field(req, "preview_chars", kDefaultPreviewChars);
  const std::string spill_session = req.value("spill_session", std::string("no-session"));

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

  spill::Written out_written;
  spill::Written err_written;
  const StreamShape out = shape_stream(res.stdout_data, static_cast<size_t>(preview_chars),
                                       spill_session, "stdout", &out_written);
  const StreamShape err = shape_stream(res.stderr_data, static_cast<size_t>(preview_chars),
                                       spill_session, "stderr", &err_written);

  // 写盘失败要看得见（规范"写盘失败必须可见"）：小输出已经内联全文，不算失败；
  // 大输出则**不能**只给一部分冒充完整结果 —— 直接报错，说清目录与原因。
  const size_t preview_limit = static_cast<size_t>(preview_chars) * 2;
  for (const auto* pair : {&out_written, &err_written}) {
    if (pair->ok) continue;
    const bool is_stdout = (pair == &out_written);
    const std::string& raw = is_stdout ? res.stdout_data : res.stderr_data;
    if (spill::char_count(raw) <= preview_limit) continue;
    return json{{"ok", false},
                {"error", std::string(is_stdout ? "标准输出" : "标准错误") +
                              "没能写进 spill 文件，且输出超过了预览阈值（无法只给一部分"
                              "冒充完整结果）：" + pair->error}}
        .dump(-1, ' ', false, json::error_handler_t::replace);
  }

  json result;
  result["ok"] = true;
  result["exit_code"] = res.exit_code;
  result["timed_out"] = res.timed_out;
  result["duration_ms"] = duration_ms;
  result["stdout"] = out.inline_text;
  result["stderr"] = err.inline_text;
  result["truncated"] = {{"stdout", out.truncated}, {"stderr", err.truncated}};
  json envelopes = json::object();
  if (out_written.ok) envelopes["stdout"] = out.envelope;
  if (err_written.ok) envelopes["stderr"] = err.envelope;
  if (!envelopes.empty()) result["spill"] = envelopes;
  // `error_handler_t::replace`：输出里可能有不是合法 UTF-8 的字节，替换掉而不是抛异常
  // （文件里仍是原始字节，替换只影响这份 JSON 里的呈现）。
  return result.dump(-1, ' ', false, json::error_handler_t::replace);
}

}  // namespace command_tool
