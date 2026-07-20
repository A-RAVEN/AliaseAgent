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
// Provider registry
// ---------------------------------------------------------------------------

/// Initialize search infrastructure from Dart config JSON.
/// Parses per-provider credentials and caches them into provider instances.
/// Performs SearXNG liveness check once (TCP connect to localhost:8888, 2s timeout).
/// Uses std::call_once to guarantee idempotency — repeated calls return immediately.
/// Returns JSON: {"ok":true} or {"ok":false,"error":"..."}
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
