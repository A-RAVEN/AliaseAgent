#ifndef API_KEY_LOADER_H
#define API_KEY_LOADER_H

#include <string>
#include <fstream>
#include <sstream>
#include <nlohmann/json.hpp>
#include <cstdlib>

// ============================================================================
// ApiKeyLoader — read API keys from user config for live integration tests
// ============================================================================

class ApiKeyLoader {
public:
  /// Load the full config.json from the user's home directory.
  /// Returns parsed JSON, or empty object on failure.
  static nlohmann::json load_config() {
    std::string config_path = get_config_path();
    if (config_path.empty()) return nlohmann::json::object();

    std::ifstream f(config_path);
    if (!f.is_open()) return nlohmann::json::object();

    try {
      std::ostringstream ss;
      ss << f.rdbuf();
      return nlohmann::json::parse(ss.str());
    } catch (...) {
      return nlohmann::json::object();
    }
  }

  /// Get the ZhipuAI API key from config.json.
  /// Returns empty string if not configured.
  static std::string get_zhipuai_key() {
    auto cfg = load_config();
    if (cfg.contains("search") && cfg["search"].contains("zhipuai")) {
      return cfg["search"]["zhipuai"].value("api_key", "");
    }
    return "";
  }

  /// Get the Kimi API key from config.json.
  /// Returns empty string if not configured.
  static std::string get_kimi_key() {
    auto cfg = load_config();
    if (cfg.contains("search") && cfg["search"].contains("kimi")) {
      return cfg["search"]["kimi"].value("api_key", "");
    }
    return "";
  }

private:
  static std::string get_config_path() {
#ifdef _WIN32
    const char* home = getenv("USERPROFILE");
#else
    const char* home = getenv("HOME");
#endif
    if (!home) return "";
    return std::string(home) + "/.aliasagent/config.json";
  }
};

#endif
