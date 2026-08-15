#ifndef SUBPROCESS_H
#define SUBPROCESS_H

#include <string>
#include <vector>
#include <functional>

// ============================================================================
// Generic subprocess runner — shared by crawl4ai (web_fetch) and ripgrep
// (glob_file / grep_file).
//
// Windows: CreateProcessA + Job Object (process-tree kill) + pipes + 100ms
//          poll loop + timeout termination.
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
  int timeout_seconds = 30;
  StdoutChunkHandler on_stdout_chunk;  // if set, stdout is streamed here (not buffered)
};

/// Run a subprocess with the given argv. Captures stdout/stderr (or streams
/// stdout via on_stdout_chunk). Kills the process tree on timeout or early stop.
Result run(const std::vector<std::string>& argv, const Options& opts = {});

/// Build a Windows command line from argv using CreateProcessA quoting rules.
/// (POSIX builds execv directly and never needs this; exposed for tests.)
std::string build_command_line(const std::vector<std::string>& argv);

} // namespace subprocess

#endif // SUBPROCESS_H
