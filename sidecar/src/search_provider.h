#ifndef SEARCH_PROVIDER_H
#define SEARCH_PROVIDER_H

#include <string>
#include <vector>
#include <memory>
#include <functional>

// ---------------------------------------------------------------------------
// Data structures
// ---------------------------------------------------------------------------

struct SearchResult {
  std::string title;   // may be empty (Kimi synthesized answer has no title)
  std::string url;     // may be empty (Kimi synthesized answer has no URL)
  std::string content; // shall be non-empty
};

struct SearchError {
  std::string message;     // human-readable error
  bool is_transient;       // retriable (HTTP 429, timeout) vs permanent (401, 403)
};

/// ProviderResult — unified result type
/// - Empty results + empty error.message = "no matches found" (success state)
/// - Empty results + non-empty error.message = failure
struct ProviderResult {
  std::vector<SearchResult> results;
  SearchError error;
};

// ---------------------------------------------------------------------------
// ISearchProvider — abstract interface
// ---------------------------------------------------------------------------

class ISearchProvider {
public:
  virtual ~ISearchProvider() = default;

  /// Unique kebab-case identifier (e.g., "zhipuai", "searxng", "kimi")
  virtual std::string name() const = 0;

  /// Human-readable description of provider capabilities
  virtual std::string description() const = 0;

  /// Whether this provider is configured and ready to use.
  /// For API-key providers: checks cached key is non-empty.
  /// For SearXNG: returns cached TCP liveness check result (O(1), no new connection).
  virtual bool is_configured() const = 0;

  /// Execute a search. Thread-safe — each call creates its own curl handle.
  virtual ProviderResult search(
    const std::string& query,
    const std::string& depth,  // "basic" or "deep"
    int max_results
  ) = 0;
};

// ---------------------------------------------------------------------------
// DeepSeek 后端的凭据闸门（tasks.md 3.2，设计决策 D2）
// ---------------------------------------------------------------------------

/// 判定 `deepseek` 后端该不该出现在可用清单里。**单独暴露是为了能被单测直接调**：
/// 安全边界用例拿"会话模型地址不是 DeepSeek"的配置断言它返回 false，并进一步断言
/// 没有发出任何请求。
///
/// 规则（顺序即判定顺序）：
///   ① `own_api_key` 非空**且** `own_base_url` 非空 → true：用户自己写死了密钥与
///      地址，既没动用会话模型那把密钥，也应该让地址写错这件事在失败说明里看得见；
///   ② `endpoint` 不含 `api.deepseek.com` → false（不回落、不发请求）：走到这里说明
///      要动用的要么是会话模型那把密钥、要么是它的地址；
///   ③ `own_api_key` 非空 → true（自己只写了密钥，地址仍是会话模型的地址）；
///   ④ `section_seen` 为假 → false（没写 `search.deepseek` 就没有回落的依据）；
///   ⑤ 否则回落：`session_api_key` 非空即 true。
///
/// @param section_seen         配置里是否出现过 `search.deepseek` 这一段
/// @param session_model_present 配置里有没有交出会话模型的地址/密钥
///                              （供日志与排错用，判定不依赖它）
/// @param own_api_key          `search.deepseek.api_key`
/// @param session_api_key      会话模型当前 provider 的密钥（`session_model.api_key`）
/// @param own_base_url         `search.deepseek.base_url`（用户自己写的那个）
/// @param endpoint             本次实际会用的地址（自己写了就是它，否则是会话模型的）
bool deepseek_provider_is_available(bool section_seen,
                                    bool session_model_present,
                                    const std::string& own_api_key,
                                    const std::string& session_api_key,
                                    const std::string& own_base_url,
                                    const std::string& endpoint);

// ---------------------------------------------------------------------------
// Provider registry
// ---------------------------------------------------------------------------

/// Initialize search infrastructure from Dart config JSON.
/// Parses per-provider credentials and caches them into provider instances.
/// Performs SearXNG liveness check once (TCP connect to localhost:8888, 2s timeout).
/// Uses std::call_once to guarantee idempotency — repeated calls return immediately.
/// Returns JSON: {"ok":true} or {"ok":false,"error":"..."}
///
/// 配置 JSON 的字段名（deepseek 那部分）：
///   `search.deepseek.{api_key,base_url,model}` —— 用户自己写的（都可选）
///   `session_model.{base_url,api_key}`         —— 会话模型当前 provider 的地址与密钥
std::string ensure_search_infra_impl(const std::string& search_config_json);

/// Return list of configured providers as JSON array of {name, description}.
/// Only returns providers whose is_configured() returns true.
std::string get_search_providers_json();

/// Get the list of configured ISearchProvider instances for dispatch.
/// Returns only providers whose is_configured() returns true.
std::vector<std::shared_ptr<ISearchProvider>> get_configured_providers();

// ---------------------------------------------------------------------------
// Parallel dispatch
// ---------------------------------------------------------------------------

/// Execute web_search: parse JSON request, validate input, dispatch to providers
/// in parallel via std::future + wait_for, aggregate namespaced results.
/// Returns namespaced JSON string.
std::string dispatch_web_search(const std::string& request_json);

// ---------------------------------------------------------------------------
// Test hooks (task 9.0e)
// ---------------------------------------------------------------------------

/// Inject mock providers for testing. When set, get_configured_providers()
/// returns these instead of the real configured providers.
/// Pass an empty vector to clear test providers.
void set_test_providers(const std::vector<std::shared_ptr<ISearchProvider>>& providers);

#endif // SEARCH_PROVIDER_H
