#include "logger.h"
#include <chrono>
#include <ctime>
#include <iomanip>
#include <sstream>

#ifdef _WIN32
#include <direct.h>
#define mkdir(p, m) _mkdir(p)
#else
#include <sys/stat.h>
#endif

Logger& Logger::instance() {
  static Logger inst;
  return inst;
}

void Logger::init(const std::string& log_dir) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (initialized_) return;

  // Ensure log directory exists
  std::string path = log_dir;
  for (size_t i = 1; i < path.size(); ++i) {
    if (path[i] == '/' || path[i] == '\\') {
      path[i] = '\0';
      mkdir(path.c_str(), 0755);
      path[i] = '/';
    }
  }
  mkdir(path.c_str(), 0755);

  std::string filename = log_dir + "/sidecar.log";
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
    case INFO:  return "INFO";
    case WARN:  return "WARN";
    case ERR:   return "ERROR";
  }
  return "???";
}