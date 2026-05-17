#include "model_gateway.h"
#include "logger.h"
#include <curl/curl.h>
#include <nlohmann/json.hpp>
#include <string>
#include <vector>
#include <sstream>
#include <cstring>
#include <atomic>

using json = nlohmann::json;

// ---------------------------------------------------------------------------
// Buffered SSE event (parsed after curl completes, while strings are alive)
// ---------------------------------------------------------------------------

enum class SseEventKind { CHUNK, TOOL_CALL, DONE };

struct SseEvent {
  SseEventKind kind;
  std::string text;      // for CHUNK
  std::string tool_json; // for TOOL_CALL
  int done_code = 0;     // for DONE
  std::string done_err;  // for DONE
};

// ---------------------------------------------------------------------------
// Internal state
// ---------------------------------------------------------------------------

struct ModelGateway::Impl {
  CURL* curl = nullptr;
  struct curl_slist* headers = nullptr;
  long timeout_secs = 120;

  // Buffered events — populated during SSE parsing, dispatched after curl
  std::vector<SseEvent> events;
  // SSE parsing state
  std::string line_buf;
  bool done_dispatched = false;

  int request_id = 0;
  static std::atomic<int> next_request_id;
};

std::atomic<int> ModelGateway::Impl::next_request_id{1};

// ---------------------------------------------------------------------------
// CURL write callback — only accumulates lines + feeds SSE parser
// Callbacks are NOT invoked here; events are buffered for dispatch after curl
// ---------------------------------------------------------------------------

static size_t write_callback(char* ptr, size_t size, size_t nmemb, void* userdata) {
  auto* impl = static_cast<ModelGateway::Impl*>(userdata);
  size_t total = size * nmemb;

  for (size_t i = 0; i < total; ++i) {
    char c = ptr[i];
    if (c == '\n') {
      std::string line = impl->line_buf;
      impl->line_buf.clear();
      if (!line.empty() && line.back() == '\r') line.pop_back();
      if (line.empty()) continue;

      // SSE data line
      if (line.rfind("data: ", 0) == 0) {
        std::string data = line.substr(6);

        if (data == "[DONE]") {
          LOG_INFO("SSE: [DONE] marker");
          impl->events.push_back({SseEventKind::DONE, "", "", 0, ""});
          impl->done_dispatched = true;
          continue;
        }

        try {
          auto ev = json::parse(data);
          std::string type = ev.value("type", "");

          if (type == "content_block_delta") {
            if (ev.contains("delta") && ev["delta"].contains("text")) {
              std::string text = ev["delta"]["text"];
              LOG_INFO("SSE: content_block_delta text=\"" + text + "\"");
              impl->events.push_back({SseEventKind::CHUNK, text, "", 0, ""});
            }
          }
          else if (type == "content_block_start") {
            if (ev.contains("content_block")) {
              auto& cb = ev["content_block"];
              if (cb.value("type", "") == "tool_use") {
                std::string tool_json = cb.dump();
                LOG_INFO("SSE: content_block_start tool_use " + tool_json);
                impl->events.push_back({SseEventKind::TOOL_CALL, "", tool_json, 0, ""});
              } else {
                LOG_INFO("SSE: content_block_start type=" + cb.value("type", ""));
              }
            }
          }
          else if (type == "message_stop") {
            LOG_INFO("SSE: message_stop");
            impl->events.push_back({SseEventKind::DONE, "", "", 0, ""});
            impl->done_dispatched = true;
          }
          else if (type == "error") {
            std::string msg = ev.value("error", json::object()).value("message", "Unknown API error");
            LOG_ERR("SSE: error \"" + msg + "\"");
            impl->events.push_back({SseEventKind::DONE, "", "", -1, msg});
            impl->done_dispatched = true;
          }
          else if (type == "message_start") {
            LOG_INFO("SSE: message_start");
          }
          else if (type == "content_block_stop") {
            LOG_INFO("SSE: content_block_stop index=" + std::to_string(ev.value("index", -1)));
          }
          else if (type == "message_delta") {
            LOG_INFO("SSE: message_delta");
          }
          else if (type == "ping") {
            // Ignore
          }
          else {
            LOG_WARN("SSE: unrecognized event type=\"" + type + "\" raw=" + data.substr(0, 200));
          }
        } catch (const json::parse_error& e) {
          LOG_ERR("SSE: JSON parse failed — " + std::string(e.what()) + " raw=" + data.substr(0, 512));
        }
      }
    } else {
      impl->line_buf += c;
    }
  }
  return total;
}

// ---------------------------------------------------------------------------
// Construction / destruction
// ---------------------------------------------------------------------------

ModelGateway::ModelGateway() : impl_(new Impl{}) {
  impl_->curl = curl_easy_init();
}

ModelGateway::~ModelGateway() {
  if (impl_->headers) curl_slist_free_all(impl_->headers);
  if (impl_->curl) curl_easy_cleanup(impl_->curl);
  delete impl_;
}

void ModelGateway::set_timeout(long seconds) {
  impl_->timeout_secs = seconds;
}

// ---------------------------------------------------------------------------
// Dispatch buffered events → callbacks
// All local strings (backed by impl_) are alive during dispatch.
// .listener queues callbacks to the event loop, but since this runs before
// the C function returns, the strings persist in g_gateway.impl_ until
// the next send_message call.
// ---------------------------------------------------------------------------

static void dispatch_events(ModelGateway::Impl* impl,
                             OnChunkCallback on_chunk,
                             OnToolCallCallback on_tool_call,
                             OnDoneCallback on_done) {
  for (auto& ev : impl->events) {
    switch (ev.kind) {
      case SseEventKind::CHUNK:
        if (on_chunk) on_chunk(ev.text.c_str());
        break;
      case SseEventKind::TOOL_CALL:
        if (on_tool_call) on_tool_call(ev.tool_json.c_str());
        break;
      case SseEventKind::DONE:
        if (on_done) on_done(ev.done_code, ev.done_err.empty() ? "" : ev.done_err.c_str());
        break;
    }
  }
}

// ---------------------------------------------------------------------------
// Main execution
// ---------------------------------------------------------------------------

int ModelGateway::execute(
  const char* api_key,
  const char* base_url,
  const char* model,
  const char* system_prompt,
  const char* messages_json,
  const char* tools_json,
  OnChunkCallback on_chunk,
  OnToolCallCallback on_tool_call,
  OnDoneCallback on_done
) {
  if (!impl_->curl) {
    LOG_ERR("CURL handle not initialized");
    if (on_done) on_done(-1, "Internal error: CURL not initialized");
    return -1;
  }

  int rid = impl_->next_request_id++;
  impl_->request_id = rid;
  impl_->events.clear();
  impl_->line_buf.clear();
  impl_->done_dispatched = false;

  LOG_INFO("=== Request #" + std::to_string(rid) + " start ===");

  // 5.1 — Build JSON request body
  json body;
  body["model"] = model;
  body["stream"] = true;
  body["max_tokens"] = 4096;

  if (system_prompt && std::strlen(system_prompt) > 0) {
    body["system"] = system_prompt;
  }

  try {
    body["messages"] = json::parse(messages_json);
  } catch (const json::parse_error& e) {
    LOG_ERR("Failed to parse messages_json: " + std::string(e.what()));
    if (on_done) on_done(-1, "Invalid messages JSON");
    return -1;
  }

  if (tools_json && std::strlen(tools_json) > 0) {
    try {
      body["tools"] = json::parse(tools_json);
    } catch (const json::parse_error& e) {
      LOG_ERR("Failed to parse tools_json: " + std::string(e.what()));
      if (on_done) on_done(-1, "Invalid tools JSON");
      return -1;
    }
  }

  std::string body_str = body.dump();

  std::string url = (base_url && std::strlen(base_url) > 0)
      ? std::string(base_url) + "/v1/messages"
      : "https://api.anthropic.com/v1/messages";

  LOG_INFO("POST " + url);
  LOG_INFO("model=" + std::string(model));

  curl_easy_reset(impl_->curl);

  if (impl_->headers) {
    curl_slist_free_all(impl_->headers);
    impl_->headers = nullptr;
  }

  std::string api_key_header = "x-api-key: " + std::string(api_key ? api_key : "");
  impl_->headers = curl_slist_append(impl_->headers, api_key_header.c_str());
  impl_->headers = curl_slist_append(impl_->headers, "anthropic-version: 2023-06-01");
  impl_->headers = curl_slist_append(impl_->headers, "content-type: application/json");

  curl_easy_setopt(impl_->curl, CURLOPT_URL, url.c_str());
  curl_easy_setopt(impl_->curl, CURLOPT_POST, 1L);
  curl_easy_setopt(impl_->curl, CURLOPT_POSTFIELDS, body_str.c_str());
  curl_easy_setopt(impl_->curl, CURLOPT_POSTFIELDSIZE, (long)body_str.size());
  curl_easy_setopt(impl_->curl, CURLOPT_HTTPHEADER, impl_->headers);
  curl_easy_setopt(impl_->curl, CURLOPT_WRITEFUNCTION, write_callback);
  curl_easy_setopt(impl_->curl, CURLOPT_WRITEDATA, impl_);
  curl_easy_setopt(impl_->curl, CURLOPT_TIMEOUT, impl_->timeout_secs);
  curl_easy_setopt(impl_->curl, CURLOPT_CONNECTTIMEOUT, 30L);
  curl_easy_setopt(impl_->curl, CURLOPT_USERAGENT, "AliasAgent/1.0");
  curl_easy_setopt(impl_->curl, CURLOPT_SSL_VERIFYPEER, 1L);

  LOG_INFO("Sending request (timeout=" + std::to_string(impl_->timeout_secs) + "s)...");

  // 5.2/5.3 — Execute; SSE events are buffered (not callback'd) during curl
  CURLcode res = curl_easy_perform(impl_->curl);

  // -- After curl completes, dispatch all buffered events --
  // impl_ strings persist (g_gateway is static global), so Dart .listener
  // callbacks can safely read them even after the C function returns.

  if (res != CURLE_OK) {
    std::string err = "Connection error: " + std::string(curl_easy_strerror(res));
    LOG_ERR(err);
    dispatch_events(impl_, on_chunk, on_tool_call, on_done);
    if (!impl_->done_dispatched && on_done) {
      on_done(-1, err.c_str());
    }
    return rid;
  }

  long http_code = 0;
  curl_easy_getinfo(impl_->curl, CURLINFO_RESPONSE_CODE, &http_code);
  LOG_INFO("HTTP " + std::to_string(http_code));

  if (http_code == 401) {
    LOG_ERR("Authentication failed (HTTP 401)");
    dispatch_events(impl_, on_chunk, on_tool_call, on_done);
    if (!impl_->done_dispatched && on_done) {
      on_done(-1, "Authentication failed — invalid API key");
    }
    return rid;
  }

  if (http_code >= 400) {
    std::string err = "API returned HTTP " + std::to_string(http_code);
    LOG_ERR(err);
    dispatch_events(impl_, on_chunk, on_tool_call, on_done);
    if (!impl_->done_dispatched && on_done) {
      on_done(-1, err.c_str());
    }
    return rid;
  }

  // Dispatch all buffered SSE events
  dispatch_events(impl_, on_chunk, on_tool_call, on_done);

  if (!impl_->done_dispatched && on_done) {
    on_done(0, "");
  }

  LOG_INFO("=== Request #" + std::to_string(rid) + " complete ===");
  return rid;
}