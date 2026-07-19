#include "search_provider.h"
#include "zhipuai_search.h"
#include "searxng_search.h"
#include "kimi_search.h"
#include "logger.h"
#include "tools.h"
#include <nlohmann/json.hpp>
#include <curl/curl.h>
#include <string>
#include <vector>
#include <thread>
#include <memory>
#include <future>
#include <chrono>
#include <algorithm>
#include <cstring>
#include <atomic>
#include <mutex>

using json = nlohmann::json;

// ============================================================================
// JSON helpers
// ============================================================================

static std::string ok_json() {
  return "{\"ok\":true}";
}

static std::string error_json(const std::string& msg) {
  return "{\"ok\":false,\"error\":\"" + tools::json_escape(msg) + "\"}";
}

// ============================================================================
// Mock/placeholder providers — real implementations in later phases
// ============================================================================

/// Placeholder provider that always returns "not configured".
class NotConfiguredProvider : public ISearchProvider {
  std::string name_;
public:
  explicit NotConfiguredProvider(std::string n) : name_(std::move(n)) {}
  std::string name() const override { return name_; }
  std::string description() const override { return ""; }
  bool is_configured() const override { return false; }
  ProviderResult search(const std::string&, const std::string&, int) override {
    return {{}, {"Provider not configured", false}};
  }
};

// ============================================================================
// Provider registry (task 1.4)
// ============================================================================

static std::once_flag g_search_infra_once;
static bool g_search_infra_done = false;
static std::string g_search_infra_error;

// Cached provider instances
static std::vector<std::shared_ptr<ISearchProvider>> g_providers;

// Test provider injection (task 9.0e)
static std::vector<std::shared_ptr<ISearchProvider>> g_test_providers;
static bool g_test_mode_active = false; // once set, always use test path

void set_test_providers(const std::vector<std::shared_ptr<ISearchProvider>>& providers) {
    g_test_providers = providers;
    g_test_mode_active = true; // always active after first call, even if empty
}

// Per-provider cached config
static std::string g_zhipuai_api_key;
static std::string g_zhipuai_model;
static std::string g_kimi_api_key;
static std::string g_kimi_model;
static std::string g_searxng_base_url;
static bool g_searxng_available = false; // cached TCP liveness result

std::string ensure_search_infra(const std::string& search_config_json) {
  // Idempotency guard — only run once
  bool already_done = false;
  std::call_once(g_search_infra_once, [&]() {
    already_done = true;

    try {
      if (search_config_json.empty() || search_config_json == "{}") {
        // No search config — all providers remain unconfigured
        g_search_infra_done = true;
        return;
      }

      auto cfg = json::parse(search_config_json);

      // ZhipuAI
      if (cfg.contains("zhipuai") && cfg["zhipuai"].is_object()) {
        auto& z = cfg["zhipuai"];
        if (z.contains("api_key")) g_zhipuai_api_key = z["api_key"].get<std::string>();
        if (z.contains("model")) g_zhipuai_model = z["model"].get<std::string>();

        // Configure the ZhipuAI provider instance
        auto zhipuai = get_zhipuai_provider();
        if (!g_zhipuai_api_key.empty()) {
          zhipuai->set_api_key(g_zhipuai_api_key);
        }
        if (!g_zhipuai_model.empty()) {
          zhipuai->set_model(g_zhipuai_model);
        }
      }

      // Kimi
      if (cfg.contains("kimi") && cfg["kimi"].is_object()) {
        auto& k = cfg["kimi"];
        if (k.contains("api_key")) g_kimi_api_key = k["api_key"].get<std::string>();
        if (k.contains("model")) g_kimi_model = k["model"].get<std::string>();

        // Configure the Kimi provider instance
        auto kimi = get_kimi_provider();
        if (!g_kimi_api_key.empty()) {
          kimi->set_api_key(g_kimi_api_key);
        }
        if (!g_kimi_model.empty()) {
          kimi->set_model(g_kimi_model);
        }
      }

      // SearXNG
      if (cfg.contains("searxng") && cfg["searxng"].is_object()) {
        auto& s = cfg["searxng"];
        if (s.contains("base_url")) g_searxng_base_url = s["base_url"].get<std::string>();
      }
      if (g_searxng_base_url.empty()) {
        g_searxng_base_url = "http://localhost:8888";
      }

      // Configure SearXNG provider instance
      auto searxng = get_searxng_provider();
      searxng->set_base_url(g_searxng_base_url);

      // One-time SearXNG TCP liveness check (2s timeout)
      // Skip the check for now — it blocks the main thread.
      // SearXNG will be marked unavailable until a background check completes.
      g_searxng_available = false;
      searxng->set_available(false);
      LOG_INFO("SearXNG liveness check: skipped (assume unavailable)");

      g_search_infra_done = true;
    } catch (const json::parse_error& e) {
      g_search_infra_error = std::string("Failed to parse search config: ") + e.what();
      g_search_infra_done = false;
    } catch (const std::exception& e) {
      g_search_infra_error = std::string("Search infra init error: ") + e.what();
      g_search_infra_done = false;
    }
  });

  if (!g_search_infra_done && already_done) {
    return error_json(g_search_infra_error);
  }

  // Already initialized (either this call or previous)
  if (!g_search_infra_done) {
    return error_json(g_search_infra_error.empty() ? "Search infra init failed" : g_search_infra_error);
  }

  return ok_json();
}

std::string get_search_providers_json() {
  auto providers = get_configured_providers();
  json arr = json::array();
  for (auto& p : providers) {
    json obj;
    obj["name"] = p->name();
    obj["description"] = p->description();
    arr.push_back(obj);
  }
  return arr.dump();
}

std::vector<std::shared_ptr<ISearchProvider>> get_configured_providers() {
  // Test injection path (task 9.0e)
  if (g_test_mode_active) {
    return g_test_providers;
  }

  std::vector<std::shared_ptr<ISearchProvider>> result;

  // Providers will be populated by their respective implementation files
  // (zhipuai_search.cpp, searxng_search.cpp, kimi_search.cpp) via
  // factory functions registered in ensure_search_infra or via static init.
  //
  // ZhipuAI (Phase 4) — uses cached API key from ensure_search_infra
  if (!g_zhipuai_api_key.empty()) {
    auto zhipuai = get_zhipuai_provider();
    if (zhipuai->is_configured()) {
      result.push_back(zhipuai);
    }
  }

  // SearXNG (Phase 5) — available if TCP liveness check passed
  {
    auto searxng = get_searxng_provider();
    if (searxng->is_configured()) {
      result.push_back(searxng);
    }
  }

  // Kimi (Phase 6) — uses cached API key from ensure_search_infra
  if (!g_kimi_api_key.empty()) {
    auto kimi = get_kimi_provider();
    if (kimi->is_configured()) {
      result.push_back(kimi);
    }
  }

  return result;
}

// ============================================================================
// Parallel dispatch (tasks 1.5, 1.6, 1.7)
// ============================================================================

// Per-provider timeout constants (seconds)
static const long SEARXNG_TIMEOUT_SEC = 5;
static const long ZHIPUAI_TIMEOUT_SEC = 30;
static const long KIMI_TIMEOUT_SEC = 30;

// Total deadline per mode
static const int DEADLINE_BASIC_SEC = 30;
static const int DEADLINE_DEEP_SEC = 90;

std::string dispatch_web_search(const std::string& request_json) {
  try {
    auto req = json::parse(request_json);

    // Input validation (task 9.4a spec):
    std::string query;
    if (req.contains("query")) {
      query = req["query"].get<std::string>();
    }
    if (query.empty()) {
      return error_json("Search query is empty");
    }

    int max_results = 5;
    if (req.contains("max_results")) {
      max_results = req["max_results"].get<int>();
      if (max_results < 1) max_results = 1;
      if (max_results > 10) max_results = 10;
    }

    std::string depth = "basic";
    if (req.contains("depth")) {
      depth = req["depth"].get<std::string>();
    }

    // Collect requested providers
    std::vector<std::string> requested_providers;
    if (req.contains("providers") && req["providers"].is_array()) {
      for (auto& p : req["providers"]) {
        requested_providers.push_back(p.get<std::string>());
      }
    }

    // Get configured providers
    auto all_providers = get_configured_providers();
    if (all_providers.empty()) {
      return error_json("No search providers configured");
    }

    // Filter to requested providers (or use all if none specified)
    std::vector<std::shared_ptr<ISearchProvider>> selected;
    if (requested_providers.empty()) {
      selected = all_providers;
    } else {
      for (auto& p : all_providers) {
        for (auto& r : requested_providers) {
          if (p->name() == r) {
            selected.push_back(p);
            break;
          }
        }
      }
      // Unknown provider names are silently ignored (spec)
    }

    if (selected.empty()) {
      return error_json("None of the requested providers are configured");
    }

    // Per-provider timeout is set inside each provider's search() implementation.
    // The CURLOPT_TIMEOUT per-request model ensures each provider has its own timeout.

    // Total deadline = max(per-provider timeout) across selected providers
    int per_provider_max_sec = (depth == "deep") ? DEADLINE_DEEP_SEC : DEADLINE_BASIC_SEC;

    LOG_INFO("web_search: query=\"" + query + "\" depth=" + depth +
             " max_results=" + std::to_string(max_results) +
             " providers=" + std::to_string(selected.size()) +
             " deadline=" + std::to_string(per_provider_max_sec) + "s");

    // Parallel dispatch via std::future + wait_for (NOT std::thread::join)
    // Capture provider by value in lambda (NOT [&] — dangling reference risk)
    std::vector<std::future<ProviderResult>> futures;
    for (auto& provider : selected) {
      futures.push_back(std::async(std::launch::async,
        [provider, query, depth, max_results]() -> ProviderResult {
          try {
            return provider->search(query, depth, max_results);
          } catch (const std::exception& e) {
            return {{}, {std::string("Provider error: ") + e.what(), false}};
          } catch (...) {
            return {{}, {"Unknown provider error", false}};
          }
        }
      ));
    }

    // Deadline enforcement via wait_until
    auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(per_provider_max_sec);

    json result;
    result["ok"] = true;
    result["results"] = json::object();

    bool any_provider_succeeded = false;
    bool all_providers_failed = true;
    std::string combined_error;

    for (size_t i = 0; i < futures.size(); ++i) {
      auto status = futures[i].wait_until(deadline);
      std::string ns = selected[i]->name();

      if (status == std::future_status::ready) {
        auto pr = futures[i].get();
        json ns_obj;

        if (pr.error.message.empty()) {
          // Success or empty results
          any_provider_succeeded = true;
          all_providers_failed = false;
          ns_obj["results"] = json::array();
          for (auto& r : pr.results) {
            json item;
            item["title"] = r.title;
            item["url"] = r.url;
            item["content"] = r.content;
            ns_obj["results"].push_back(item);
          }
          result["results"][ns] = ns_obj;
        } else {
          // Error from provider
          ns_obj["error"] = pr.error.message;
          if (!combined_error.empty()) combined_error += "; ";
          combined_error += ns + ": " + pr.error.message;
          result["results"][ns] = ns_obj;
        }
      } else {
        // Timeout — provider didn't complete before deadline
        json ns_obj;
        ns_obj["error"] = "Timeout after " + std::to_string(per_provider_max_sec) + "s";
        if (!combined_error.empty()) combined_error += "; ";
        combined_error += ns + ": timeout";
        result["results"][ns] = ns_obj;
        LOG_WARN("web_search: provider " + ns + " timed out");
      }
    }

    if (all_providers_failed) {
      result["ok"] = false;
      result["error"] = "All providers failed: " + combined_error;
    }

    return result.dump();

  } catch (const json::parse_error& e) {
    return error_json(std::string("Invalid search request: ") + e.what());
  } catch (const std::exception& e) {
    return error_json(std::string("Search dispatch error: ") + e.what());
  } catch (...) {
    return error_json("Unknown search dispatch error");
  }
}
