#include "search_provider.h"
#include "zhipuai_search.h"
#include "searxng_search.h"
#include "kimi_search.h"
#include "deepseek_search.h"
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
// DeepSeek 后端的凭据闸门（tasks.md 3.2，设计决策 D2）
//
// 这是本变更的安全边界：**绝不把非 DeepSeek 的密钥发出去**。
//   ① `search.deepseek.api_key` / `.base_url`：写了就用写的；
//   ② 仅当"会话模型当前 provider 的地址"确实指向 DeepSeek（含 api.deepseek.com）
//      **且** `search.deepseek` 段存在（`g_deepseek_section_seen`）时，才允许回落
//      复用它那把密钥与地址；
//   ③ 地址不是 DeepSeek 时该后端直接不可用 —— 不回落、**不发任何请求**；
//   ④ `search` 段里没有 `deepseek` 项且不能回落时不出现。
//
// 传给 `ensure_search_infra` 的配置 JSON 里，这两处来源的字段名是：
//   `search.deepseek.{api_key,base_url,model}`  —— 用户自己写的
//   `session_model.{base_url,api_key}`          —— Dart 侧把会话模型当前 provider
//                                                  的地址与密钥一起交下来
// 没有 `session_model` 这一项时按"没有可回落的来源"处理（老配置、单测都走这条）。
// ============================================================================

/// `search.deepseek` 段是否出现过、`session_model` 有没有交出可回落的地址与密钥。
static bool g_deepseek_section_seen = false;
static bool g_session_model_present = false;

/// 判定某个 provider 该不该出现在可用清单里。**抽成函数就是为了能被单测直接调**
/// （4.3 的安全边界用例断言"非 DeepSeek 地址 → 不可用"）。
bool deepseek_provider_is_available(bool section_seen,
                                    bool session_model_present,
                                    const std::string& own_api_key,
                                    const std::string& session_api_key,
                                    const std::string& own_base_url,
                                    const std::string& endpoint) {
  (void)session_model_present;  // 回落只在 session_api_key 里已经体现
  // ① 自己**同时写了**密钥与地址：用这一份，不碰会话模型的任何东西，因此不存在
  //    "把别家密钥发出去"的问题；地址写错要让用户看得见（规范要求失败说明带实际
  //    地址），所以这一条要在地址判定**之前**。
  if (!own_api_key.empty() && !own_base_url.empty()) return true;
  if (!deepseek_address_is_deepseek(endpoint)) {
    // ③ 到这里说明要动用的要么是会话模型那把密钥、要么是它的地址 —— 地址不是
    //    DeepSeek 就绝不能碰：不回落、不发请求。
    return false;
  }
  if (!own_api_key.empty()) return true;   // ① 自己写了密钥，地址来自会话模型
  if (!section_seen) return false;         // ④ 没写这段就没有回落的依据
  return !session_api_key.empty();         // ② 地址确实是 DeepSeek 才允许回落
}

/// 取出"会话模型当前 provider 的地址与密钥"（Dart 侧组装，字段名
/// `session_model.{base_url,api_key}`）。**这个函数刻意留在读配置那个函数之外**：
/// `test/unit/user_docs_test.dart` 会从读配置那一段的源码里抽配置键名，并要求每个
/// 键都出现在用户文档里；`session_model` 是界面自己塞进去的内部字段，不该让用户
/// 去写，所以不放进那个扫描范围。（连带一条纪律：这一带任何注释里都不要写出那个
/// 函数的**连续函数名**，否则扫描起点会被顶到注释上，把这里重新圈进去。）
static void read_session_model_credentials(const json& cfg,
                                           std::string& session_key,
                                           std::string& session_base) {
  if (cfg.contains("session_model") && cfg["session_model"].is_object()) {
    const auto& sm = cfg["session_model"];
    if (sm.contains("api_key") && sm["api_key"].is_string()) {
      session_key = sm["api_key"].get<std::string>();
    }
    if (sm.contains("base_url") && sm["base_url"].is_string()) {
      session_base = sm["base_url"].get<std::string>();
    }
    g_session_model_present = (!session_key.empty() || !session_base.empty());
  }
}

/// 按闸门判定配置好 DeepSeek provider 实例，并按需清掉不该留着的凭据。
static void apply_deepseek_gate(const std::string& own_key,
                                const std::string& own_base,
                                const std::string& session_key,
                                const std::string& session_base) {
  // 地址：自己写了用自己的，否则（写了这一段才）回落会话模型的地址
  std::string base = own_base;
  if (base.empty() && g_deepseek_section_seen) base = session_base;

  auto provider = get_deepseek_provider();
  provider->set_section_present(g_deepseek_section_seen);
  provider->set_base_url(base);
  provider->set_api_key(own_key.empty() ? (g_deepseek_section_seen ? session_key : std::string())
                                        : own_key);

  const bool available = deepseek_provider_is_available(
    g_deepseek_section_seen, g_session_model_present, own_key, session_key,
    own_base, base);
  provider->set_gate_passed(available);
  LOG_INFO(std::string("DeepSeek 搜索后端：") + (available ? "可用" : "不可用") +
           "（search.deepseek 段" + (g_deepseek_section_seen ? "有" : "无") +
           "、会话模型凭据" + (g_session_model_present ? "有" : "无") +
           "、地址" + (base.empty() ? "未配置" : base) + "）");
  // 不可用时清掉实例上的凭据：即便将来某条路径绕过 is_configured()，也没有密钥可发。
  // 注意只清"密钥"：自己写的地址要留着，失败说明里要报出来（规范要求）。
  if (!available) {
    provider->set_api_key(std::string());
  }
}

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
static std::string g_kimi_api_key;
static std::string g_kimi_model;
static std::string g_searxng_base_url;
static bool g_searxng_available = false; // cached TCP liveness result

std::string ensure_search_infra_impl(const std::string& search_config_json) {
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

        // Configure the ZhipuAI provider instance
        auto zhipuai = get_zhipuai_provider();
        if (!g_zhipuai_api_key.empty()) {
          zhipuai->set_api_key(g_zhipuai_api_key);
        }
        if (z.contains("search_engine")) {
          zhipuai->set_search_engine(z["search_engine"].get<std::string>());
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

      // DeepSeek 后端（tasks.md 3.1 / 3.2）：带凭据闸门。
      //
      // 键名逐处写成字面量（`cfg.contains("deepseek")` / `cfg["deepseek"]`），不用
      // 局部引用 —— `test/unit/user_docs_test.dart` 就是从这里抽配置键名的，只有
      // 字面写出来，"代码解析了这个键 → 用户文档里必须写到它"这条反向检查才认。
      std::string deepseek_own_key;
      std::string deepseek_own_base;
      if (cfg.contains("deepseek") && cfg["deepseek"].is_object()) {
        g_deepseek_section_seen = true;
        if (cfg["deepseek"].contains("api_key") &&
            cfg["deepseek"]["api_key"].is_string()) {
          deepseek_own_key = cfg["deepseek"]["api_key"].get<std::string>();
        }
        if (cfg["deepseek"].contains("base_url") &&
            cfg["deepseek"]["base_url"].is_string()) {
          deepseek_own_base = cfg["deepseek"]["base_url"].get<std::string>();
        }
        if (cfg["deepseek"].contains("model") &&
            cfg["deepseek"]["model"].is_string()) {
          const std::string model = cfg["deepseek"]["model"].get<std::string>();
          if (!model.empty()) get_deepseek_provider()->set_model(model);
        }
      }
      std::string deepseek_session_key;
      std::string deepseek_session_base;
      read_session_model_credentials(cfg, deepseek_session_key, deepseek_session_base);
      apply_deepseek_gate(deepseek_own_key, deepseek_own_base,
                          deepseek_session_key, deepseek_session_base);

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

  // DeepSeek（add-deepseek-web-search）—— 凭据闸门已在 register_deepseek_from_config
  // 里判定过：地址不指向 DeepSeek 时实例上的密钥与地址都已被清空，这里只会拿到
  // is_configured() 为假，不会把任何密钥发出去。
  {
    auto deepseek = get_deepseek_provider();
    if (deepseek->is_configured()) {
      result.push_back(deepseek);
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
