#ifndef SUBPROCESS_H
#define SUBPROCESS_H

#include <string>
#include <utility>
#include <vector>
#include <functional>

#ifdef _WIN32
#include <windows.h>  // DWORD（下面的排错用变量）
#endif

// ============================================================================
// Generic subprocess runner — shared by crawl4ai (web_fetch) and ripgrep
// (glob_file / grep_file).
//
// Windows: CreateProcessW + Job Object (process-tree kill) + pipes + 100ms
//          poll loop + timeout termination.（早先用 CreateProcessA，中文参数与
//          中文工作目录会被 ANSI 码页弄坏，见 run() 上方的说明。）
// POSIX:   fork + execv + select() + killpg on timeout.
//
// argv is passed as a list (no shell involved). A Windows command line is
// built from argv with CreateProcessA quoting rules; POSIX passes argv
// directly to execv.
// ============================================================================

namespace subprocess {

struct Result {
  bool started = false;       // process created/exec'd successfully
  bool timed_out = false;     // terminated due to timeout
  bool stopped_early = false; // stdout handler requested early termination
  int exit_code = -1;         // process exit code (-1 if not captured)
  std::string stdout_data;    // captured stdout (only when no on_stdout_chunk)
  std::string stderr_data;    // captured stderr
};

/// Optional stdout consumer. Called with each chunk of stdout as it arrives
/// (chunk boundaries are pipe-read boundaries, not line boundaries). Return
/// true to request EARLY TERMINATION: the process is killed and run() returns
/// with stopped_early=true. Used for streaming truncation decisions.
using StdoutChunkHandler = std::function<bool(const std::string& chunk)>;

struct Options {
  std::string stdin_data;              // written to child's stdin, then closed
  std::string cwd;                     // child working directory (empty = inherit)
  int timeout_seconds = 30;            // 整秒超时（既有调用方用这个）
  // 毫秒超时。**大于 0 时优先于 timeout_seconds** —— 模型给的超时是毫秒数，
  // 整秒装不下它（500 毫秒会被截成 0 而立即触发）。保持 0 即沿用整秒语义。
  int timeout_ms = 0;
  StdoutChunkHandler on_stdout_chunk;  // if set, stdout is streamed here (not buffered)
  // 要**额外注入**给子进程的环境变量。是"并入"不是"替换"：子进程仍会拿到本进程
  // 的完整环境（PATH、SystemRoot、TEMP 等），只是这几项被覆盖/新增。键名按 Windows
  // 的规则做大小写不敏感比较，同一个块里不会出现两个同名变量。
  std::vector<std::pair<std::string, std::string>> extra_env;
};

/// Run a subprocess with the given argv. Captures stdout/stderr (or streams
/// stdout via on_stdout_chunk). Kills the process tree on timeout or early stop.
///
/// Windows 上真正的启动走宽字符接口（`CreateProcessW`），命令行与工作目录都按
/// UTF-8 转 UTF-16 之后传进去。**为什么必须这样**：`CreateProcessA` 用当前 ANSI
/// 码页解释命令行与工作目录，而本机 ANSI 码页是 1252（控制台码页是另一回事），
/// 于是含中文的参数与工作目录会被弄坏 —— 实测：参数 `中文参数` 传到子进程里变成
/// `c3a4c2b8c2ad…`（UTF-8 字节被按 1252 解释后再编码一次），而尾反斜杠、连续反
/// 斜杠这两类只含 ASCII 的参数不受影响。改成宽字符之后，不在当前码页里的路径
/// 由"起不来"变成"能起来"。
///
/// 已经实测过的另一件事：命令字符串作为**一个** argv 元素递到 PowerShell 的
/// `-Command` 之后，PowerShell 收到的就是原文（含空格、单双引号、结尾反斜杠），
/// 我们拼装时加的那一对定界引号被 `CommandLineToArgvW` 正常去掉。所以"外层不做
/// 二次解析"这条成立，argv 形状的断言不足以代替它，实测结论记在这里。
Result run(const std::vector<std::string>& argv, const Options& opts = {});

/// Build a Windows command line from argv using CommandLineToArgvW quoting rules.
/// (POSIX builds execv directly and never needs this; exposed for tests.)
std::string build_command_line(const std::vector<std::string>& argv);

#ifdef _WIN32
/// 与 build_command_line 同一套引号规则，作用在 UTF-16 上（真正启动时用它）。
/// 两个函数对同一组 argv 的分段结果必须一致：断言见 subprocess_test.cpp。
std::wstring build_command_line_wide(const std::vector<std::string>& argv);

/// UTF-8 → UTF-16。**给所有要走宽字符接口的调用方共用**：中文路径只有转对了才
/// 能被 `GetFileAttributesW` / `_wmkdir` / `CreateProcessW` 认出来。转换失败
/// （非法 UTF-8）返回空串，调用方按"用不了"处理。
std::wstring utf8_to_wide(const std::string& s);

/// 最近一次"起进程失败"的 `GetLastError()`，以及当时有没有传自定义环境块。
/// 仅供测试与排错：正式的失败原因还没有出口（见 `Docs/known-bugs.md`）。
extern DWORD g_last_start_error;
extern bool g_last_start_had_env;
#endif

} // namespace subprocess

#endif // SUBPROCESS_H
