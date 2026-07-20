#ifndef ZHIPUAI_SEARCH_H
#define ZHIPUAI_SEARCH_H

#include "search_provider.h"
#include <string>

// ============================================================================
// ZhipuAISearch — search provider using ZhipuAI standalone Web Search API
//
// POST https://open.bigmodel.cn/api/paas/v4/web_search
// with body {"search_engine":"search-prime","search_query":"...","count":N}.
// Returns structured search_result[] array — no model, no tool calling, no SSE.
//
// Deferred features (see design.md Non-Goals):
//   - search_domain_filter / search_recency_filter
//   - request_id / user_id
// ============================================================================

class ZhipuAISearch : public ISearchProvider {
public:
  ZhipuAISearch() = default;

  std::string name() const override { return "zhipuai"; }

  std::string description() const override {
    return "ZhipuAI Web Search — standalone search API returning structured "
           "results (title, URL, content). Requires API key.";
  }

  bool is_configured() const override;

  ProviderResult search(
    const std::string& query,
    const std::string& depth,
    int max_results
  ) override;

  // ---- Configuration setters (called by ensure_search_infra) ----

  void set_api_key(const std::string& key) { api_key_ = key; }
  void set_search_engine(const std::string& engine) { search_engine_ = engine; }
  void set_base_url(const std::string& url) { base_url_ = url; }

  // ---- Accessors for testing ----

  const std::string& api_key() const { return api_key_; }
  const std::string& search_engine() const { return search_engine_; }

private:
  std::string api_key_;
  std::string search_engine_ = "search-prime";
  std::string base_url_ = "https://open.bigmodel.cn/api/paas/v4/web_search";
};

// ============================================================================
// Factory / registration
// ============================================================================

/// Get the global ZhipuAISearch instance (created on first ensure_search_infra call).
std::shared_ptr<ZhipuAISearch> get_zhipuai_provider();

#endif // ZHIPUAI_SEARCH_H
