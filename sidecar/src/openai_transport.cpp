#include "openai_transport.h"
#include "logger.h"
#include <nlohmann/json.hpp>
#include <string>
#include <cstring>
#include <algorithm>
#include <cctype>

using json = nlohmann::json;

// ============================================================================
// OpenAI HTTP request builder (task 2.2)
// ============================================================================

std::string build_openai_request(
  const std::string& model,
  const std::string& messages_json,
  const std::string& tools_json,
  const std::string& tool_choice_json,
  const std::string& extra_body_json
) {
  try {
    json body;
    body["model"] = model;
    body["stream"] = true;

    body["messages"] = json::parse(messages_json);

    if (!tools_json.empty() && tools_json != "[]") {
      body["tools"] = json::parse(tools_json);
    }

    if (!tool_choice_json.empty() && tool_choice_json != "null") {
      body["tool_choice"] = json::parse(tool_choice_json);
    }

    // Merge extra fields
    if (!extra_body_json.empty() && extra_body_json != "{}") {
      auto extra = json::parse(extra_body_json);
      for (auto& [key, val] : extra.items()) {
        body[key] = val;
      }
    }

    return body.dump();
  } catch (const json::parse_error& e) {
    LOG_ERR("build_openai_request: JSON parse error — " + std::string(e.what()));
    return "{}";
  }
}

// ============================================================================
// OpenAI SSE write callback (tasks 2.1, 2.3, 2.4, 2.5)
// ============================================================================

/// Parse an SSE "data:" line containing an OpenAI-format JSON event.
static void parse_openai_event(OpenAITransferCtx* ctx, const std::string& data) {
  if (data == "[DONE]") {
    LOG_INFO("OpenAI SSE: [DONE] marker");
    ctx->state.finished = true;
    if (ctx->callbacks.on_finish) {
      ctx->callbacks.on_finish("stop");
    }
    return;
  }

  try {
    auto ev = json::parse(data);

    // Check for top-level error
    if (ev.contains("error")) {
      std::string err_msg = ev["error"].value("message", ev["error"].is_string()
        ? ev["error"].get<std::string>()
        : "Unknown API error");
      LOG_ERR("OpenAI SSE: error \"" + err_msg + "\"");
      ctx->state.error_message = err_msg;
      ctx->state.finished = true;
      if (ctx->callbacks.on_error) ctx->callbacks.on_error(err_msg);
      return;
    }

    // Check choices array
    if (!ev.contains("choices") || !ev["choices"].is_array() || ev["choices"].empty()) {
      return; // ping or other non-choice event — ignore silently
    }

    auto& choice = ev["choices"][0];

    // finish_reason
    if (choice.contains("finish_reason") && !choice["finish_reason"].is_null()) {
      std::string reason = choice["finish_reason"].get<std::string>();
      LOG_INFO("OpenAI SSE: finish_reason=" + reason);
      ctx->state.finished = true;
      ctx->state.finish_reason = reason;
      if (ctx->callbacks.on_finish) ctx->callbacks.on_finish(reason);
    }

    // delta
    if (choice.contains("delta")) {
      auto& delta = choice["delta"];

      // Text content: delta.content
      if (delta.contains("content") && !delta["content"].is_null()) {
        std::string text = delta["content"].get<std::string>();
        if (!text.empty()) {
          LOG_INFO("OpenAI SSE: text_delta len=" + std::to_string(text.size()));
          if (ctx->callbacks.on_text) ctx->callbacks.on_text(text);
        }
      }

      // Tool calls: delta.tool_calls[]
      if (delta.contains("tool_calls") && delta["tool_calls"].is_array()) {
        for (auto& tc : delta["tool_calls"]) {
          int idx = tc.value("index", -1);
          if (idx < 0) continue;

          // Capture tool_call id (task 2.5)
          if (tc.contains("id") && !tc["id"].is_null()) {
            ctx->state.tool_call_ids[idx] = tc["id"].get<std::string>();
            LOG_INFO("OpenAI SSE: tool_call id=" + ctx->state.tool_call_ids[idx] + " index=" + std::to_string(idx));
          }

          // Capture function name
          if (tc.contains("function") && tc["function"].is_object()) {
            auto& func = tc["function"];
            if (func.contains("name") && !func["name"].is_null()) {
              ctx->state.function_names[idx] = func["name"].get<std::string>();
              LOG_INFO("OpenAI SSE: tool_call function.name=" + ctx->state.function_names[idx]);
            }

            // Accumulate function.arguments delta by index (task 2.5)
            if (func.contains("arguments") && !func["arguments"].is_null()) {
              std::string args = func["arguments"].get<std::string>();
              // Check aggregate cap (1MB per event)
              if (ctx->state.aggregate_size + args.size() > AGGREGATE_MAX) {
                ctx->aborted = true;
                ctx->abort_reason = "SSE tool_call arguments exceeded 1MB aggregate cap";
                LOG_ERR(ctx->abort_reason);
                return;
              }
              ctx->state.aggregate_size += args.size();
              ctx->state.accumulated_args[idx] += args;
              LOG_INFO("OpenAI SSE: tool_call arguments delta index=" + std::to_string(idx)
                       + " len=" + std::to_string(args.size())
                       + " total=" + std::to_string(ctx->state.accumulated_args[idx].size()));
            }
          }
        }
      }
    }
  } catch (const json::parse_error& e) {
    ctx->state.parse_errors++;
    LOG_ERR("OpenAI SSE: JSON parse failed — " + std::string(e.what())
            + " raw=" + data.substr(0, 512));
    if (ctx->state.parse_errors > MAX_PARSE_ERRORS) {
      ctx->aborted = true;
      ctx->abort_reason = "Excessive SSE parse errors (" + std::to_string(ctx->state.parse_errors) + ")";
      LOG_ERR(ctx->abort_reason);
      if (ctx->callbacks.on_error) ctx->callbacks.on_error(ctx->abort_reason);
    }
  }
}

/// Flush accumulated tool call arguments into structured JSON events.
/// Called after finish_reason is received.
static void flush_pending_tool_calls(OpenAITransferCtx* ctx) {
  for (auto& [idx, args] : ctx->state.accumulated_args) {
    if (args.empty()) continue;

    json tc_event;
    tc_event["index"] = idx;
    tc_event["id"] = ctx->state.tool_call_ids.count(idx)
      ? ctx->state.tool_call_ids[idx] : "";
    tc_event["function"]["name"] = ctx->state.function_names.count(idx)
      ? ctx->state.function_names[idx] : "";
    tc_event["function"]["arguments"] = args;

    LOG_INFO("OpenAI SSE: tool_call final index=" + std::to_string(idx)
             + " id=" + tc_event["id"].get<std::string>()
             + " name=" + tc_event["function"]["name"].get<std::string>()
             + " args_len=" + std::to_string(args.size()));

    if (ctx->callbacks.on_tool_call) {
      ctx->callbacks.on_tool_call(tc_event.dump());
    }
  }
  ctx->state.accumulated_args.clear();
}

// ---------------------------------------------------------------------------
// Curl write callback — line-buffered SSE parsing
// ---------------------------------------------------------------------------

size_t openai_write_callback(char* ptr, size_t size, size_t nmemb, void* userdata) {
  auto* ctx = static_cast<OpenAITransferCtx*>(userdata);
  size_t total = size * nmemb;

  // Append to raw_body buffer (capped at 64KB) for error logging
  if (ctx->raw_body.size() < RAW_BODY_MAX) {
    size_t remaining = RAW_BODY_MAX - ctx->raw_body.size();
    size_t to_append = total < remaining ? total : remaining;
    ctx->raw_body.append(ptr, to_append);
  }

  for (size_t i = 0; i < total; ++i) {
    char c = ptr[i];

    // Task 2.4: line_buf 64KB cap — applies to BOTH model_gateway.cpp and new SSE handlers
    if (ctx->line_buf.size() >= LINE_BUF_MAX) {
      ctx->aborted = true;
      ctx->abort_reason = "SSE line exceeded 64KB cap";
      LOG_ERR(ctx->abort_reason);
      if (ctx->callbacks.on_error) ctx->callbacks.on_error(ctx->abort_reason);
      return 0; // abort transfer
    }

    if (c == '\n') {
      std::string line = ctx->line_buf;
      ctx->line_buf.clear();
      if (!line.empty() && line.back() == '\r') line.pop_back();
      if (line.empty()) continue;

      // SSE data line
      if (line.rfind("data: ", 0) == 0) {
        std::string data = line.substr(6);
        parse_openai_event(ctx, data);
      }

      if (ctx->aborted) return 0;
    } else {
      ctx->line_buf += c;
    }
  }

  return total;
}

// ============================================================================
// Curl handle setup (task 2.6)
// ============================================================================

CURL* create_openai_curl_handle(
  const std::string& url,
  const std::string& api_key,
  const std::string& body_str,
  long timeout_sec,
  long connect_timeout_sec
) {
  CURL* curl = curl_easy_init();
  if (!curl) return nullptr;

  struct curl_slist* headers = nullptr;
  headers = curl_slist_append(headers, "Content-Type: application/json");
  std::string auth = "Authorization: Bearer " + api_key;
  headers = curl_slist_append(headers, auth.c_str());

  curl_easy_setopt(curl, CURLOPT_URL, url.c_str());
  curl_easy_setopt(curl, CURLOPT_POST, 1L);
  curl_easy_setopt(curl, CURLOPT_POSTFIELDS, body_str.c_str());
  curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE, (long)body_str.size());
  curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);
  curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, openai_write_callback);
  curl_easy_setopt(curl, CURLOPT_TIMEOUT, timeout_sec);
  curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT, connect_timeout_sec);
  curl_easy_setopt(curl, CURLOPT_USERAGENT, "AliasAgent/1.0");
  curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, 1L);
  curl_easy_setopt(curl, CURLOPT_ACCEPT_ENCODING, ""); // enable gzip/deflate decompression

  return curl;
}
