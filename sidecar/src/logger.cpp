#include "logger.h"
#include <chrono>
#include <ctime>
#include <iomanip>
#include <sstream>
#include <cstdlib>
#include <cstring>
#include <filesystem>

#ifdef _WIN32
#include <direct.h>
#include <windows.h>
#define mkdir(p, m) _mkdir(p)
#else
#include <sys/stat.h>
#endif

Logger& Logger::instance() {
  static Logger inst;
  return inst;
}

std::string Logger::crash_dir_;

std::string Logger::crash_dir() {
  return crash_dir_;
}

static void ensure_dir(const std::string& path) {
  std::string p = path;
  for (size_t i = 1; i < p.size(); ++i) {
    if (p[i] == '/' || p[i] == '\\') {
      p[i] = '\0';
      mkdir(p.c_str(), 0755);
      p[i] = '/';
    }
  }
  mkdir(p.c_str(), 0755);
}

static void rotate_logs(const std::string& log_path) {
  namespace fs = std::filesystem;
  std::error_code ec;
  auto sz = fs::file_size(log_path, ec);
  if (ec || sz < 10 * 1024 * 1024) return; // < 10MB, no rotation

  // Rotate: .log → .1.log → .2.log, delete .3.log
  fs::path p(log_path);
  fs::path p3 = fs::path(log_path + ".3");  // actually we need .3.log, but simpler: base.3.log
  // Proper naming: sidecar.log → sidecar.1.log → sidecar.2.log
  std::string base = log_path;
  // sidecar.log → remove .log → sidecar
  std::string stem;
  if (base.size() > 4 && base.substr(base.size() - 4) == ".log") {
    stem = base.substr(0, base.size() - 4);
  } else {
    stem = base;
  }

  // Delete oldest
  fs::remove(stem + ".2.log", ec);
  // Shift
  fs::rename(stem + ".1.log", stem + ".2.log", ec);
  fs::rename(log_path, stem + ".1.log", ec);
}

void Logger::init(const std::string& log_dir) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (initialized_) return;

  // Read ALIASAGENT_LOG_LEVEL env var (once, at init time)
  const char* env_level = std::getenv("ALIASAGENT_LOG_LEVEL");
  if (env_level) {
    if (std::strcmp(env_level, "trace") == 0 || std::strcmp(env_level, "TRACE") == 0) {
      current_level_.store(TRACE, std::memory_order_relaxed);
    } else if (std::strcmp(env_level, "info") == 0 || std::strcmp(env_level, "INFO") == 0) {
      current_level_.store(INFO, std::memory_order_relaxed);
    } else if (std::strcmp(env_level, "warn") == 0 || std::strcmp(env_level, "WARN") == 0) {
      current_level_.store(WARN, std::memory_order_relaxed);
    } else if (std::strcmp(env_level, "error") == 0 || std::strcmp(env_level, "ERROR") == 0 ||
               std::strcmp(env_level, "err") == 0 || std::strcmp(env_level, "ERR") == 0) {
      current_level_.store(ERR, std::memory_order_relaxed);
    }
    // Unrecognized values → default to INFO (already set)
  }

  // Ensure log directory exists
  ensure_dir(log_dir);

  // Pre-create crashes directory
  crash_dir_ = log_dir;
  // Replace trailing "/logs" with "/crashes"
  {
    std::string ld = log_dir;
    if (ld.size() >= 5 && ld.substr(ld.size() - 5) == "/logs") {
      crash_dir_ = ld.substr(0, ld.size() - 5) + "/crashes";
    } else if (ld.size() >= 5 && ld.substr(ld.size() - 5) == "\\logs") {
      crash_dir_ = ld.substr(0, ld.size() - 5) + "\\crashes";
    }
  }
  ensure_dir(crash_dir_);

  std::string filename = log_dir + "/sidecar.log";

  // Log rotation: check size, rotate if > 10MB
  rotate_logs(filename);

  file_.open(filename, std::ios::out | std::ios::app);
  initialized_ = true;
}

void Logger::log(Level level, const std::string& message) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!file_.is_open()) return;
  file_ << timestamp() << " [" << level_str(level) << "] " << message << std::endl;
  file_.flush();
}

void Logger::log_raw(const std::string& message) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!file_.is_open()) return;
  file_ << message << std::endl;
  file_.flush();
}

std::string Logger::timestamp() {
  auto now = std::chrono::system_clock::now();
  auto t = std::chrono::system_clock::to_time_t(now);
  auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
      now.time_since_epoch()) % 1000;

  std::tm tm;
#ifdef _WIN32
  localtime_s(&tm, &t);
#else
  localtime_r(&t, &tm);
#endif

  std::ostringstream oss;
  oss << std::put_time(&tm, "%Y-%m-%d %H:%M:%S")
      << '.' << std::setfill('0') << std::setw(3) << ms.count();
  return oss.str();
}

const char* Logger::level_str(Level level) {
  switch (level) {
    case TRACE: return "TRACE";
    case INFO:  return "INFO";
    case WARN:  return "WARN";
    case ERR:   return "ERROR";
  }
  return "???";
}