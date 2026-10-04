#include "subprocess.h"
#include <algorithm>
#include <chrono>

#ifdef _WIN32
#include <windows.h>
#else
#include <unistd.h>
#include <sys/wait.h>
#include <signal.h>
#include <sys/select.h>
#include <sys/time.h>
#include <fcntl.h>
extern char** environ;
#endif

namespace subprocess {

/// 生效的超时毫秒数。毫秒字段大于 0 时优先（模型给的超时是毫秒数，整秒装不下）；
/// 否则用既有的整秒字段。两个调用分支都用它，保证 Windows 与 POSIX 一致。
static long long effective_timeout_ms(const Options& opts) {
  if (opts.timeout_ms > 0) return opts.timeout_ms;
  return static_cast<long long>(opts.timeout_seconds) * 1000;
}

/// 键名是否相等：Windows 的环境变量名大小写不敏感（`Path` 与 `PATH` 是同一个），
/// 并入时按这个规则去重，免得同一个块里出现两个同名变量。
static bool key_equals(const std::string& a, const std::string& b) {
  if (a.size() != b.size()) return false;
  for (size_t i = 0; i < a.size(); ++i) {
    char x = a[i], y = b[i];
    if (x >= 'a' && x <= 'z') x = static_cast<char>(x - 'a' + 'A');
    if (y >= 'a' && y <= 'z') y = static_cast<char>(y - 'a' + 'A');
    if (x != y) return false;
  }
  return true;
}

// ============================================================================
// Windows command-line construction (CommandLineToArgvW quoting rules)
// ============================================================================

/// Quote a single argv element for a Windows command line.
/// Mirrors CommandLineToArgvW semantics: spaces/tabs force quoting; embedded
/// quotes are backslash-escaped; backslashes before a quote are doubled;
/// trailing backslashes before the closing quote are doubled.
static std::string quote_arg(const std::string& arg) {
  if (arg.empty()) return "\"\"";
  const bool needs_quotes = arg.find_first_of(" \t") != std::string::npos ||
                            arg.find('"') != std::string::npos;
  if (!needs_quotes) return arg;

  std::string out = "\"";
  size_t backslashes = 0;
  for (char c : arg) {
    if (c == '\\') {
      backslashes++;
    } else if (c == '"') {
      out.append(backslashes * 2, '\\');
      backslashes = 0;
      out += "\\\"";
    } else {
      out.append(backslashes, '\\');
      backslashes = 0;
      out += c;
    }
  }
  out.append(backslashes * 2, '\\');
  out += '"';
  return out;
}

std::string build_command_line(const std::vector<std::string>& argv) {
  std::string line;
  for (size_t i = 0; i < argv.size(); ++i) {
    if (i > 0) line += ' ';
    line += quote_arg(argv[i]);
  }
  return line;
}

#ifdef _WIN32

/// 最近一次"起进程失败"的 `GetLastError()` 与当时有没有带自定义环境块。
/// 只给测试与排错用（`Docs/known-bugs.md` 里记着"调用方拿不到失败原因"这条缺陷）。
DWORD g_last_start_error = 0;
bool g_last_start_had_env = false;

/// Same quoting rule as quote_arg, on UTF-16 code units. Kept as a separate
/// function (rather than converting the byte result) so that a wide code unit
/// is never mistaken for two ANSI bytes.
static std::wstring quote_arg_wide(const std::wstring& arg) {
  if (arg.empty()) return L"\"\"";
  const bool needs_quotes = arg.find_first_of(L" \t") != std::wstring::npos ||
                            arg.find(L'"') != std::wstring::npos;
  if (!needs_quotes) return arg;

  std::wstring out = L"\"";
  size_t backslashes = 0;
  for (wchar_t c : arg) {
    if (c == L'\\') {
      backslashes++;
    } else if (c == L'"') {
      out.append(backslashes * 2, L'\\');
      backslashes = 0;
      out += L"\\\"";
    } else {
      out.append(backslashes, L'\\');
      backslashes = 0;
      out += c;
    }
  }
  out.append(backslashes * 2, L'\\');
  out += L'"';
  return out;
}

/// UTF-8 → UTF-16。Invalid input yields an empty result (caller treats that as
/// "cannot start", which is honest: the bytes cannot be put on a wide command
/// line without inventing characters).
std::wstring utf8_to_wide(const std::string& s) {
  if (s.empty()) return std::wstring();
  int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s.data(),
                              static_cast<int>(s.size()), nullptr, 0);
  if (n <= 0) return std::wstring();
  std::wstring out(static_cast<size_t>(n), L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s.data(),
                      static_cast<int>(s.size()), out.data(), n);
  return out;
}

std::wstring build_command_line_wide(const std::vector<std::string>& argv) {  std::wstring line;
  for (size_t i = 0; i < argv.size(); ++i) {
    if (i > 0) line += L' ';
    const std::wstring w = utf8_to_wide(argv[i]);
    if (w.empty() && !argv[i].empty()) return std::wstring();  // 非法 UTF-8
    line += quote_arg_wide(w);
  }
  return line;
}

/// 取本进程的完整环境块（`KEY=VALUE` 一串，UTF-16），并入要注入的项之后返回。
/// **全程走 UTF-16，不做"宽→UTF-8→宽"的来回转换**：父环境里本来就可能含非 ASCII
/// 的值，来回转一次既多此一举，也给"转失败"留下把整块搞坏的机会。
/// **也不做"重建一份全局环境"这种事**：正常 Windows 程序就是继承父进程的环境，
/// 读注册表重拼会漏掉启动后的变更、还会与所有正常程序的行为不一致。
static std::vector<wchar_t> build_environment_block(
    const std::vector<std::pair<std::string, std::string>>& extra) {
  if (extra.empty()) return {};  // 空 = 传 nullptr，走最干净的继承路径

  std::vector<std::wstring> merged;  // 每条是 "KEY=VALUE"
  if (LPWCH block = GetEnvironmentStringsW()) {
    for (LPWCH p = block; *p;) {
      const std::wstring entry(p);
      p += entry.size() + 1;
      if (entry.find(L'=') != std::wstring::npos) merged.push_back(entry);
    }
    FreeEnvironmentStringsW(block);
  }

  for (const auto& kv : extra) {
    const std::string pair = kv.first + "=" + kv.second;
    const std::wstring w = utf8_to_wide(pair);
    if (w.empty() && !pair.empty()) continue;  // 要注入的值本身非法，跳过这一项
    const std::wstring key = utf8_to_wide(kv.first);
    bool replaced = false;
    for (auto& existing : merged) {
      const size_t eq = existing.find(L'=');
      const std::wstring existing_key = eq == std::wstring::npos ? existing : existing.substr(0, eq);
      // 键名按 Windows 规则大小写不敏感：先把两边都折成大写再比
      std::wstring a = existing_key, b = key;
      for (auto& c : a) c = static_cast<wchar_t>(towupper(c));
      for (auto& c : b) c = static_cast<wchar_t>(towupper(c));
      if (a == b) {
        existing = w;  // 同名覆盖，不新增第二份
        replaced = true;
        break;
      }
    }
    if (!replaced) merged.push_back(w);
  }

  std::vector<wchar_t> out;
  for (const auto& entry : merged) {
    out.insert(out.end(), entry.begin(), entry.end());
    out.push_back(L'\0');
  }
  out.push_back(L'\0');  // 整块以双 NUL 结束
  return out;
}

/// 把 UTF-8 的 argv + 工作目录拼成一条宽字符命令行并启动进程。
/// 返回的 HANDLE 等仍由调用方按原逻辑处理；本函数只负责"启动"这一步。
/// 失败时 started=false（具体的错误原因目前不向外传，见 known-bugs）。
static bool start_process_wide(const std::vector<std::string>& argv,
                               const std::string& cwd, STARTUPINFOW* si,
                               PROCESS_INFORMATION* pi,
                               const std::vector<std::pair<std::string, std::string>>& extra_env) {
  std::wstring wide_cmd = build_command_line_wide(argv);
  if (wide_cmd.empty() && !argv.empty()) return false;
  std::vector<wchar_t> cmd_buf(wide_cmd.begin(), wide_cmd.end());
  cmd_buf.push_back(L'\0');
  std::wstring wide_cwd;
  const wchar_t* cwd_ptr = nullptr;
  if (!cwd.empty()) {
    wide_cwd = utf8_to_wide(cwd);
    if (wide_cwd.empty()) return false;
    cwd_ptr = wide_cwd.c_str();
  }
  std::vector<wchar_t> env_block = build_environment_block(extra_env);
  LPVOID env_ptr = env_block.empty() ? nullptr : env_block.data();
  // CREATE_UNICODE_ENVIRONMENT 不是可选的：不带上它，我们自己拼的宽字符环境块会被
  // 当成 ANSI 解释、校验不过，CreateProcessW 直接以 ERROR_INVALID_PARAMETER(87) 失败
  // （实测：同样的块，不带这个标志 err=87，带上 err=0）。
  const DWORD flags = CREATE_NO_WINDOW |
                      (env_ptr ? CREATE_UNICODE_ENVIRONMENT : 0);
  const BOOL started = CreateProcessW(nullptr, cmd_buf.data(), nullptr, nullptr, TRUE,
                                      flags, env_ptr, cwd_ptr, si, pi);
  if (!started) {
    // 起不来的原因目前只在这里记下（kn-1.7：调用方拿不到，见 Docs/known-bugs.md）
    g_last_start_error = GetLastError();
    g_last_start_had_env = env_ptr != nullptr;
  }
  return started != 0;
}

#endif  // _WIN32

// ============================================================================
// Windows implementation
// ============================================================================

#ifdef _WIN32

Result run(const std::vector<std::string>& argv, const Options& opts) {
  Result res;
  if (argv.empty()) return res;

  HANDLE hStdInRd = nullptr, hStdInWr = nullptr;
  HANDLE hStdOutRd = nullptr, hStdOutWr = nullptr;
  HANDLE hStdErrRd = nullptr, hStdErrWr = nullptr;
  SECURITY_ATTRIBUTES sa = {sizeof(sa), nullptr, TRUE};

  if (!CreatePipe(&hStdInRd, &hStdInWr, &sa, 0) ||
      !CreatePipe(&hStdOutRd, &hStdOutWr, &sa, 0) ||
      !CreatePipe(&hStdErrRd, &hStdErrWr, &sa, 0)) {
    return res;
  }
  SetHandleInformation(hStdInWr, HANDLE_FLAG_INHERIT, 0);
  SetHandleInformation(hStdOutRd, HANDLE_FLAG_INHERIT, 0);
  SetHandleInformation(hStdErrRd, HANDLE_FLAG_INHERIT, 0);

  STARTUPINFOW si = {};
  si.cb = sizeof(si);
  si.hStdInput = hStdInRd;
  si.hStdOutput = hStdOutWr;
  si.hStdError = hStdErrWr;
  si.dwFlags |= STARTF_USESTDHANDLES;

  // Job Object: kills the whole process tree when the job closes / is terminated.
  HANDLE hJob = CreateJobObjectW(nullptr, nullptr);
  if (hJob) {
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION jeli = {};
    jeli.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    SetInformationJobObject(hJob, JobObjectExtendedLimitInformation, &jeli, sizeof(jeli));
  }

  PROCESS_INFORMATION pi = {};
  const bool ok = start_process_wide(argv, opts.cwd, &si, &pi, opts.extra_env);

  // Parent closes the write ends of stdout/stderr and read end of stdin so the
  // child owns the write ends (EOF propagates correctly).
  CloseHandle(hStdInRd);
  CloseHandle(hStdOutWr);
  CloseHandle(hStdErrWr);

  if (!ok) {
    CloseHandle(hStdInWr);
    CloseHandle(hStdOutRd);
    CloseHandle(hStdErrRd);
    if (hJob) CloseHandle(hJob);
    return res; // started=false
  }

  res.started = true;
  // Track whether the child is actually inside our job: when the host process
  // is itself inside a job (CI, sandboxed shell, Task Scheduler), CreateProcess
  // inherits that job and AssignProcessToJobObject fails with
  // ERROR_ACCESS_DENIED — TerminateJobObject on our empty job would then kill
  // nothing. Fall back to TerminateProcess on the direct child in that case.
  bool in_job = false;
  if (hJob) {
    in_job = AssignProcessToJobObject(hJob, pi.hProcess) != 0;
  }
  CloseHandle(pi.hThread);

  // Write request data to stdin, then close write end.
  if (!opts.stdin_data.empty()) {
    DWORD written = 0;
    WriteFile(hStdInWr, opts.stdin_data.data(), (DWORD)opts.stdin_data.size(), &written, nullptr);
  }
  CloseHandle(hStdInWr);

  auto start_time = std::chrono::steady_clock::now();
  bool handler_stop = false;
  // 生效超时按毫秒算（模型给的毫秒数不能被整秒截掉）；每轮最多睡 100 毫秒是为了
  // 及时把管道里的输出捞出来，不是超时精度 —— 唤醒后立刻按毫秒核对是否到点。
  const long long timeout_ms = effective_timeout_ms(opts);

  auto drain = [&](HANDLE hPipe, bool is_stdout) {
    DWORD avail = 0;
    while (PeekNamedPipe(hPipe, nullptr, 0, nullptr, &avail, nullptr) && avail > 0) {
      char buf[4096];
      DWORD rd = 0;
      DWORD to_read = (avail < sizeof(buf) - 1) ? avail : sizeof(buf) - 1;
      if (!ReadFile(hPipe, buf, to_read, &rd, nullptr) || rd == 0) break;
      if (is_stdout && opts.on_stdout_chunk) {
        if (opts.on_stdout_chunk(std::string(buf, rd))) {
          handler_stop = true;
          break;
        }
      } else if (is_stdout) {
        res.stdout_data.append(buf, rd);
      } else {
        res.stderr_data.append(buf, rd);
      }
    }
  };

  while (true) {
    drain(hStdOutRd, true);
    drain(hStdErrRd, false);

    // 睡到"下一个 100 毫秒的检查点"或"超时时刻"，谁先到睡谁。
    const long long left_ms = timeout_ms - std::chrono::duration_cast<std::chrono::milliseconds>(
                                             std::chrono::steady_clock::now() - start_time)
                                             .count();
    DWORD wait_slice = left_ms <= 0 ? 0
                                    : static_cast<DWORD>(left_ms < 100 ? left_ms : 100);

    if (handler_stop) {
      // Stream consumer decided we have enough — kill the process tree.
      if (in_job) TerminateJobObject(hJob, 1);
      else TerminateProcess(pi.hProcess, 1);
      WaitForSingleObject(pi.hProcess, 2000);
      drain(hStdOutRd, true);
      drain(hStdErrRd, false);
      res.stopped_early = true;
      break;
    }

    DWORD wr = WaitForSingleObject(pi.hProcess, wait_slice);
    if (wr == WAIT_OBJECT_0) {
      // Process exited — final drain to capture remaining buffered data.
      drain(hStdOutRd, true);
      drain(hStdErrRd, false);
      break;
    }

    const long long elapsed_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
      std::chrono::steady_clock::now() - start_time).count();
    if (elapsed_ms >= timeout_ms) {
      res.timed_out = true;
      if (in_job) TerminateJobObject(hJob, 1);
      else TerminateProcess(pi.hProcess, 1);
      WaitForSingleObject(pi.hProcess, 2000);
      drain(hStdOutRd, true);
      drain(hStdErrRd, false);
      break;
    }
  }

  DWORD exit_code = 0;
  GetExitCodeProcess(pi.hProcess, &exit_code);
  res.exit_code = static_cast<int>(exit_code);

  CloseHandle(hStdOutRd);
  CloseHandle(hStdErrRd);
  CloseHandle(pi.hProcess);
  if (hJob) CloseHandle(hJob);
  return res;
}

#else

// ============================================================================
// POSIX implementation
// ============================================================================

/// 把要注入的项并进 `environ`，得到一份完整的 `execv` 环境。与 Windows 分支同一条
/// 规矩：**并入不是替换**（PATH 等必须留给子进程），键名大小写不敏感去重。
static std::vector<char*> build_posix_env(
    const std::vector<std::pair<std::string, std::string>>& extra) {
  std::vector<char*> envp;
  extern char** environ;
  for (char** e = environ; e && *e; ++e) {
    const std::string entry(*e);
    const size_t eq = entry.find('=');
    if (eq != std::string::npos && !extra.empty()) {
      bool overridden = false;
      for (const auto& kv : extra) {
        if (key_equals(entry.substr(0, eq), kv.first)) {
          overridden = true;
          break;
        }
      }
      if (overridden) continue;  // 同名旧项丢掉，改用注入的那份
    }
    envp.push_back(*e);
  }
  // 注入项需要活到 execv 之后，这里用静态存储（fork 之后、exec 之前不会有别的线程）
  static std::vector<std::string> injected;
  injected.clear();
  for (const auto& kv : extra) injected.push_back(kv.first + "=" + kv.second);
  for (auto& s : injected) envp.push_back(const_cast<char*>(s.c_str()));
  envp.push_back(nullptr);
  return envp;
}

Result run(const std::vector<std::string>& argv, const Options& opts) {
  Result res;
  if (argv.empty()) return res;

  std::vector<char*> cargv;
  cargv.reserve(argv.size() + 1);
  for (const auto& a : argv) cargv.push_back(const_cast<char*>(a.c_str()));
  cargv.push_back(nullptr);

  int pipe_stdin[2], pipe_stdout[2], pipe_stderr[2];
  if (pipe(pipe_stdin) != 0 || pipe(pipe_stdout) != 0 || pipe(pipe_stderr) != 0) {
    return res;
  }

  pid_t pid = fork();
  if (pid < 0) {
    close(pipe_stdin[0]); close(pipe_stdin[1]);
    close(pipe_stdout[0]); close(pipe_stdout[1]);
    close(pipe_stderr[0]); close(pipe_stderr[1]);
    return res;
  }

  if (pid == 0) {
    // Child: redirect stdin/stdout/stderr, exec argv directly (no shell).
    dup2(pipe_stdin[0], STDIN_FILENO);
    dup2(pipe_stdout[1], STDOUT_FILENO);
    dup2(pipe_stderr[1], STDERR_FILENO);
    close(pipe_stdin[1]); close(pipe_stdout[0]); close(pipe_stderr[0]);
    setpgid(0, 0);
    if (!opts.cwd.empty()) chdir(opts.cwd.c_str());
    if (opts.extra_env.empty()) {
      execv(cargv[0], cargv.data());
    } else {
      std::vector<char*> envp = build_posix_env(opts.extra_env);
      execve(cargv[0], cargv.data(), envp.data());
    }
    _exit(127);  // exec failed
  }

  // Parent
  close(pipe_stdin[0]);
  close(pipe_stdout[1]);
  close(pipe_stderr[1]);
  res.started = true;

  if (!opts.stdin_data.empty()) {
    ssize_t w = write(pipe_stdin[1], opts.stdin_data.data(), opts.stdin_data.size());
    (void)w;
  }
  close(pipe_stdin[1]);

  auto start = std::chrono::steady_clock::now();
  bool handler_stop = false;
  bool stdout_open = true;
  bool stderr_open = true;
  int status = 0;

  while (true) {
    const long long left_ms = effective_timeout_ms(opts) -
                              std::chrono::duration_cast<std::chrono::milliseconds>(
                                  std::chrono::steady_clock::now() - start).count();
    if (left_ms <= 0) {
      res.timed_out = true;
      break;
    }

    fd_set fds;
    FD_ZERO(&fds);
    if (stdout_open) FD_SET(pipe_stdout[0], &fds);
    if (stderr_open) FD_SET(pipe_stderr[0], &fds);
    int maxfd = std::max(stdout_open ? pipe_stdout[0] : -1,
                         stderr_open ? pipe_stderr[0] : -1) + 1;

    struct timeval tv;
    tv.tv_sec = static_cast<time_t>(left_ms / 1000);
    tv.tv_usec = static_cast<suseconds_t>((left_ms % 1000) * 1000);

    int sel_ret = select(maxfd, &fds, nullptr, nullptr, &tv);
    if (sel_ret < 0) break;
    if (sel_ret == 0) { res.timed_out = true; break; }

    char buf[4096];
    if (stdout_open && FD_ISSET(pipe_stdout[0], &fds)) {
      ssize_t n = read(pipe_stdout[0], buf, sizeof(buf) - 1);
      if (n <= 0) {
        stdout_open = false;  // EOF
      } else if (opts.on_stdout_chunk) {
        if (opts.on_stdout_chunk(std::string(buf, n))) handler_stop = true;
      } else {
        res.stdout_data.append(buf, n);
      }
    }
    if (stderr_open && FD_ISSET(pipe_stderr[0], &fds)) {
      ssize_t n = read(pipe_stderr[0], buf, sizeof(buf) - 1);
      if (n <= 0) {
        stderr_open = false;  // EOF
      } else {
        res.stderr_data.append(buf, n);
      }
    }

    if (handler_stop) {
      res.stopped_early = true;
      break;
    }

    // Both output pipes at EOF → the child is about to exit; reap it.
    if (!stdout_open && !stderr_open) {
      if (waitpid(pid, &status, WNOHANG) == pid) break;
    }
  }

  if (res.timed_out || handler_stop) {
    killpg(pid, SIGKILL);
  }

  close(pipe_stdout[0]);

  if (waitpid(pid, &status, 0) == -1) status = 0;

  // Final drain of stderr (select loop may have left data).
  {
    int flags = fcntl(pipe_stderr[0], F_GETFL, 0);
    fcntl(pipe_stderr[0], F_SETFL, flags | O_NONBLOCK);
    char ebuf[4096];
    ssize_t n;
    while ((n = read(pipe_stderr[0], ebuf, sizeof(ebuf) - 1)) > 0) {
      res.stderr_data.append(ebuf, n);
    }
  }
  close(pipe_stderr[0]);

  res.exit_code = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
  return res;
}

#endif

} // namespace subprocess
