#ifndef KIMI_SEARCH_H
#define KIMI_SEARCH_H

#include "search_provider.h"
#include <string>

// ============================================================================
// KimiSearch — search provider using Kimi $web_search builtin function
// ============================================================================

class KimiSearch : public ISearchProvider {
public:
  KimiSearch() = default;

  std::string name() const override { return "kimi"; }

  std::string description() const override {
    return "Kimi $web_search — AI-synthesized answer (single summary, no URLs). "
           "Requires API key.";
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

private:
  std::string api_key_;
  std::string model_ = "kimi-k2.6";  // current flagship per Kimi docs, was "moonshot-v1-auto"
  std::string base_url_ = "https://api.moonshot.cn/v1/chat/completions";

  /// Perform a single HTTP POST + SSE parse attempt.
  /// @param messages_json  The conversation messages JSON
  /// @param result_json    Output: the tool_call arguments JSON (NO-OP relay)
  /// @param text_answer    Output: the final text answer
  /// @param error_msg      Output: error message on failure
  /// @param http_code      Output: HTTP response code (for 429 detection)
  /// @return true if the request completed without transport error
  bool perform_request(
    const std::string& messages_json,
    std::string& result_json,
    std::string& text_answer,
    std::string& error_msg,
    long& http_code
  ) const;
};

// ============================================================================
// Factory / registration
// ============================================================================

/// Get the global KimiSearch instance.
std::shared_ptr<KimiSearch> get_kimi_provider();

#endif // KIMI_SEARCH_H
