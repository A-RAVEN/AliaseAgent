#include "browser.h"
#include "tools.h"
#include "logger.h"
#include "subprocess.h"
#include <nlohmann/json.hpp>
#include <string>
#include <vector>
#include <thread>
#include <mutex>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>

#ifdef _WIN32
#include <windows.h>
#endif

using json = nlohmann::json;

namespace browser {

// Per-command response timeout: browser ops (goto/click) use OP_TIMEOUT_SEC=30s
// in the worker; give the sidecar a little headroom.
static const long BROWSER_RESPONSE_TIMEOUT_MS = 60000L;
// One-shot availability probe timeout (seconds). Raised from 30s: the probe
// cold-launches a headless Edge per call (the worker's `available` path), which
// under real-desktop load can exceed 30s and spuriously report "unavailable" —
// the root of live runs being skipped with `browser probe did not run` (12.2).
// The Dart side waits 120s (sidecar_bridge browserAvailable isolation timeout).
static const long AVAILABLE_TIMEOUT_SEC = 60L;
// One-shot probe attempts before concluding unavailable: the first probe may
// time out under load; retry once before accepting a transient failure as fact.
static const int AVAILABLE_PROBE_ATTEMPTS = 2;

// ============================================================================
// Python availability (cached lazily, mirrors web_fetch's detect_python)
// ============================================================================

static bool g_python_available = false;
static bool g_python_checked = false;
#ifdef _WIN32
static const char* PYTHON_BINARIES[] = {"python", "python3", nullptr};
#else
static const char* PYTHON_BINARIES[] = {"python3", "python", nullptr};
#endif

static void detect_python() {
  if (g_python_checked) return;
  g_python_checked = true;
  for (int i = 0; PYTHON_BINARIES[i] != nullptr; ++i) {
    std::string cmd = std::string(PYTHON_BINARIES[i]) + " --version";
#ifdef _WIN32
    FILE* fp = _popen(cmd.c_str(), "r");
#else
    FILE* fp = popen(cmd.c_str(), "r");
#endif
    if (fp) {
      char buf[128] = {0};
      if (fgets(buf, sizeof(buf), fp) && buf[0] != '\0') {
        int ret = -1;
#ifdef _WIN32
        ret = _pclose(fp);
#else
        ret = pclose(fp);
#endif
        if (ret == 0) {
          g_python_available = true;
          LOG_INFO("browser: python detected: " + std::string(buf));
          return;
        }
      } else {
#ifdef _WIN32
        _pclose(fp);
#else
        pclose(fp);
#endif
      }
    }
  }
  LOG_WARN("browser: python not found on PATH");
}

// ============================================================================
// Script path resolution (browser_worker.py), mirroring web_fetch
// ============================================================================

static std::string resolve_script_path() {
#ifdef _WIN32
  char dll_path[MAX_PATH] = {0};
  HMODULE hModule = nullptr;
  static int dummy = 0;
  GetModuleHandleExA(
    GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
    (LPCSTR)&dummy, &hModule);
  if (hModule) GetModuleFileNameA(hModule, dll_path, sizeof(dll_path));
#else
  char dll_path[4096] = {0};
  FILE* maps = fopen("/proc/self/maps", "r");
  if (maps) {
    char line[4096];
    while (fgets(line, sizeof(line), maps)) {
      if (strstr(line, "sidecar.so") || strstr(line, "libsidecar")) {
        char* path_start = strchr(line, '/');
        if (path_start) {
          char* end = strchr(path_start, '\n');
          if (end) *end = '\0';
          snprintf(dll_path, sizeof(dll_path), "%s", path_start);
          break;
        }
      }
    }
    fclose(maps);
  }
#endif
  std::string dir;
  if (dll_path[0] != '\0') {
    dir = dll_path;
    size_t last_sep = dir.find_last_of("\\/");
    if (last_sep != std::string::npos) dir = dir.substr(0, last_sep);
  }
  const char* suffixes[] = {
    "/../scripts/browser_worker.py",
    "/scripts/browser_worker.py",
    "/../share/aliasagent/scripts/browser_worker.py",
    "/share/aliasagent/scripts/browser_worker.py",
  };
  for (const auto* suffix : suffixes) {
    std::string candidate = dir + suffix;
#ifdef _WIN32
    if (GetFileAttributesA(candidate.c_str()) != INVALID_FILE_ATTRIBUTES) return candidate;
#else
    FILE* f = fopen(candidate.c_str(), "r");
    if (f) { fclose(f); return candidate; }
#endif
  }
  const char* cwd_suffixes[] = {"scripts/browser_worker.py", "../scripts/browser_worker.py"};
  for (const char* c : cwd_suffixes) {
#ifdef _WIN32
    if (GetFileAttributesA(c) != INVALID_FILE_ATTRIBUTES) return c;
#else
    FILE* f = fopen(c, "r");
    if (f) { fclose(f); return c; }
#endif
  }
  LOG_WARN("browser: browser_worker.py not found");
  return "scripts/browser_worker.py";  // best guess; launch will fail if missing
}

// ============================================================================
// Persistent worker handle (Windows). Thread-unsafe globals are guarded by
// g_cmd_mutex for send_command; the stderr drain runnss on its own thread.
// ============================================================================

#ifdef _WIN32
static HANDLE g_proc = nullptr;
static HANDLE g_job = nullptr;
static HANDLE g_stdin_wr = nullptr;   // parent -> child stdin
static HANDLE g_stdout_rd = nullptr;  // child stdout -> parent
static HANDLE g_stderr_rd = nullptr;  // child stderr -> parent
static bool g_in_job = false;
static std::thread g_stderr_thread;
static std::atomic<bool> g_alive{false};
static bool g_ever_started = false;    // worker spawned at least once (session ever started)
static bool g_dead_reported = false;   // a dead session was surfaced once; next cmd reopens
static std::mutex g_cmd_mutex;

// Availability-probe cache (12.2): remember ONLY an authoritative success so a
// repeated probe never re-cold-launches a headless Edge. A `available:false`
// answer is deliberately NOT cached — it can be a genuine absence OR a transient
// load-induced cold-launch timeout the worker collapsed to false; caching it
// would permanently under-declare the tool (the 12.2 mistake this guards
// against). So g_probe_known is set only when the worker confirmed available.
static bool g_probe_known = false;
static bool g_probe_available = false;
static std::string g_probe_channel;

static bool worker_running() {
  if (g_proc == nullptr) return false;
  DWORD code = 0;
  if (!GetExitCodeProcess(g_proc, &code)) return false;
  return code == STILL_ACTIVE;
}

static void stop_worker() {
  g_alive = false;
  if (g_stdin_wr) { CloseHandle(g_stdin_wr); g_stdin_wr = nullptr; }  // EOF -> worker exits
  if (g_stderr_thread.joinable()) g_stderr_thread.join();
  if (g_proc && g_in_job) { TerminateJobObject(g_job, 1); }
  else if (g_proc) { TerminateProcess(g_proc, 1); }
  if (g_proc) { WaitForSingleObject(g_proc, 2000); CloseHandle(g_proc); g_proc = nullptr; }
  if (g_stdout_rd) { CloseHandle(g_stdout_rd); g_stdout_rd = nullptr; }
  if (g_stderr_rd) { CloseHandle(g_stderr_rd); g_stderr_rd = nullptr; }
  if (g_job) { CloseHandle(g_job); g_job = nullptr; }
  g_in_job = false;
}

// Process-exit cleanup for the persistent worker: if the long-lived stderr drain
// thread is never joined, its std::thread static destructor at DLL-unload calls
// std::terminate (or, if the worker's headed Edge lingers, blocks the process
// exit). The atexit handler closes the worker's stdin (worker exits) and joins
// the drain thread so the process terminates cleanly (measured: a headed-browser
// sidecar test hung on exit without this).
static void shutdown_worker_atexit() { stop_worker(); }

static void stderr_drain(HANDLE hPipe) {
  char buf[4096];
  DWORD avail = 0;
  while (true) {
    // Peek for available bytes; if the pipe closed (0 avail + no data) break.
    if (!PeekNamedPipe(hPipe, nullptr, 0, nullptr, &avail, nullptr)) break;
    if (avail == 0) { Sleep(30); if (!worker_running()) break; continue; }
    DWORD rd = 0;
    DWORD to_read = (avail < sizeof(buf) - 1) ? avail : sizeof(buf) - 1;
    if (!ReadFile(hPipe, buf, to_read, &rd, nullptr) || rd == 0) break;
    buf[rd] = '\0';
    // Route each line into sidecar.log VERBATIM so the machine-readable
    // `browser-record:` line appears intact for test attribution.
    std::string chunk(buf, rd);
    size_t nl;
    while ((nl = chunk.find('\n')) != std::string::npos) {
      std::string line = chunk.substr(0, nl);
      if (!line.empty() && line.back() == '\r') line.pop_back();
      if (!line.empty()) LOG_RAW(line);
      chunk.erase(0, nl + 1);
    }
    if (!chunk.empty()) LOG_RAW(chunk);
  }
}

// Read one complete line ('\n'-terminated JSON) from the worker's stdout.
// Returns false on timeout / process death / pipe error.
static bool read_response(std::string& out) {
  char buf[8192];
  std::string acc;
  auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(BROWSER_RESPONSE_TIMEOUT_MS);
  while (true) {
    DWORD avail = 0;
    if (!PeekNamedPipe(g_stdout_rd, nullptr, 0, nullptr, &avail, nullptr)) return false;
    if (avail > 0) {
      DWORD rd = 0;
      DWORD to_read = (avail < sizeof(buf) - 1) ? avail : sizeof(buf) - 1;
      if (!ReadFile(g_stdout_rd, buf, to_read, &rd, nullptr) || rd == 0) return false;
      acc.append(buf, rd);
      size_t nl = acc.find('\n');
      while (nl != std::string::npos) {
        // Return the first line; keep any extra (shouldn't happen — one line per cmd).
        out = acc.substr(0, nl);
        return true;
      }
    } else {
      if (!worker_running()) return false;
      if (std::chrono::steady_clock::now() >= deadline) { LOG_WARN("browser: response timeout"); return false; }
      Sleep(30);
    }
  }
}

// Task 12.13: the AliasAgent window's own rect, so the worker can place the
// headed browser clear of it. Measured 2026-09-11 over 237 frames: with the
// browser sitting over the app only 10.5% of frames showed the app at all, and
// while the browser was on about:blank the app's rect was pure white with no
// text -- which reads exactly like "the app went white / froze". Moving the
// browser beside the app keeps it user-visible (spec L6) without any
// bring-to-front (spec L30-31). Returns "L,T,W,H", or "" when the window is not
// found (the worker then keeps Playwright's default placement).
static std::string app_window_rect() {
#ifdef _WIN32
  struct Ctx {
    DWORD pid;
    RECT rect;
    bool found;
  };
  RECT zero = {0, 0, 0, 0};
  Ctx ctx{GetCurrentProcessId(), zero, false};
  EnumWindows(
      [](HWND hwnd, LPARAM lp) -> BOOL {
        Ctx* c = reinterpret_cast<Ctx*>(lp);
        DWORD pid = 0;
        GetWindowThreadProcessId(hwnd, &pid);
        if (pid != c->pid) return TRUE;
        char cls[64] = {0};
        if (GetClassNameA(hwnd, cls, sizeof(cls) - 1) == 0) return TRUE;
        if (std::string(cls) != "FLUTTER_RUNNER_WIN32_WINDOW") return TRUE;
        RECT r = {0, 0, 0, 0};
        if (!GetWindowRect(hwnd, &r)) return TRUE;
        if (r.right - r.left <= 0 || r.bottom - r.top <= 0) return TRUE;
        c->rect = r;
        c->found = true;
        return FALSE;  // stop at the first match
      },
      reinterpret_cast<LPARAM>(&ctx));
  if (!ctx.found) return "";
  char buf[96];
  std::snprintf(buf, sizeof(buf), "%ld,%ld,%ld,%ld", ctx.rect.left, ctx.rect.top,
                ctx.rect.right - ctx.rect.left, ctx.rect.bottom - ctx.rect.top);
  return std::string(buf);
#else
  return "";
#endif
}

static bool start_worker() {
  stop_worker();
  LOG_INFO("browser: starting persistent worker");

  HANDLE hStdinRd = nullptr, hStdinWr = nullptr;
  HANDLE hStdOutRd = nullptr, hStdOutWr = nullptr;
  HANDLE hStdErrRd = nullptr, hStdErrWr = nullptr;
  SECURITY_ATTRIBUTES sa = {sizeof(sa), nullptr, TRUE};
  if (!CreatePipe(&hStdinRd, &hStdinWr, &sa, 0) ||
      !CreatePipe(&hStdOutRd, &hStdOutWr, &sa, 0) ||
      !CreatePipe(&hStdErrRd, &hStdErrWr, &sa, 0)) {
    LOG_WARN("browser: pipe creation failed");
    return false;
  }
  SetHandleInformation(hStdinWr, HANDLE_FLAG_INHERIT, 0);
  SetHandleInformation(hStdOutRd, HANDLE_FLAG_INHERIT, 0);
  SetHandleInformation(hStdErrRd, HANDLE_FLAG_INHERIT, 0);

  STARTUPINFOA si = {};
  si.cb = sizeof(si);
  si.hStdInput = hStdinRd;
  si.hStdOutput = hStdOutWr;
  si.hStdError = hStdErrWr;
  si.dwFlags |= STARTF_USESTDHANDLES;

  HANDLE hJob = CreateJobObjectA(nullptr, nullptr);
  if (hJob) {
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION jeli = {};
    jeli.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    SetInformationJobObject(hJob, JobObjectExtendedLimitInformation, &jeli, sizeof(jeli));
  }

  std::string python_bin;
  for (int i = 0; PYTHON_BINARIES[i] != nullptr; ++i) {
    std::string cmd = std::string(PYTHON_BINARIES[i]) + " --version";
    FILE* fp = _popen(cmd.c_str(), "r");
    if (fp) {
      char b[128] = {0};
      bool ok = fgets(b, sizeof(b), fp) && b[0] != '\0';
      int ret = _pclose(fp);
      if (ok && ret == 0) { python_bin = PYTHON_BINARIES[i]; break; }
    }
  }
  if (python_bin.empty()) {
    LOG_WARN("browser: python not available");
    CloseHandle(hStdinRd); CloseHandle(hStdinWr);
    CloseHandle(hStdOutRd); CloseHandle(hStdOutWr);
    CloseHandle(hStdErrRd); CloseHandle(hStdErrWr);
    if (hJob) CloseHandle(hJob);
    return false;
  }

  std::string script = resolve_script_path();
  // Task 12.13: tell the worker where our window is so it can place the headed
  // browser clear of it (the worker falls back to Playwright's default when the
  // rect is empty).
  std::vector<std::string> worker_argv{python_bin, script};
  const std::string app_rect = app_window_rect();
  if (!app_rect.empty()) {
    worker_argv.push_back("--app-rect=" + app_rect);
    LOG_INFO("browser: app window rect " + app_rect);
  }
  std::string args = subprocess::build_command_line(worker_argv);
  std::vector<char> cmd_buf(args.begin(), args.end());
  cmd_buf.push_back('\0');

  PROCESS_INFORMATION pi = {};
  BOOL ok = CreateProcessA(nullptr, cmd_buf.data(), nullptr, nullptr, TRUE,
                           CREATE_NO_WINDOW, nullptr, nullptr, &si, &pi);
  CloseHandle(hStdinRd);
  CloseHandle(hStdOutWr);
  CloseHandle(hStdErrWr);
  if (!ok) {
    LOG_WARN("browser: failed to create worker process");
    CloseHandle(hStdinWr); CloseHandle(hStdOutRd); CloseHandle(hStdErrRd);
    if (hJob) CloseHandle(hJob);
    return false;
  }
  bool in_job = false;
  if (hJob) in_job = AssignProcessToJobObject(hJob, pi.hProcess) != 0;
  CloseHandle(pi.hThread);

  g_proc = pi.hProcess;
  g_job = hJob;
  g_stdin_wr = hStdinWr;
  g_stdout_rd = hStdOutRd;
  g_stderr_rd = hStdErrRd;
  g_in_job = in_job;
  g_alive = true;
  // Important: the child owns hStdInWr / hStdOutRd / hStdErrWr (closed above).
  g_stderr_thread = std::thread(stderr_drain, hStdErrRd);
  // Ensure the persistent worker + drain thread are torn down at process exit,
  // otherwise the joinable std::thread static destructor blocks/terminates the
  // process (measured: a headed-browser test hung on exit before this).
  static bool atexit_registered = false;
  if (!atexit_registered) {
    atexit_registered = true;
    std::atexit(shutdown_worker_atexit);
  }
  LOG_INFO("browser: worker started (pid handle set)");
  return true;
}

static std::string send_command(const json& cmd) {
  std::lock_guard<std::mutex> lock(g_cmd_mutex);
  if (!g_alive || !worker_running()) {
    // Worker died mid-command (race after run_browser_op's ensure): surface a
    // detectable failure once (never silently restart). The next command reopens.
    LOG_WARN("browser: worker not running on command");
    stop_worker();
    g_dead_reported = true;  // the next command is an explicit reopen, not a restart
    json resp;
    resp["ok"] = false;
    resp["dead"] = true;
    resp["needs_relaunch"] = true;
    resp["error"] = "browser session not connected - issue the command again to reopen";
    return resp.dump();
  }
  std::string cmd_str = cmd.dump() + "\n";
  DWORD written = 0;
  if (!WriteFile(g_stdin_wr, cmd_str.data(), (DWORD)cmd_str.size(), &written, nullptr)) {
    LOG_WARN("browser: failed to write command to worker");
    stop_worker();
    g_dead_reported = true;  // surfaced once; the next command is the explicit reopen
    return "{\"ok\":false,\"error\":\"browser worker write failed\",\"dead\":true}";
  }
  std::string line;
  if (!read_response(line)) {
    // Stuck / dead worker: kill so a fresh one is spawned on the next command.
    stop_worker();
    g_dead_reported = true;  // surfaced once; the next command is the explicit reopen
    return "{\"ok\":false,\"error\":\"browser operation timed out or worker died\",\"dead\":true}";
  }
  return line;
}

// Ensure a worker for an op WITHOUT silently hiding a dead session:
//   - first command ever: this IS the session startup (open semantics) -> spawn.
//   - worker died between commands: surface the failure ONCE (dead:true) and let
//     the AI explicitly reopen by issuing the command again (no silent restart).
//   - after a dead was surfaced: the AI's next command is the explicit reopen ->
//     spawn a fresh worker and proceed.
// Returns "" with out_err set on an unavailable stack; otherwise the worker's
// response JSON (a dead:true error on the first post-death command).
static std::string run_browser_op(const json& cmd, std::string& out_err) {
  if (!g_alive || !worker_running()) {
    if (!g_ever_started) {
      // Session startup on the first command.
      g_ever_started = true;
      g_dead_reported = false;
      if (!start_worker()) {
        out_err = "browser unavailable (python/playwright/script path)";
        LOG_WARN("browser: op rejected, worker not startable: " + out_err);
        return "";
      }
    } else if (!g_dead_reported) {
      // Watchdog: never silently restart a dead session. Report it once.
      LOG_WARN("browser: worker died between commands - surfacing dead:true once");
      g_dead_reported = true;
      json resp;
      resp["ok"] = false;
      resp["dead"] = true;
      resp["needs_relaunch"] = true;
      resp["error"] = "browser session not connected - issue the command again to reopen";
      return resp.dump();
    } else {
      // AI-explicit reopen (the dead was already surfaced).
      LOG_INFO("browser: AI-explicit reopen (worker was dead)");
      g_dead_reported = false;
      if (!start_worker()) {
        out_err = "browser unavailable (python/playwright/script path)";
        LOG_WARN("browser: reopen failed, worker not startable: " + out_err);
        return "";
      }
    }
  }
  return send_command(cmd);
}

// Test hook: tear down the persistent worker and reset session state.
//   was_started=false -> fresh state (the next op is a session startup).
//   was_started=true  -> simulate a session that HAD started then died (the next
//                        op is a watchdog dead-detection: dead:true once, then the
//                        following op is the AI's explicit reopen).
void reset_session(bool was_started) {
  stop_worker();
  g_ever_started = was_started;
  g_dead_reported = false;
}

#else  // !_WIN32 — graceful degradation: browser tools not supported here.

static std::string browser_unsupported() {
  json resp;
  resp["ok"] = false;
  resp["error"] = "browser tools are only supported on Windows (Playwright + Edge)";
  resp["available"] = false;
  return resp.dump();
}

static std::string run_browser_op(const json& cmd, std::string& out_err) {
  out_err = "browser tools not supported on this platform";
  return "";
}

// Test hook: no-op on non-Windows (browser tool unsupported here). Declared in
// browser.h so the test executable links on every platform.
void reset_session(bool was_started) {
  (void)was_started;
}

#endif // _WIN32

// ============================================================================
// Public API
// ============================================================================

std::string browser_available() {
#ifdef _WIN32
  detect_python();
  if (!g_python_available) {
    return "{\"ok\":true,\"available\":false,\"error\":\"python not found\"}";
  }
  if (g_probe_known) {
    json cached;
    cached["ok"] = true;
    cached["available"] = g_probe_available;
    cached["channel"] = g_probe_channel;
    return cached.dump();
  }
  std::string script = resolve_script_path();
  std::string python_bin;
  for (int i = 0; PYTHON_BINARIES[i] != nullptr; ++i) {
    std::string cmd = std::string(PYTHON_BINARIES[i]) + " --version";
    FILE* fp = _popen(cmd.c_str(), "r");
    if (fp) {
      char b[128] = {0};
      bool ok = fgets(b, sizeof(b), fp) && b[0] != '\0';
      int ret = _pclose(fp);
      if (ok && ret == 0) { python_bin = PYTHON_BINARIES[i]; break; }
    }
  }
  if (python_bin.empty()) {
    return "{\"ok\":true,\"available\":false,\"error\":\"python not found\"}";
  }
  json req;
  req["cmd"] = "available";
  // The one-shot probe cold-launches a headless Edge; under load that can cross
  // the timeout (a transient condition, NOT "stack absent"). Retry once before
  // concluding the stack is unusable. A genuine absence — the worker answering
  // ok:true/available:false — is authoritative and cached, so a repeated probe
  // never re-pays the cold-launch cost (12.2).
  std::string last_error = "browser probe did not run";
  for (int attempt = 0; attempt < AVAILABLE_PROBE_ATTEMPTS; ++attempt) {
    subprocess::Options opts;
    opts.stdin_data = req.dump() + "\n";
    opts.timeout_seconds = AVAILABLE_TIMEOUT_SEC;
    subprocess::Result res = subprocess::run({python_bin, script}, opts);
    if (!res.started || res.timed_out) {
      last_error = res.timed_out ? "browser probe timed out" : "browser probe did not run";
      continue;
    }
    if (res.stdout_data.empty()) { last_error = "browser probe empty"; continue; }
    // Strip trailing newline.
    std::string out = res.stdout_data;
    while (!out.empty() && (out.back() == '\n' || out.back() == '\r')) out.pop_back();
    // The worker already returns {"ok":true,"available":bool,...} — pass through.
    // Cache ONLY the (expensive) SUCCESS so a repeated probe never re-launches a
    // cold headless Edge (12.2 cost reduction). An available:false is NOT cached:
    // it may be a genuine absence, OR a transient load-induced slow cold-launch
    // that the worker's bounded launch timeout collapsed to available:false (the
    // exact condition 12.2 targets). Caching a transient false would permanently
    // under-declare the browser tool for the run — so re-probe instead.
    try {
      auto parsed = json::parse(out);
      if (parsed.contains("ok") && parsed["ok"].get<bool>()) {
        const bool avail = parsed.value("available", false);
        if (avail) {
          g_probe_known = true;
          g_probe_available = true;
          g_probe_channel = parsed.value("channel", "");
          return parsed.dump();
        }
        last_error = parsed.value("error", "browser not usable");
        continue;  // re-probe (could be a transient load timeout, not real absence)
      }
      last_error = "browser probe invalid";
    } catch (...) { last_error = "browser probe invalid"; }
  }
  return json{{"ok", true}, {"available", false}, {"error", last_error}}.dump();
#else
  return "{\"ok\":true,\"available\":false,\"error\":\"browser tools not supported on this platform\"}";
#endif
}

static std::string browser_op_body(const char* request_json, const char* cmd) {
#ifdef _WIN32
  json worker_cmd;
  worker_cmd["cmd"] = cmd;
  std::string err_str = "{}";
  try {
    if (request_json && request_json[0] != '\0') {
      auto req = json::parse(request_json);
      if (req.is_object()) {
        for (auto it = req.begin(); it != req.end(); ++it) {
          worker_cmd[it.key()] = it.value();
        }
      }
    }
    worker_cmd["cmd"] = cmd;  // cmd wins over any user-supplied key.
    std::string out_err;
    std::string resp = run_browser_op(worker_cmd, out_err);
    if (!out_err.empty()) {
      json r;
      r["ok"] = false;
      r["error"] = out_err;
      return r.dump();
    }
    return resp.empty() ? "{\"ok\":false,\"error\":\"browser call returned empty\"}" : resp;
  } catch (const std::exception& e) {
    json r;
    r["ok"] = false;
    r["error"] = std::string("browser: ") + e.what();
    return r.dump();
  }
#else
  (void)request_json; (void)cmd;
  return browser_unsupported();
#endif
}

std::string browser_navigate(const std::string& request_json) {
  return browser_op_body(request_json.c_str(), "navigate");
}
std::string browser_click(const std::string& request_json) {
  return browser_op_body(request_json.c_str(), "click");
}
std::string browser_type(const std::string& request_json) {
  return browser_op_body(request_json.c_str(), "type");
}
std::string browser_snapshot(const std::string& request_json) {
  return browser_op_body(request_json.c_str(), "snapshot");
}

} // namespace browser
