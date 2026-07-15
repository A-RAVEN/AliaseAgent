#include "crash_handler.h"
#include <cstring>
#include <ctime>
#include <cstdio>
#include <cstdlib>

#ifdef _WIN32
#include <windows.h>
#include <dbghelp.h>
#include <string>
#include <algorithm>
#pragma comment(lib, "dbghelp.lib")
#else
#include <unistd.h>
#include <signal.h>
#include <execinfo.h>
#include <fcntl.h>
#include <sys/stat.h>
#endif

// ---------------------------------------------------------------------------
// Global crash state (pre-initialized before any crash can occur)
// ---------------------------------------------------------------------------

#ifdef _WIN32
static HANDLE g_crash_log_handle = INVALID_HANDLE_VALUE;
#else
static int g_crash_log_fd = -1;
#endif

static bool g_crash_inited = false;
static char g_crash_dir[512] = {0};

// ---------------------------------------------------------------------------
// Reentrant crash_log — WriteFile / write syscall, no mutex, no malloc
// ---------------------------------------------------------------------------

void crash_log(const char* msg) {
#ifdef _WIN32
  if (g_crash_log_handle == INVALID_HANDLE_VALUE) return;
  DWORD written;
  WriteFile(g_crash_log_handle, msg, (DWORD)strlen(msg), &written, nullptr);
  WriteFile(g_crash_log_handle, "\r\n", 2, &written, nullptr);
#else
  if (g_crash_log_fd < 0) return;
  size_t len = strlen(msg);
  write(g_crash_log_fd, msg, len);
  write(g_crash_log_fd, "\n", 1);
#endif
}

// ---------------------------------------------------------------------------
// Crash dump file lifecycle — keep at most max_files
// ---------------------------------------------------------------------------

#ifdef _WIN32
void crash_rotate_dumps(const char* crash_dir, int max_files) {
  // Enumerate .dmp files, sort by modification time, delete oldest if over limit
  std::string pattern = std::string(crash_dir) + "\\*.dmp";
  WIN32_FIND_DATAA fd;
  HANDLE h = FindFirstFileA(pattern.c_str(), &fd);
  if (h == INVALID_HANDLE_VALUE) return;

  struct DmpInfo {
    std::string name;
    FILETIME ft;
  };
  std::vector<DmpInfo> dmps;

  do {
    DmpInfo info;
    info.name = fd.cFileName;
    info.ft = fd.ftLastWriteTime;
    dmps.push_back(info);
  } while (FindNextFileA(h, &fd));
  FindClose(h);

  if ((int)dmps.size() <= max_files) return;

  // Sort oldest first
  std::sort(dmps.begin(), dmps.end(), [](const DmpInfo& a, const DmpInfo& b) {
    return CompareFileTime(&a.ft, &b.ft) < 0;
  });

  // Delete oldest until within limit
  int to_delete = (int)dmps.size() - max_files;
  for (int i = 0; i < to_delete; ++i) {
    std::string full = std::string(crash_dir) + "\\" + dmps[i].name;
    DeleteFileA(full.c_str());
  }
}
#else
void crash_rotate_dumps(const char* crash_dir, int max_files) {
  // Non-Windows: no .dmp files to rotate; backtraces are in crash.log
  (void)crash_dir;
  (void)max_files;
}
#endif

// ---------------------------------------------------------------------------
// Timestamp helper (signal-safe: uses stack buffer only)
// ---------------------------------------------------------------------------

static void format_timestamp(char* buf, size_t bufsz) {
  time_t now = time(nullptr);
  struct tm tm;
#ifdef _WIN32
  localtime_s(&tm, &now);
#else
  localtime_r(&now, &tm);
#endif
  snprintf(buf, bufsz, "%04d%02d%02d_%02d%02d%02d",
           tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday,
           tm.tm_hour, tm.tm_min, tm.tm_sec);
}

// ============================================================================
// Windows implementation
// ============================================================================

#ifdef _WIN32

static LONG WINAPI unhandled_exception_filter(EXCEPTION_POINTERS* ex_info) {
  char msg[256];
  DWORD code = ex_info->ExceptionRecord->ExceptionCode;
  void* addr = ex_info->ExceptionRecord->ExceptionAddress;
  DWORD tid = GetCurrentThreadId();
  snprintf(msg, sizeof(msg),
           "Unhandled exception: code=0x%08lX addr=%p thread=%lu",
           code, addr, tid);
  crash_log(msg);
  dump_ffi_ring_buffer();
  crash_write_dump();
  return EXCEPTION_EXECUTE_HANDLER;
}

static void terminate_handler() {
  crash_log("std::terminate called");
  dump_ffi_ring_buffer();
  crash_write_dump();
  // Re-throw — the runtime will call abort()
}

void crash_write_dump() {
  if (g_crash_dir[0] == '\0') return;

  // Generate filename with timestamp
  char ts[32];
  format_timestamp(ts, sizeof(ts));
  char filename[512];
  snprintf(filename, sizeof(filename), "%s\\sidecar_crash_%s.dmp", g_crash_dir, ts);

  HANDLE file = CreateFileA(filename, GENERIC_WRITE, 0, nullptr,
                             CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return;

  MINIDUMP_EXCEPTION_INFORMATION mei{};
  mei.ThreadId = GetCurrentThreadId();
  mei.ExceptionPointers = nullptr;
  // Capture current context if no exception pointer available
  CONTEXT ctx{};
  RtlCaptureContext(&ctx);
  EXCEPTION_RECORD er{};
  er.ExceptionAddress = _ReturnAddress();
  EXCEPTION_POINTERS ep{&er, &ctx};
  mei.ExceptionPointers = &ep;
  mei.ClientPointers = FALSE;

  // Dynamically load dbghelp for MiniDumpWriteDump (avoid static link issues)
  HMODULE dbghelp = GetModuleHandleA("dbghelp.dll");
  if (!dbghelp) dbghelp = LoadLibraryA("dbghelp.dll");

  typedef BOOL (WINAPI *MDWD)(HANDLE, DWORD, HANDLE, MINIDUMP_TYPE,
      PMINIDUMP_EXCEPTION_INFORMATION, PMINIDUMP_USER_STREAM_INFORMATION,
      PMINIDUMP_CALLBACK_INFORMATION);
  auto mini_dump_write_dump = (MDWD)GetProcAddress(dbghelp, "MiniDumpWriteDump");

  if (mini_dump_write_dump) {
    BOOL ok = mini_dump_write_dump(
        GetCurrentProcess(), GetCurrentProcessId(),
        file, MiniDumpNormal,
        mei.ExceptionPointers, nullptr, nullptr);
    if (ok) {
      char buf[512];
      snprintf(buf, sizeof(buf), "Minidump written: %s", filename);
      crash_log(buf);
    }
  }

  CloseHandle(file);

  // Rotate old dumps
  crash_rotate_dumps(g_crash_dir, 10);
}

void crash_init(const char* crash_dir) {
  if (g_crash_inited) return;
  g_crash_inited = true;

  if (crash_dir) {
    strncpy(g_crash_dir, crash_dir, sizeof(g_crash_dir) - 1);
    g_crash_dir[sizeof(g_crash_dir) - 1] = '\0';
  }

  // Open crash log file
  char log_path[512];
  snprintf(log_path, sizeof(log_path), "%s\\crash.log", g_crash_dir);
  g_crash_log_handle = CreateFileA(log_path, FILE_APPEND_DATA,
      FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
      OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);

  // Register handlers
  SetUnhandledExceptionFilter(unhandled_exception_filter);
  std::set_terminate(terminate_handler);
}

// ============================================================================
// Linux/macOS implementation
// ============================================================================

#else

static void signal_handler(int sig, siginfo_t* info, void* ctx) {
  char msg[256];
  const char* name = (sig == SIGSEGV) ? "SIGSEGV" : (sig == SIGABRT) ? "SIGABRT" : "SIGNAL";
  snprintf(msg, sizeof(msg), "Signal %d (%s) at address=%p", sig, name, info->si_addr);
  crash_log(msg);
  dump_ffi_ring_buffer();
  crash_write_dump();

  // Re-raise with default handler to get core dump
  signal(sig, SIG_DFL);
  raise(sig);
}

static void terminate_handler() {
  crash_log("std::terminate called");
  dump_ffi_ring_buffer();
  crash_write_dump();
  abort();
}

void crash_write_dump() {
  if (g_crash_dir[0] == '\0') return;

  char ts[32];
  format_timestamp(ts, sizeof(ts));

  // Open a timestamped crash log for the backtrace
  char path[512];
  snprintf(path, sizeof(path), "%s/crash_backtrace_%s.log", g_crash_dir, ts);
  int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
  if (fd < 0) return;

  void* buffer[128];
  int nptrs = backtrace(buffer, 128);
  char** symbols = backtrace_symbols(buffer, nptrs);

  char header[128];
  int hlen = snprintf(header, sizeof(header), "Stack trace (%d frames):\n", nptrs);
  write(fd, header, hlen);

  if (symbols) {
    for (int i = 0; i < nptrs; ++i) {
      write(fd, symbols[i], strlen(symbols[i]));
      write(fd, "\n", 1);
    }
  }

  close(fd);

  char msg[256];
  snprintf(msg, sizeof(msg), "Backtrace written: %s", path);
  crash_log(msg);
}

void crash_init(const char* crash_dir) {
  if (g_crash_inited) return;
  g_crash_inited = true;

  if (crash_dir) {
    strncpy(g_crash_dir, crash_dir, sizeof(g_crash_dir) - 1);
    g_crash_dir[sizeof(g_crash_dir) - 1] = '\0';
  }

  // Open crash log file (append)
  char log_path[512];
  snprintf(log_path, sizeof(log_path), "%s/crash.log", g_crash_dir);
  g_crash_log_fd = open(log_path, O_WRONLY | O_CREAT | O_APPEND, 0644);

  // Register signal handlers
  struct sigaction sa{};
  sa.sa_sigaction = signal_handler;
  sa.sa_flags = SA_SIGINFO;
  sigaction(SIGSEGV, &sa, nullptr);
  sigaction(SIGABRT, &sa, nullptr);

  // Register terminate handler
  std::set_terminate(terminate_handler);
}

#endif
