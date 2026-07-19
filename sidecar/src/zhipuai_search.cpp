#include "zhipuai_search.h"
#include "search_provider.h"
#include "logger.h"
#include "tools.h"
#include <nlohmann/json.hpp>
#include <curl/curl.h>
#include <string>
#include <vector>
#include <chrono>

using json = nlohmann::json;

// ============================================================================
// Timeout constants
// ============================================================================

static const long REQUEST_TIMEOUT_SEC = 30L;
static const long CONNECT_TIMEOUT_SEC = 15L;
static const size_t MAX_RESPONSE_SIZE = 5 * 1024 * 1024; // 5MB

// ============================================================================
// Non-streaming write callback — simple body capture
// ============================================================================

struct WriteCtx {
  std::string body;
};

static size_t write_callback(char* ptr, size_t size, size_t nmemb, void* userdata) {
  auto* ctx = static_cast<WriteCtx*>(userdata);
  size_t total = size * nmemb;
  if (ctx->body.size() + total > MAX_RESPONSE_SIZE) {
    LOG_ERR("ZhipuAI: response exceeded " + std::to_string(MAX_RESPONSE_SIZE) + " bytes");
    return 0; // abort transfer
  }
  ctx->body.append(ptr, total);
  return total;
}

// ============================================================================
// Tool definition
// ============================================================================

/// Build the web_search tool definition for ZhipuAI Chat Completions.
/// Per official docs (docs.bigmodel.cn), the tool requires a nested
/// "web_search" object. search_result=true ensures the response includes
/// the top-level web_search[] array.
static std::string web_search_tool_json(int max_results) {
  json tool;
  tool["type"] = "web_search";
  // Per official docs, the API expects string values for these fields
  // (Python SDK uses "True"/"False" strings, not JSON booleans)
  tool["web_search"]["enable"] = "True";
  tool["web_search"]["search_result"] = "True";
  tool["web_search"]["count"] = std::to_string(max_results);
  return json::array({tool}).dump();
}

// ============================================================================
// Global provider instance
// ============================================================================

static std::shared_ptr<ZhipuAISearch> g_zhipuai_instance;

std::shared_ptr<ZhipuAISearch> get_zhipuai_provider() {
  if (!g_zhipuai_instance) {
    g_zhipuai_instance = std::make_shared<ZhipuAISearch>();
  }
  return g_zhipuai_instance;
}

// ============================================================================
// is_configured
// ============================================================================

bool ZhipuAISearch::is_configured() const {
  return !api_key_.empty();
}

// ============================================================================
// Search implementation — non-streaming HTTP POST + JSON parsing
// ============================================================================

ProviderResult ZhipuAISearch::search(
  const std::string& query,
  const std::string& depth,
  int max_results
) {
  ProviderResult result;
  (void)depth; // depth ignored — web_search controls depth automatically

  if (api_key_.empty()) {
    result.error = {"ZhipuAI API key not configured", false};
    return result;
  }

  LOG_INFO("ZhipuAI search: query=\"" + query + "\" max_results=" + std::to_string(max_results));

  // ---- Build request body ----
  json body;
  body["model"] = model_;
  body["stream"] = false;
  body["messages"] = json::array({
    {{"role", "system"}, {"content", "You are a web search assistant. Use the web_search tool to find current, accurate information."}},
    {{"role", "user"}, {"content", query}}
  });
  body["tools"] = json::parse(web_search_tool_json(max_results));
  // Omit tool_choice — model decides whether to use web_search.
  // Glm-4.7-flash automatically invokes web_search when the tool is registered.

  std::string body_str = body.dump();

  // ---- Create curl handle ----
  CURL* curl = curl_easy_init();
  if (!curl) {
    result.error = {"ZhipuAI: curl_easy_init failed", false};
    return result;
  }

  struct curl_slist* headers = nullptr;
  headers = curl_slist_append(headers, "Content-Type: application/json");
  std::string auth = "Authorization: Bearer " + api_key_;
  headers = curl_slist_append(headers, auth.c_str());

  curl_easy_setopt(curl, CURLOPT_URL, base_url_.c_str());
  curl_easy_setopt(curl, CURLOPT_POST, 1L);
  curl_easy_setopt(curl, CURLOPT_POSTFIELDS, body_str.c_str());
  curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE, (long)body_str.size());
  curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);
  curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, write_callback);
  curl_easy_setopt(curl, CURLOPT_TIMEOUT, REQUEST_TIMEOUT_SEC);
  curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT, CONNECT_TIMEOUT_SEC);
  curl_easy_setopt(curl, CURLOPT_USERAGENT, "AliasAgent/1.0");
  curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, 1L);
  curl_easy_setopt(curl, CURLOPT_ACCEPT_ENCODING, "");

  // ---- Perform request ----
  WriteCtx ctx;
  curl_easy_setopt(curl, CURLOPT_WRITEDATA, &ctx);

  LOG_INFO("ZhipuAI: POST " + base_url_);
  CURLcode cres = curl_easy_perform(curl);

  // Check HTTP status code
  long http_code = 0;
  curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &http_code);

  curl_easy_cleanup(curl);
  curl_slist_free_all(headers);

  if (cres != CURLE_OK) {
    std::string err = "ZhipuAI: connection error — " + std::string(curl_easy_strerror(cres));
    LOG_ERR(err);
    result.error = {err, true};
    return result;
  }

  if (http_code >= 400) {
    std::string err = "ZhipuAI: HTTP " + std::to_string(http_code);
    // Try to extract error detail from response body
    try {
      auto err_json = json::parse(ctx.body);
      if (err_json.contains("error") && err_json["error"].contains("message")) {
        err += " — " + err_json["error"]["message"].get<std::string>();
      }
    } catch (...) {}
    LOG_ERR(err);
    result.error = {err, http_code == 429 || http_code >= 500};
    return result;
  }

  // ---- Parse JSON response ----
  LOG_INFO("ZhipuAI: response HTTP " + std::to_string(http_code) + " body_len=" + std::to_string(ctx.body.size()));
  try {
    auto resp = json::parse(ctx.body);

    // Parse web_search[] — top-level array with structured search results
    if (resp.contains("web_search") && resp["web_search"].is_array()) {
      for (auto& item : resp["web_search"]) {
        SearchResult r;
        if (item.contains("title")) r.title = item["title"].get<std::string>();
        if (item.contains("link")) r.url = item["link"].get<std::string>();
        if (item.contains("content")) r.content = item["content"].get<std::string>();
        if (!r.content.empty() || !r.title.empty() || !r.url.empty()) {
          result.results.push_back(std::move(r));
        }
      }
    }

    // Apply client-side truncation to web_search results
    if (static_cast<int>(result.results.size()) > max_results) {
      result.results.resize(max_results);
    }

    // Parse message.content — synthesized answer with [来源：ref_N] references
    if (resp.contains("choices") && resp["choices"].is_array() && !resp["choices"].empty()) {
      auto& choice = resp["choices"][0];
      if (choice.contains("message") && choice["message"].contains("content")) {
        std::string answer = choice["message"]["content"].get<std::string>();
        if (!answer.empty()) {
          SearchResult r;
          r.title = "";
          r.url = "";
          r.content = std::move(answer);
          result.results.push_back(std::move(r));
        }
      }
    }

    LOG_INFO("ZhipuAI search: " + std::to_string(result.results.size()) + " results");

  } catch (const json::parse_error& e) {
    LOG_ERR("ZhipuAI: failed to parse response JSON — " + std::string(e.what()));
    LOG_ERR("ZhipuAI: raw body prefix=" + ctx.body.substr(0, 512));
    result.error = {"ZhipuAI: invalid JSON response", false};
  }

  return result;
}
