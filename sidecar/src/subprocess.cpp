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
#include <fcntl.h>
#endif

namespace subprocess {

// ============================================================================
// Windows command-line construction (CreateProcessA quoting rules)
// ============================================================================

/// Quote a single argv element for a CreateProcessA command line.
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

// ============================================================================
// Windows implementation
// ============================================================================

#ifdef _WIN32

Result run(const std::vector<std::string>& argv, const Options& opts) {
  Result res;
  if (argv.empty()) return res;
  std::string cmd = build_command_line(argv);

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

  STARTUPINFOA si = {};
  si.cb = sizeof(si);
  si.hStdInput = hStdInRd;
  si.hStdOutput = hStdOutWr;
  si.hStdError = hStdErrWr;
  si.dwFlags |= STARTF_USESTDHANDLES;

  // Job Object: kills the whole process tree when the job closes / is terminated.
  HANDLE hJob = CreateJobObjectA(nullptr, nullptr);
  if (hJob) {
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION jeli = {};
    jeli.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    SetInformationJobObject(hJob, JobObjectExtendedLimitInformation, &jeli, sizeof(jeli));
  }

  std::vector<char> cmd_buf(cmd.begin(), cmd.end());
  cmd_buf.push_back('\0');
  PROCESS_INFORMATION pi = {};
  const char* cwd_ptr = opts.cwd.empty() ? nullptr : opts.cwd.c_str();
  BOOL ok = CreateProcessA(nullptr, cmd_buf.data(), nullptr, nullptr, TRUE,
                           CREATE_NO_WINDOW, nullptr, cwd_ptr, &si, &pi);

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

    DWORD wr = WaitForSingleObject(pi.hProcess, 100);
    if (wr == WAIT_OBJECT_0) {
      // Process exited — final drain to capture remaining buffered data.
      drain(hStdOutRd, true);
      drain(hStdErrRd, false);
      break;
    }

    auto elapsed = std::chrono::duration_cast<std::chrono::seconds>(
      std::chrono::steady_clock::now() - start_time).count();
    if (elapsed >= opts.timeout_seconds) {
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
    execv(cargv[0], cargv.data());
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
    auto elapsed = std::chrono::duration_cast<std::chrono::seconds>(
      std::chrono::steady_clock::now() - start).count();
    long remaining = static_cast<long>(opts.timeout_seconds) - static_cast<long>(elapsed);
    if (remaining <= 0) {
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
    tv.tv_sec = remaining;
    tv.tv_usec = 0;

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
