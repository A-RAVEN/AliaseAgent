#include "kimi_search.h"
#include "openai_transport.h"
#include "logger.h"
#include "tools.h"
#include <nlohmann/json.hpp>
#include <curl/curl.h>
#include <string>
#include <vector>
#include <thread>
#include <chrono>
#include <sstream>

using json = nlohmann::json;

// ============================================================================
// Constants
// ============================================================================

static const long KIMI_TIMEOUT_SEC = 30L;
static const long KIMI_CONNECT_TIMEOUT_SEC = 15L;
static const int MAX_429_RETRIES = 2; // task 6.6

// ============================================================================
// Global provider instance
// ============================================================================

static std::shared_ptr<KimiSearch> g_kimi_instance;

std::shared_ptr<KimiSearch> get_kimi_provider() {
  if (!g_kimi_instance) {
    g_kimi_instance = std::make_shared<KimiSearch>();
  }
  return g_kimi_instance;
}

// ============================================================================
// Tool definition (task 6.3)
// ============================================================================

/// Build the $web_search builtin function tool definition JSON.
static std::string kimi_web_search_tool_json() {
  json tools = json::array();
  json tool;
  tool["type"] = "builtin_function";
  tool["function"]["name"] = "$web_search";
  tools.push_back(tool);
  return tools.dump();
}

/// Build the tool_choice for Kimi. Use "auto" — the model decides when to search.
/// Per Kimi docs, when thinking is disabled, tool_choice can be any valid value.
static std::string kimi_tool_choice_json() {
  return "\"auto\"";
}

/// Build the thinking disabled field (task 6.2).
static std::string kimi_extra_body_json() {
  json extra;
  extra["thinking"]["type"] = "disabled";
  return extra.dump();
}

// ============================================================================
// Build messages for Kimi
// ============================================================================

static std::string build_kimi_messages(const std::string& query) {
  json msgs = json::array();

  json system_msg;
  system_msg["role"] = "system";
  system_msg["content"] = "You are a helpful search assistant. Use the $web_search tool to find current information.";
  msgs.push_back(system_msg);

  json user_msg;
  user_msg["role"] = "user";
  user_msg["content"] = query;
  msgs.push_back(user_msg);

  return msgs.dump();
}

// ============================================================================
// is_configured
// ============================================================================

bool KimiSearch::is_configured() const {
  return !api_key_.empty();
}

// ============================================================================
// perform_request — single HTTP POST + SSE parse (task 6.3)
// ============================================================================

bool KimiSearch::perform_request(
  const std::string& messages_json,
  std::string& result_json,
  std::string& text_answer,
  std::string& error_msg,
  long& http_code
) const {
  std::string tools_json = kimi_web_search_tool_json();
  std::string tool_choice_json = kimi_tool_choice_json();
  std::string extra_json = kimi_extra_body_json();

  std::string body = build_openai_request(
    model_, messages_json, tools_json, tool_choice_json, extra_json
  );

  CURL* curl = create_openai_curl_handle(
    base_url_, api_key_, body, KIMI_TIMEOUT_SEC, KIMI_CONNECT_TIMEOUT_SEC
  );
  if (!curl) {
    error_msg = "Kimi: curl_easy_init failed";
    return false;
  }

  OpenAITransferCtx ctx;
  std::string captured_args;
  std::string captured_tool_id;

  ctx.callbacks.on_text = [&text_answer](const std::string& text) {
    text_answer += text;
  };

  ctx.callbacks.on_tool_call = [&captured_args, &captured_tool_id](const std::string& tc_json) {
    try {
      auto tc = json::parse(tc_json);
      captured_args = tc["function"]["arguments"].get<std::string>();
      captured_tool_id = tc.value("id", "");
      LOG_INFO("Kimi: tool_call captured — id=" + captured_tool_id +
               " args_len=" + std::to_string(captured_args.size()));
    } catch (const json::parse_error& e) {
      LOG_ERR("Kimi: failed to parse tool_call JSON — " + std::string(e.what()));
    }
  };

  ctx.callbacks.on_error = [&error_msg](const std::string& err) {
    error_msg = err;
    LOG_ERR("Kimi SSE error: " + err);
  };

  curl_easy_setopt(curl, CURLOPT_WRITEDATA, &ctx);

  LOG_INFO("Kimi: POST " + base_url_);

  CURLcode cres = curl_easy_perform(curl);
  curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &http_code);
  curl_easy_cleanup(curl);

  if (cres != CURLE_OK) {
    error_msg = "Kimi: connection error — " + std::string(curl_easy_strerror(cres));
    LOG_ERR(error_msg);
    return false;
  }

  // Flush accumulated tool calls from SSE deltas
  for (auto& [idx, args] : ctx.state.accumulated_args) {
    if (args.empty()) continue;
    captured_args = args;
    if (ctx.state.tool_call_ids.count(idx)) {
      captured_tool_id = ctx.state.tool_call_ids[idx];
    }
  }

  // If HTTP error, include raw body in error message for debugging
  if (http_code >= 400) {
    error_msg = "HTTP " + std::to_string(http_code);
    if (!ctx.raw_body.empty()) {
      error_msg += " — " + ctx.raw_body.substr(0, 300);
    }
    return false;
  }

  // Check for stream-level errors
  if (ctx.aborted) {
    error_msg = ctx.abort_reason;
    return false;
  }

  if (ctx.state.parse_errors > MAX_PARSE_ERRORS) {
    error_msg = "Excessive SSE parse errors";
    return false;
  }

  if (!ctx.state.error_message.empty()) {
    error_msg = ctx.state.error_message;
    return false;
  }

  result_json = captured_args; // NO-OP relay: pass through as-is
  return true;
}

// ============================================================================
// search implementation (tasks 6.1-6.7)
// ============================================================================

ProviderResult KimiSearch::search(
  const std::string& query,
  const std::string& /* depth */,
  int max_results
) {
  (void)max_results; // Kimi returns a single synthesized answer, max_results not meaningful

  ProviderResult result;

  if (api_key_.empty()) {
    result.error = {"Kimi API key not configured", false};
    return result;
  }

  LOG_INFO("Kimi search: query=\"" + query + "\"");

  // Build initial messages
  json msgs = json::parse(build_kimi_messages(query));

  // Multi-turn loop: up to 2 turns
  // Turn 1: model calls $web_search → we capture args
  // Turn 2: we respond with tool_result → model generates answer
  for (int turn = 0; turn < 2; turn++) {
    std::string messages_json = msgs.dump();
    std::string tool_args;
    std::string text_answer;
    std::string error_msg;
    long http_code = 0;

    // Task 6.6: 429 retry logic (Kimi-only)
    bool request_ok = false;
    for (int retry = 0; retry <= MAX_429_RETRIES; retry++) {
      error_msg.clear();
      text_answer.clear();
      tool_args.clear();

      request_ok = perform_request(messages_json, tool_args, text_answer, error_msg, http_code);

      if (http_code == 429 && retry < MAX_429_RETRIES) {
        // Exponential backoff: 1s, 2s
        int delay_sec = retry + 1;
        LOG_WARN("Kimi: HTTP 429 — retrying in " + std::to_string(delay_sec) + "s (attempt " +
                 std::to_string(retry + 1) + "/" + std::to_string(MAX_429_RETRIES) + ")");
        std::this_thread::sleep_for(std::chrono::seconds(delay_sec));
        continue;
      }
      break;
    }

    // After retries — check result
    if (!request_ok) {
      result.error = {error_msg.empty() ? "Kimi request failed" : error_msg, true};
      return result;
    }

    if (http_code >= 400) {
      if (http_code == 401 || http_code == 403) {
        result.error = {"Kimi API authentication failed (HTTP " + std::to_string(http_code) + ")", false};
      } else if (http_code == 429) {
        result.error = {"Kimi rate limited (HTTP 429) — retries exhausted", true};
      } else {
        result.error = {"Kimi API error (HTTP " + std::to_string(http_code) + ")", http_code >= 500};
      }
      return result;
    }

    // Check if we got a tool_call (Turn 1) or text answer (Turn 2)
    if (!tool_args.empty()) {
      // Task 6.3: NO-OP relay — pass arguments back as tool_result
      // Add assistant message with tool_calls
      json asst_msg;
      asst_msg["role"] = "assistant";
      asst_msg["content"] = json(nullptr);
      json tc_array = json::array();
      json tc;
      tc["id"] = "call_kimi_search";
      tc["type"] = "builtin_function";
      tc["function"]["name"] = "$web_search";
      tc["function"]["arguments"] = tool_args;
      tc_array.push_back(tc);
      asst_msg["tool_calls"] = tc_array;
      msgs.push_back(asst_msg);

      // Add tool_result message (NO-OP: relay args as result)
      json tr_msg;
      tr_msg["role"] = "tool";
      tr_msg["tool_call_id"] = "call_kimi_search";
      tr_msg["content"] = tool_args; // NO-OP relay
      msgs.push_back(tr_msg);

      LOG_INFO("Kimi: NO-OP relay complete — continuing to collect answer");
      continue;
    }

    if (!text_answer.empty()) {
      // Task 6.4: Normalize — single SearchResult with synthesized answer
      SearchResult r;
      r.title = "";    // Kimi synthesized answers have no title
      r.url = "";      // Kimi synthesized answers have no URL
      r.content = text_answer;
      result.results.push_back(std::move(r));

      LOG_INFO("Kimi search: answer len=" + std::to_string(text_answer.size()));
      return result;
    }

    // No tool_call AND no text answer — error (task 6.5)
    if (turn == 0) {
      result.error = {"Kimi did not invoke $web_search and returned empty response", false};
    } else {
      result.error = {"Kimi returned empty response", false};
    }
    return result;
  }

  // Exhausted turns without answer
  result.error = {"Kimi: exceeded max turns without answer", false};
  return result;
}
