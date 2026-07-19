#include "model_gateway.h"
#include "logger.h"
#include "crash_handler.h"
#include <curl/curl.h>
#include <nlohmann/json.hpp>
#include <string>
#include <vector>
#include <array>
#include <sstream>
#include <cstring>
#include <atomic>
#include <chrono>

using json = nlohmann::json;

// ---------------------------------------------------------------------------
// FFI ring buffer — records recent C→Dart callback invocations
// ---------------------------------------------------------------------------

enum class FfiEventType { CHUNK, TOOL_CALL, THINKING, DONE };

struct FfiEvent {
  FfiEventType type;
  size_t payload_size;
  uint64_t timestamp_ms;
};

struct FfiRingBuffer {
  static constexpr size_t CAPACITY = 256;
  std::array<FfiEvent, CAPACITY> events{};
  std::atomic<size_t> write_idx{0};
  std::atomic_flag spinlock = ATOMIC_FLAG_INIT;

  void push(FfiEventType type, size_t payload_size) {
    // Spinlock — lightweight, no contention (callbacks are synchronous)
    while (spinlock.test_and_set(std::memory_order_acquire)) {}
    uint64_t ts = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
    size_t idx = write_idx.fetch_add(1, std::memory_order_relaxed) % CAPACITY;
    events[idx] = {type, payload_size, ts};
    spinlock.clear(std::memory_order_release);
  }
};

// ---------------------------------------------------------------------------
// Buffered SSE event (parsed after curl completes, while strings are alive)
// ---------------------------------------------------------------------------

enum class SseEventKind { CHUNK, TOOL_CALL, THINKING, DONE };

struct SseEvent {
  SseEventKind kind;
  std::string text;           // for CHUNK
  std::string tool_json;      // for TOOL_CALL
  std::string thinking_json;  // for THINKING
  int done_code = 0;          // for DONE
  std::string done_err;       // for DONE
  std::string done_stop_reason; // for DONE, from message_delta
};

// ---------------------------------------------------------------------------
// Internal state
// ---------------------------------------------------------------------------

struct PendingThinking {
  std::string thinking;
  std::string signature;
};

struct ModelGateway::Impl {
  CURL* curl = nullptr;
  struct curl_slist* headers = nullptr;
  long timeout_secs = 120;

  // FFI ring buffer (always on, independent of log level)
  FfiRingBuffer ffi_ring;

  // Buffered events — populated during SSE parsing, dispatched after curl
  std::vector<SseEvent> events;
  // SSE parsing state
  std::string line_buf;
  bool done_dispatched = false;
  // Raw response body buffer (capped at 64KB, logged on HTTP errors)
  std::string raw_body;
  // Tool use assembly: accumulate input_json_delta partial_json per block index
  std::map<int, json> pending_tool_uses;
  std::map<int, std::string> partial_jsons;
  // Thinking block assembly: accumulate thinking/signature deltas per block index
  std::map<int, PendingThinking> pending_thinking;
  // stop_reason from message_delta, carried into DONE events
  std::string last_stop_reason;
  std::string last_error;

  int request_id = 0;
  static std::atomic<int> next_request_id;
};

std::atomic<int> ModelGateway::Impl::next_request_id{1};

// Global pointer for crash handler access (dump_ffi_ring_buffer)
static FfiRingBuffer* g_ffi_ring = nullptr;

// ---------------------------------------------------------------------------
// CURL write callback — only accumulates lines + feeds SSE parser
// Callbacks are NOT invoked here; events are buffered for dispatch after curl
// ---------------------------------------------------------------------------

static size_t write_callback(char* ptr, size_t size, size_t nmemb, void* userdata) {
  auto* impl = static_cast<ModelGateway::Impl*>(userdata);
  size_t total = size * nmemb;

  // Append to raw_body buffer (capped at 64KB) for error logging
  if (impl->raw_body.size() < 64 * 1024) {
    size_t remaining = 64 * 1024 - impl->raw_body.size();
    size_t to_append = total < remaining ? total : remaining;
    impl->raw_body.append(ptr, to_append);
  }

  for (size_t i = 0; i < total; ++i) {
    char c = ptr[i];
    // 64KB line_buf cap — prevents unbounded memory growth on malicious streams
    if (impl->line_buf.size() >= 64 * 1024) {
      LOG_ERR("SSE line exceeded 64KB cap, aborting transfer");
      return 0;
    }
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
          impl->events.push_back({SseEventKind::DONE, "", "", "", 0, "", impl->last_stop_reason});
          impl->done_dispatched = true;
          continue;
        }

        try {
          auto ev = json::parse(data);
          std::string type = ev.value("type", "");

          if (type == "content_block_delta") {
            if (ev.contains("delta")) {
              auto& delta = ev["delta"];
              std::string delta_type = delta.value("type", "");
              if (delta_type == "text_delta") {
                std::string text = delta.value("text", "");
                LOG_INFO("SSE: content_block_delta text=\"" + text + "\"");
                impl->events.push_back({SseEventKind::CHUNK, text, "", "", 0, "", ""});
              } else if (delta_type == "input_json_delta") {
                int idx = ev.value("index", -1);
                std::string pj = delta.value("partial_json", "");
                impl->partial_jsons[idx] += pj;
                LOG_INFO("SSE: input_json_delta index=" + std::to_string(idx) + " partial=" + pj);
              } else if (delta_type == "thinking_delta") {
                int idx = ev.value("index", -1);
                std::string thinking = delta.value("thinking", "");
                impl->pending_thinking[idx].thinking += thinking;
                LOG_INFO("SSE: thinking_delta index=" + std::to_string(idx) + " len=" + std::to_string(thinking.size()));
              } else if (delta_type == "signature_delta") {
                int idx = ev.value("index", -1);
                std::string sig = delta.value("signature", "");
                impl->pending_thinking[idx].signature += sig;
                LOG_INFO("SSE: signature_delta index=" + std::to_string(idx) + " len=" + std::to_string(sig.size()));
              }
            }
          }
          else if (type == "content_block_start") {
            if (ev.contains("content_block")) {
              auto& cb = ev["content_block"];
              if (cb.value("type", "") == "tool_use") {
                int idx = ev.value("index", -1);
                impl->pending_tool_uses[idx] = cb;
                impl->partial_jsons[idx] = "";
                LOG_INFO("SSE: content_block_start tool_use index=" + std::to_string(idx) + " name=" + cb.value("name", ""));
              } else if (cb.value("type", "") == "thinking") {
                int idx = ev.value("index", -1);
                impl->pending_thinking[idx] = {};
                LOG_INFO("SSE: content_block_start thinking index=" + std::to_string(idx));
              } else {
                LOG_INFO("SSE: content_block_start type=" + cb.value("type", ""));
              }
            }
          }
          else if (type == "message_stop") {
            LOG_INFO("SSE: message_stop");
            impl->events.push_back({SseEventKind::DONE, "", "", "", 0, "", impl->last_stop_reason});
            impl->done_dispatched = true;
          }
          else if (type == "error") {
            std::string msg = ev.value("error", json::object()).value("message", "Unknown API error");
            LOG_ERR("SSE: error \"" + msg + "\"");
            impl->events.push_back({SseEventKind::DONE, "", "", "", -1, msg, impl->last_stop_reason});
            impl->done_dispatched = true;
          }
          else if (type == "message_start") {
            LOG_INFO("SSE: message_start");
          }
          else if (type == "content_block_stop") {
            int idx = ev.value("index", -1);
            LOG_INFO("SSE: content_block_stop index=" + std::to_string(idx));
            // Check pending_thinking first (thinking blocks come before text/tool_use)
            auto th_it = impl->pending_thinking.find(idx);
            if (th_it != impl->pending_thinking.end()) {
              json thinking;
              thinking["type"] = "thinking";
              thinking["thinking"] = th_it->second.thinking;
              thinking["signature"] = th_it->second.signature;
              std::string thinking_json_str = thinking.dump();
              LOG_INFO("SSE: thinking final len=" + std::to_string(th_it->second.thinking.size()));
              impl->events.push_back({SseEventKind::THINKING, "", "", thinking_json_str, 0, "", ""});
              impl->pending_thinking.erase(th_it);
            }
            auto it = impl->pending_tool_uses.find(idx);
            if (it != impl->pending_tool_uses.end()) {
              json tool = it->second;
              auto pj_it = impl->partial_jsons.find(idx);
              if (pj_it != impl->partial_jsons.end() && !pj_it->second.empty()) {
                try {
                  tool["input"] = json::parse(pj_it->second);
                } catch (const json::parse_error& e) {
                  LOG_ERR("SSE: failed to parse accumulated input_json for block " + std::to_string(idx) + " — " + std::string(e.what()));
                }
              }
              std::string tool_json = tool.dump();
              LOG_INFO("SSE: tool_use final " + tool_json);
              impl->events.push_back({SseEventKind::TOOL_CALL, "", tool_json, "", 0, "", ""});
              impl->pending_tool_uses.erase(it);
              impl->partial_jsons.erase(idx);
            }
          }
          else if (type == "message_delta") {
            if (ev.contains("delta") && ev["delta"].contains("stop_reason")) {
              impl->last_stop_reason = ev["delta"]["stop_reason"];
            }
            LOG_INFO("SSE: message_delta stop_reason=" + impl->last_stop_reason);
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
                             OnThinkingCallback on_thinking,
                             OnDoneCallback on_done) {
  LOG_TRACE("dispatch_events: " + std::to_string(impl->events.size()) + " buffered events");
  for (auto& ev : impl->events) {
    switch (ev.kind) {
      case SseEventKind::CHUNK:
        impl->ffi_ring.push(FfiEventType::CHUNK, ev.text.size());
        LOG_TRACE("FFI: on_chunk(len=" + std::to_string(ev.text.size()) + ")");
        if (on_chunk) on_chunk(ev.text.c_str());
        break;
      case SseEventKind::TOOL_CALL:
        impl->ffi_ring.push(FfiEventType::TOOL_CALL, ev.tool_json.size());
        LOG_TRACE("FFI: on_tool_call(len=" + std::to_string(ev.tool_json.size()) + ")");
        if (on_tool_call) on_tool_call(ev.tool_json.c_str());
        break;
      case SseEventKind::THINKING:
        impl->ffi_ring.push(FfiEventType::THINKING, ev.thinking_json.size());
        LOG_TRACE("FFI: on_thinking(len=" + std::to_string(ev.thinking_json.size()) + ")");
        if (on_thinking) on_thinking(ev.thinking_json.c_str());
        break;
      case SseEventKind::DONE:
        impl->ffi_ring.push(FfiEventType::DONE, 0);
        LOG_TRACE("FFI: on_done(code=" + std::to_string(ev.done_code) + ")");
        if (on_done) on_done(ev.done_code, ev.done_err.empty() ? "" : ev.done_err.c_str(), ev.done_stop_reason.c_str());
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
  OnThinkingCallback on_thinking,
  OnDoneCallback on_done
) {
  if (!impl_->curl) {
    LOG_ERR("CURL handle not initialized");
    if (on_done) on_done(-1, "Internal error: CURL not initialized", "");
    return -1;
  }

  int rid = impl_->next_request_id++;
  impl_->request_id = rid;
  impl_->events.clear();
  impl_->line_buf.clear();
  impl_->raw_body.clear();
  impl_->done_dispatched = false;
  impl_->last_stop_reason.clear();
  impl_->last_error.clear();
  impl_->pending_thinking.clear();
  impl_->pending_tool_uses.clear();
  impl_->partial_jsons.clear();

  g_ffi_ring = &impl_->ffi_ring;  // register for crash handler visibility

  LOG_INFO("=== Request #" + std::to_string(rid) + " start ===");
  LOG_TRACE("execute: model=" + std::string(model ? model : "null") + " msgs=" + std::to_string(messages_json ? std::strlen(messages_json) : 0) + " bytes");

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
    if (on_done) on_done(-1, "Invalid messages JSON", "");
    return -1;
  }

  if (tools_json && std::strlen(tools_json) > 0) {
    try {
      body["tools"] = json::parse(tools_json);
    } catch (const json::parse_error& e) {
      LOG_ERR("Failed to parse tools_json: " + std::string(e.what()));
      if (on_done) on_done(-1, "Invalid tools JSON", "");
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
  LOG_INFO("body=" + body_str);

  // 5.2/5.3 — Execute; SSE events are buffered (not callback'd) during curl
  CURLcode res = curl_easy_perform(impl_->curl);

  // -- After curl completes, dispatch all buffered events --
  // impl_ strings persist (g_gateway is static global), so Dart .listener
  // callbacks can safely read them even after the C function returns.

  if (res != CURLE_OK) {
    std::string err = "Connection error: " + std::string(curl_easy_strerror(res));
    LOG_ERR(err);
    dispatch_events(impl_, on_chunk, on_tool_call, on_thinking, on_done);
    if (!impl_->done_dispatched && on_done) {
      impl_->last_error = err;
      on_done(-1, impl_->last_error.c_str(), "");
    }
    return rid;
  }

  long http_code = 0;
  curl_easy_getinfo(impl_->curl, CURLINFO_RESPONSE_CODE, &http_code);
  LOG_INFO("HTTP " + std::to_string(http_code));

  if (http_code == 401) {
    LOG_ERR("Authentication failed (HTTP 401)");
    if (!impl_->raw_body.empty()) {
      std::string preview = impl_->raw_body.size() > 2048
          ? impl_->raw_body.substr(0, 2048) + "..."
          : impl_->raw_body;
      LOG_ERR("API error body: " + preview);
    }
    dispatch_events(impl_, on_chunk, on_tool_call, on_thinking, on_done);
    if (!impl_->done_dispatched && on_done) {
      on_done(-1, "Authentication failed — invalid API key", "");
    }
    return rid;
  }

  if (http_code >= 400) {
    std::string err = "API returned HTTP " + std::to_string(http_code);
    LOG_ERR(err);
    if (!impl_->raw_body.empty()) {
      std::string preview = impl_->raw_body.size() > 2048
          ? impl_->raw_body.substr(0, 2048) + "..."
          : impl_->raw_body;
      LOG_ERR("API error body: " + preview);
    }
    dispatch_events(impl_, on_chunk, on_tool_call, on_thinking, on_done);
    if (!impl_->done_dispatched && on_done) {
      impl_->last_error = err;
      on_done(-1, impl_->last_error.c_str(), "");
    }
    return rid;
  }

  // Dispatch all buffered SSE events
  dispatch_events(impl_, on_chunk, on_tool_call, on_thinking, on_done);

  if (!impl_->done_dispatched && on_done) {
    on_done(0, "", "");
  }

  LOG_INFO("=== Request #" + std::to_string(rid) + " complete ===");
  return rid;
}

// ---------------------------------------------------------------------------
// dump_ffi_ring_buffer — called by crash handler to dump ring buffer contents
// Lock-free snapshot read of the ring buffer → crash_log()
// ---------------------------------------------------------------------------

static const char* ffi_event_type_str(FfiEventType t) {
  switch (t) {
    case FfiEventType::CHUNK:     return "chunk";
    case FfiEventType::TOOL_CALL: return "tool_call";
    case FfiEventType::THINKING:  return "thinking";
    case FfiEventType::DONE:      return "done";
  }
  return "?";
}

void dump_ffi_ring_buffer() {
  if (!g_ffi_ring) {
    crash_log("FFI ring buffer: empty");
    return;
  }

  // Lock-free snapshot: read write_idx once, then iterate
  size_t write_idx = g_ffi_ring->write_idx.load(std::memory_order_acquire);
  size_t count = write_idx < FfiRingBuffer::CAPACITY ? write_idx : FfiRingBuffer::CAPACITY;

  char header[128];
  snprintf(header, sizeof(header), "Last %zu FFI calls:", count);
  crash_log(header);

  for (size_t i = 0; i < count; ++i) {
    size_t idx = (write_idx - count + i) % FfiRingBuffer::CAPACITY;
    const FfiEvent& ev = g_ffi_ring->events[idx];
    char line[256];
    snprintf(line, sizeof(line), "  [%llu] %s payload=%zu",
             (unsigned long long)ev.timestamp_ms,
             ffi_event_type_str(ev.type),
             ev.payload_size);
    crash_log(line);
  }
}