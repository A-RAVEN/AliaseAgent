#ifndef ZHIPUAI_SEARCH_H
#define ZHIPUAI_SEARCH_H

#include "search_provider.h"
#include <string>

// ============================================================================
// ZhipuAISearch — search provider using ZhipuAI web_search tool
//
// Non-streaming HTTP POST to Chat Completions API with
// tools: [{"type": "web_search", "web_search": {...}}].
// Platform auto-executes search; results returned as top-level
// web_search[] array + synthesized answer in message.content.
// No SSE, no agent loop, no tool_result relay.
// ============================================================================

class ZhipuAISearch : public ISearchProvider {
public:
  ZhipuAISearch() = default;

  std::string name() const override { return "zhipuai"; }

  std::string description() const override {
    return "ZhipuAI web_search — AI-driven search with synthesized answer "
           "and structured results. Requires API key.";
  }

  bool is_configured() const override;

  ProviderResult search(
    const std::string& query,
    const std::string& depth,
    int max_results
  ) override;

  // ---- Configuration setters (called by ensure_search_infra) ----

  void set_api_key(const std::string& key) { api_key_ = key; }
  void set_model(const std::string& model) { model_ = model; }
  void set_base_url(const std::string& url) { base_url_ = url; }

  // ---- Accessors for testing ----

  const std::string& api_key() const { return api_key_; }
  const std::string& model() const { return model_; }

private:
  std::string api_key_;
  std::string model_ = "glm-4.7-flash";
  std::string base_url_ = "https://open.bigmodel.cn/api/paas/v4/chat/completions";
};

// ============================================================================
// Factory / registration
// ============================================================================

/// Get the global ZhipuAISearch instance (created on first ensure_search_infra call).
std::shared_ptr<ZhipuAISearch> get_zhipuai_provider();

#endif // ZHIPUAI_SEARCH_H
