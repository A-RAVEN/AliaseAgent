#ifndef LOGGER_H
#define LOGGER_H

#include <mutex>
#include <fstream>
#include <string>
#include <atomic>

class Logger {
public:
  enum Level { TRACE = 0, INFO = 1, WARN = 2, ERR = 3 };

  static Logger& instance();

  void init(const std::string& log_dir);
  void log(Level level, const std::string& message);
  void log_raw(const std::string& message);

  /// Fast lock-free read of current log level (for macro guards).
  Level level() const { return static_cast<Level>(current_level_.load(std::memory_order_relaxed)); }

  /// Expose crash directory for use by crash_handler.
  static std::string crash_dir();

private:
  Logger() = default;
  std::string timestamp();
  static const char* level_str(Level level);

  std::mutex mutex_;
  std::ofstream file_;
  bool initialized_ = false;
  std::atomic<int> current_level_{INFO};
  static std::string crash_dir_;
};

// Lazy-evaluation macros: level check before argument evaluation
#define LOG_TRACE(msg) do { if (Logger::instance().level() <= Logger::TRACE) Logger::instance().log(Logger::TRACE, msg); } while(0)
#define LOG_INFO(msg)  do { if (Logger::instance().level() <= Logger::INFO)  Logger::instance().log(Logger::INFO, msg);  } while(0)
#define LOG_WARN(msg)  do { if (Logger::instance().level() <= Logger::WARN)  Logger::instance().log(Logger::WARN, msg);  } while(0)
#define LOG_ERR(msg)   do { if (Logger::instance().level() <= Logger::ERR)   Logger::instance().log(Logger::ERR, msg);   } while(0)
#define LOG_RAW(msg)   Logger::instance().log_raw(msg)

#endif