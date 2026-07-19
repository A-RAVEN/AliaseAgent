#include "searxng_search.h"
#include "logger.h"
#include "tools.h"
#include <nlohmann/json.hpp>
#include <curl/curl.h>
#include <string>
#include <vector>
#include <algorithm>

using json = nlohmann::json;

// ============================================================================
// Constants (task 5.4)
// ============================================================================

static const long SEARXNG_TIMEOUT_SEC = 5L;
static const long SEARXNG_CONNECT_TIMEOUT_SEC = 3L;

// ============================================================================
// Global provider instance
// ============================================================================

static std::shared_ptr<SearXNGSelfHost> g_searxng_instance;

std::shared_ptr<SearXNGSelfHost> get_searxng_provider() {
  if (!g_searxng_instance) {
    g_searxng_instance = std::make_shared<SearXNGSelfHost>();
  }
  return g_searxng_instance;
}

// ============================================================================
// is_configured — returns cached TCP liveness result
// ============================================================================

bool SearXNGSelfHost::is_configured() const {
  // SearXNG doesn't need an API key — it's "configured" if it was reachable
  // during ensure_search_infra's one-time TCP check.
  return available_;
}

// ============================================================================
// Write callback — simple buffer accumulator
// ============================================================================

struct SearXNGWriteCtx {
  std::string body;
};

static size_t searxng_write_callback(char* ptr, size_t size, size_t nmemb, void* userdata) {
  auto* ctx = static_cast<SearXNGWriteCtx*>(userdata);
  size_t total = size * nmemb;
  ctx->body.append(ptr, total);
  return total;
}

// ============================================================================
// Search implementation (tasks 5.2, 5.3, 5.4)
// ============================================================================

ProviderResult SearXNGSelfHost::search(
  const std::string& query,
  const std::string& /* depth */,  // depth is ignored for SearXNG (task 5.2)
  int max_results
) {
  ProviderResult result;

  if (query.empty()) {
    result.error = {"Search query is empty", false};
    return result;
  }

  LOG_INFO("SearXNG search: query=\"" + query + "\" max_results=" + std::to_string(max_results));

  // Build URL with URL-encoded query (task 5.2)
  CURL* curl = curl_easy_init();
  if (!curl) {
    result.error = {"SearXNG: curl_easy_init failed", false};
    return result;
  }

  // URL-encode the query
  char* encoded_query = curl_easy_escape(curl, query.c_str(), static_cast<int>(query.size()));
  if (!encoded_query) {
    curl_easy_cleanup(curl);
    result.error = {"SearXNG: URL encoding failed", false};
    return result;
  }

  std::string url = base_url_ + "/search?q=" + std::string(encoded_query) + "&format=json";
  curl_free(encoded_query);

  LOG_INFO("SearXNG: GET " + url);

  // Setup curl (task 5.4: 5s timeout)
  SearXNGWriteCtx write_ctx;
  curl_easy_setopt(curl, CURLOPT_URL, url.c_str());
  curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, searxng_write_callback);
  curl_easy_setopt(curl, CURLOPT_WRITEDATA, &write_ctx);
  curl_easy_setopt(curl, CURLOPT_TIMEOUT, SEARXNG_TIMEOUT_SEC);
  curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT, SEARXNG_CONNECT_TIMEOUT_SEC);
  curl_easy_setopt(curl, CURLOPT_USERAGENT, "AliasAgent/1.0");
  curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 1L);
  // SearXNG is localhost HTTP — no SSL needed

  // Execute
  CURLcode cres = curl_easy_perform(curl);

  // Check HTTP status code first
  long http_code = 0;
  curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &http_code);
  curl_easy_cleanup(curl);

  if (cres != CURLE_OK) {
    std::string curl_err = curl_easy_strerror(cres);
    LOG_ERR("SearXNG: connection error — " + curl_err);

    if (cres == CURLE_OPERATION_TIMEDOUT || cres == CURLE_COULDNT_CONNECT) {
      result.error = {"SearXNG unavailable", true};
    } else {
      result.error = {"SearXNG: " + curl_err, true};
    }
    return result;
  }

  // Task 5.3: HTTP 403 — format:json not enabled
  if (http_code == 403) {
    result.error = {"SearXNG returned HTTP 403 — ensure format: json is enabled in settings.yml", false};
    return result;
  }

  // HTTP 5xx
  if (http_code >= 500) {
    result.error = {"SearXNG server error (HTTP " + std::to_string(http_code) + ")", true};
    return result;
  }

  // Other HTTP errors
  if (http_code >= 400) {
    result.error = {"SearXNG returned HTTP " + std::to_string(http_code), false};
    return result;
  }

  // Parse JSON response (task 5.2)
  try {
    auto resp = json::parse(write_ctx.body);

    if (!resp.contains("results") || !resp["results"].is_array()) {
      LOG_WARN("SearXNG: response missing 'results' array");
      result.error = {"SearXNG: unexpected response format", false};
      return result;
    }

    auto& results_array = resp["results"];

    // Client-side truncation to max_results
    int count = 0;
    for (auto& item : results_array) {
      if (count >= max_results) break;

      SearchResult r;
      if (item.contains("title")) r.title = item["title"].get<std::string>();
      if (item.contains("url")) r.url = item["url"].get<std::string>();
      if (item.contains("content")) r.content = item["content"].get<std::string>();

      // Skip results with no content (malformed entries)
      if (r.content.empty() && r.title.empty() && r.url.empty()) continue;

      result.results.push_back(std::move(r));
      count++;
    }

    LOG_INFO("SearXNG: " + std::to_string(result.results.size()) + " results (from " +
             std::to_string(results_array.size()) + " total)");

  } catch (const json::parse_error& e) {
    LOG_ERR("SearXNG: JSON parse error — " + std::string(e.what()));
    result.error = {"SearXNG: failed to parse response", false};
    return result;
  }

  return result;
}
