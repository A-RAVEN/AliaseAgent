#ifndef LOGGER_H
#define LOGGER_H

#include <mutex>
#include <fstream>
#include <string>

class Logger {
public:
  enum Level { INFO, WARN, ERR };

  static Logger& instance();

  void init(const std::string& log_dir);
  void log(Level level, const std::string& message);
  void log_raw(const std::string& message);

private:
  Logger() = default;
  std::string timestamp();
  static const char* level_str(Level level);

  std::mutex mutex_;
  std::ofstream file_;
  bool initialized_ = false;
};

#define LOG_INFO(msg)  Logger::instance().log(Logger::INFO, msg)
#define LOG_WARN(msg)  Logger::instance().log(Logger::WARN, msg)
#define LOG_ERR(msg)   Logger::instance().log(Logger::ERR, msg)
#define LOG_RAW(msg)   Logger::instance().log_raw(msg)

#endif