#ifndef SEARXNG_SEARCH_H
#define SEARXNG_SEARCH_H

#include "search_provider.h"
#include <string>

// ============================================================================
// SearXNGSelfHost — search provider using local SearXNG instance
// ============================================================================

class SearXNGSelfHost : public ISearchProvider {
public:
  SearXNGSelfHost() = default;

  std::string name() const override { return "searxng"; }

  std::string description() const override {
    return "SearXNG self-hosted — 70+ search engines, short snippets. "
           "No API key needed. Runs locally.";
  }

  bool is_configured() const override;

  ProviderResult search(
    const std::string& query,
    const std::string& depth,
    int max_results
  ) override;

  // ---- Configuration setters (called by ensure_search_infra) ----

  void set_base_url(const std::string& url) { base_url_ = url; }
  void set_available(bool available) { available_ = available; }

private:
  std::string base_url_ = "http://localhost:8888";
  bool available_ = true; // set by ensure_search_infra's TCP liveness check
};

// ============================================================================
// Factory / registration
// ============================================================================

/// Get the global SearXNGSelfHost instance.
std::shared_ptr<SearXNGSelfHost> get_searxng_provider();

#endif // SEARXNG_SEARCH_H
