#include "zhipuai_search.h"
#include "search_provider.h"
#include "logger.h"
#include "tools.h"
#include <nlohmann/json.hpp>
#include <curl/curl.h>
#include <string>
#include <vector>
#include <chrono>
#include <algorithm>
#include <mutex>
#include <thread>

using json = nlohmann::json;

// ============================================================================
// Timeout constants
// ============================================================================

static const long REQUEST_TIMEOUT_SEC = 30L;
static const long CONNECT_TIMEOUT_SEC = 15L;
static const size_t MAX_RESPONSE_SIZE = 5 * 1024 * 1024; // 5MB

// ============================================================================
// Write callback — simple body capture
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
// Rate limit guard — serialize requests + cooldown + exponential backoff
// ============================================================================

static std::mutex g_zhipuai_mutex;
static std::chrono::steady_clock::time_point g_last_request_time;
static int g_consecutive_400_count = 0;
static const long BASE_COOLDOWN_MS = 500;

// ============================================================================
// TODO: Deferred API features (see design.md Non-Goals)
//   - search_domain_filter: whitelist domain filter (supported by search_pro_jina)
//   - search_recency_filter: oneDay|oneWeek|oneMonth|oneYear|noLimit
//   - request_id: 6-64 char unique request identifier
//   - user_id: 6-128 char end-user identifier
// ============================================================================

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
// Search implementation — standalone Web Search API POST + JSON parsing
// ============================================================================

ProviderResult ZhipuAISearch::search(
  const std::string& query,
  const std::string& depth,
  int max_results
) {
  // ---- Rate limit guard: serialize all ZhipuAI requests ----
  std::lock_guard<std::mutex> lock(g_zhipuai_mutex);

  ProviderResult result;
  (void)depth; // Web Search API does not support depth
  bool http_sent = false;
  long http_code = 0;
  std::string response_body;

  // ---- Input validation ----
  if (api_key_.empty()) {
    result.error = {"ZhipuAI API key not configured", false};
    // No HTTP sent — skip cooldown, release mutex immediately
    return result;
  }

  if (query.empty()) {
    result.error = {"ZhipuAI: search query is empty", false};
    return result;
  }

  // Clamp max_results to API limit (1-50)
  if (max_results < 1) max_results = 1;
  if (max_results > 50) max_results = 50;

  LOG_INFO("ZhipuAI search: query=\"" + query + "\" max_results=" + std::to_string(max_results));

  // ---- Build request body (standalone Web Search API format) ----
  json body;
  body["search_engine"] = search_engine_;
  body["search_query"] = query;
  body["count"] = max_results;

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
  http_sent = true; // HTTP request was actually sent

  // Check HTTP status code
  curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &http_code);

  curl_easy_cleanup(curl);
  curl_slist_free_all(headers);
  response_body = ctx.body;

  if (cres != CURLE_OK) {
    std::string err = "ZhipuAI: connection error — " + std::string(curl_easy_strerror(cres));
    LOG_ERR(err);
    result.error = {err, true};
    goto cooldown;
  }

  if (http_code >= 400) {
    std::string err = "ZhipuAI: HTTP " + std::to_string(http_code);
    // Parse error body: the API may return either flat {"code":...,"message":"..."}
    // or nested {"error":{"code":"...","message":"..."}} format. Try both.
    try {
      auto err_json = json::parse(ctx.body);
      if (err_json.contains("error") && err_json["error"].contains("message")) {
        err += " — " + err_json["error"]["message"].get<std::string>();
      } else if (err_json.contains("message") && err_json["message"].is_string()) {
        err += " — " + err_json["message"].get<std::string>();
      }
    } catch (...) {}
    LOG_ERR(err);
    // 429 from billing (余额不足) is NOT transient; only rate-limit 429 is transient.
    bool is_billing = (ctx.body.find("余额不足") != std::string::npos ||
                       ctx.body.find("资源包") != std::string::npos ||
                       ctx.body.find("1113") != std::string::npos);
    result.error = {err, (http_code == 429 && !is_billing) || http_code >= 500};
    goto cooldown;
  }

  // ---- Parse JSON response ----
  LOG_INFO("ZhipuAI: response HTTP " + std::to_string(http_code) + " body_len=" + std::to_string(ctx.body.size()));
  try {
    auto resp = json::parse(ctx.body);

    // Log top-level id/created for tracing (not exposed to upper layers)
    if (resp.contains("id")) {
      LOG_INFO("ZhipuAI: request id=" + resp["id"].get<std::string>());
    }

    // Parse search_result[] — the only result source (no synthesized answer)
    if (resp.contains("search_result") && resp["search_result"].is_array()) {
      for (auto& item : resp["search_result"]) {
        SearchResult r;
        if (item.contains("title")) r.title = item["title"].get<std::string>();
        if (item.contains("link")) r.url = item["link"].get<std::string>();
        if (item.contains("content")) r.content = item["content"].get<std::string>();
        // Include results that have at least title+link OR non-empty content
        if (!r.content.empty() || (!r.title.empty() && !r.url.empty())) {
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

cooldown:
  // ---- Post-request cooldown + exponential backoff (lock still held) ----
  if (http_sent) {
    // Update backoff counter
    if (http_code == 400) {
      bool is_moderation = (response_body.find("不安全") != std::string::npos ||
                            response_body.find("敏感") != std::string::npos);
      if (is_moderation) {
        g_consecutive_400_count++;
      } else {
        g_consecutive_400_count = 0;
      }
    } else {
      g_consecutive_400_count = 0; // reset on any non-400 response
    }

    // Compute cooldown with exponential backoff
    long cooldown_ms = BASE_COOLDOWN_MS;
    if (g_consecutive_400_count > 0) {
      int shift = std::min(g_consecutive_400_count, 3); // max 3 doublings
      cooldown_ms = BASE_COOLDOWN_MS * (1 << shift);     // 500 → 1000 → 2000 → 4000
    }

    auto now = std::chrono::steady_clock::now();
    if (g_last_request_time.time_since_epoch().count() > 0) {
      auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
        now - g_last_request_time).count();
      if (elapsed < cooldown_ms) {
        long sleep_ms = cooldown_ms - elapsed;
        LOG_INFO("ZhipuAI: cooldown sleep " + std::to_string(sleep_ms) + "ms" +
                 (g_consecutive_400_count > 0
                   ? " (backoff x" + std::to_string(1 << std::min(g_consecutive_400_count, 3)) + ")"
                   : ""));
        std::this_thread::sleep_for(std::chrono::milliseconds(sleep_ms));
      }
    }
    g_last_request_time = std::chrono::steady_clock::now();
  }

  return result;
  // lock_guard releases mutex here
}
