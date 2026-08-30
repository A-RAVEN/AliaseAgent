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
#include <thread>
#include <mutex>
#include <deque>
#include <map>

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
// PendingThinking — per-block delta accumulation (single writer: curl thread)
// ---------------------------------------------------------------------------

struct PendingThinking {
  std::string thinking;
  std::string signature;
};

// ---------------------------------------------------------------------------
// Internal state
// ---------------------------------------------------------------------------

struct ModelGateway::Impl {
  CURL* curl = nullptr;
  struct curl_slist* headers = nullptr;
  long timeout_secs = 120;

  // FFI ring buffer (always on, independent of log level)
  FfiRingBuffer ffi_ring;

  // ---- Request serialization (D1) ----------------------------------------
  // At most one active request: execute() holds this mutex across the whole
  // request lifecycle (spawn + join). Concurrent send_message calls from
  // multiple worker isolates serialize on it, and the same CURL handle is
  // never used by more than one thread at any given time (libcurl requirement:
  // curl.se/libcurl/c/threadsafe.html — "You must never use a single handle
  // from more than one thread at any given time").
  std::mutex request_mutex;

  // ---- Cancellation (D7 / D8) ----------------------------------------------
  // cancel_flag: generic "abort whatever is currently running" (observed by the
  // curl thread's XFERINFO callback; reset by every execute()).
  // cancel_request_id: request-id TARGETED cancel — set by cancel_request(id);
  // NOT reset by execute(), so a cancel that lands in the enqueue→start window
  // still aborts the SPECIFIC request (closes the global-flag reset race).
  std::atomic<bool> cancel_flag{false};
  std::atomic<int> cancel_request_id{0};

  // ---- Callback string lifetime (D3) --------------------------------------
  // Incremental event texts are stored in a deque of strings; the curl thread
  // hands out pointers to element addresses (std::deque::emplace_back does not
  // invalidate references to existing elements). Dart .listener callbacks
  // synchronously copy the strings when the isolate processes the messages.
  // Cleared only at the start of the next request, while holding request_mutex
  // — by then the previous request's curl thread has joined AND its done
  // callback has been processed by the main isolate (Dart serialization gate:
  // a new sendMessage never starts until the previous done was handled).
  std::mutex pending_mutex;
  std::deque<std::string> pending_strings;

  // ---- Active callbacks (set at execute() start, curl-thread read) --------
  OnChunkCallback on_chunk = nullptr;
  OnToolCallCallback on_tool_call = nullptr;
  OnThinkingCallback on_thinking = nullptr;
  OnDoneCallback on_done = nullptr;

  // ---- SSE parsing state (single writer: curl thread) ---------------------
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
  // Measured usage carried into DONE events (field dialect [UNVERIFIED]:
  // Anthropic-format /v1/messages uses input_tokens/output_tokens; the sidecar
  // parses whichever token-count field the endpoint returns, defaulting to 0).
  int last_input_tokens = 0;
  int last_output_tokens = 0;

  int request_id = 0;
  static std::atomic<int> next_request_id;
};

std::atomic<int> ModelGateway::Impl::next_request_id{1};

// Global pointer for crash handler access (dump_ffi_ring_buffer)
static FfiRingBuffer* g_ffi_ring = nullptr;

// Forward declarations (defined below write_callback)
static bool http_status_ok(ModelGateway::Impl* impl);
static void dispatch_done(ModelGateway::Impl* impl, int code,
                          const std::string& err, const std::string& stop_reason);

// ---------------------------------------------------------------------------
// Stable string storage — callbacks receive pointers into pending_strings
// (deque element addresses are stable across emplace_back; strings are written
// once by the curl thread before the callback fires and read once by the Dart
// isolate inside the .listener closure — no concurrent read/write per element)
// ---------------------------------------------------------------------------

static const char* stable_str(ModelGateway::Impl* impl, std::string&& s) {
  std::lock_guard<std::mutex> lock(impl->pending_mutex);
  impl->pending_strings.emplace_back(std::move(s));
  return impl->pending_strings.back().c_str();
}

// ---------------------------------------------------------------------------
// CURL write callback — parses SSE lines and invokes callbacks in real-time
// from the curl thread (no buffering): text_delta → on_chunk immediately,
// thinking_delta → on_thinking immediately, tool_use → on_tool_call at
// content_block_stop, done → on_done at message_stop/[DONE]/error.
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
    // Post-done guard (9.4): once the stream's done has been dispatched
    // (message_stop/[DONE]/error), stop processing further bytes. A
    // wire-format-violating server sending content_block_delta after
    // message_stop would otherwise invoke callbacks on Dart NativeCallables
    // that finish() already closed — undefined behavior.
    if (impl->done_dispatched) break;
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

        // [DONE] is an OpenAI-format marker, NOT part of the Anthropic wire format
        // (which terminates with message_stop — platform.claude.com/docs/en/build-with-claude/streaming).
        // Kept as a compatibility redundancy for proxies that inject it.
        if (data == "[DONE]") {
          LOG_TRACE("SSE: [DONE] marker (OpenAI-format redundancy)");
          // Single-done guard: message_stop and [DONE] may both appear in a
          // successful stream (recorded in the DeepSeek endpoint fixture) —
          // on_done must fire exactly once. HTTP-error responses additionally
          // suppress stream done: the error branch reports unconditionally.
          if (!impl->done_dispatched && http_status_ok(impl)) {
            impl->done_dispatched = true;
            dispatch_done(impl, 0, "", impl->last_stop_reason);
          }
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
                LOG_TRACE("SSE: content_block_delta text=\"" + text + "\"");
                // Real-time delivery (D5): text streams while curl is active
                if (impl->on_chunk) {
                  impl->ffi_ring.push(FfiEventType::CHUNK, text.size());
                  impl->on_chunk(stable_str(impl, std::move(text)));
                }
              } else if (delta_type == "input_json_delta") {
                int idx = ev.value("index", -1);
                std::string pj = delta.value("partial_json", "");
                impl->partial_jsons[idx] += pj;
                LOG_TRACE("SSE: input_json_delta index=" + std::to_string(idx) + " partial=" + pj);
              } else if (delta_type == "thinking_delta") {
                int idx = ev.value("index", -1);
                std::string thinking = delta.value("thinking", "");
                impl->pending_thinking[idx].thinking += thinking;
                LOG_TRACE("SSE: thinking_delta index=" + std::to_string(idx) + " len=" + std::to_string(thinking.size()));
                // Real-time delivery (D4): incremental event
                // wire: content_block_delta {index, delta:{type:"thinking_delta", thinking:...}}
                // → sidecar-composed callback payload (internal format only):
                //   {"type":"thinking_delta","index":N,"delta":"<partial>"}
                if (impl->on_thinking) {
                  json evt;
                  evt["type"] = "thinking_delta";
                  evt["index"] = idx;
                  evt["delta"] = thinking;
                  std::string payload = evt.dump();
                  impl->ffi_ring.push(FfiEventType::THINKING, payload.size());
                  impl->on_thinking(stable_str(impl, std::move(payload)));
                }
              } else if (delta_type == "signature_delta") {
                int idx = ev.value("index", -1);
                std::string sig = delta.value("signature", "");
                impl->pending_thinking[idx].signature += sig;
                LOG_TRACE("SSE: signature_delta index=" + std::to_string(idx) + " len=" + std::to_string(sig.size()));
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
                LOG_TRACE("SSE: content_block_start tool_use index=" + std::to_string(idx) + " name=" + cb.value("name", ""));
              } else if (cb.value("type", "") == "thinking") {
                int idx = ev.value("index", -1);
                impl->pending_thinking[idx] = {};
                LOG_TRACE("SSE: content_block_start thinking index=" + std::to_string(idx));
              } else {
                LOG_TRACE("SSE: content_block_start type=" + cb.value("type", ""));
              }
            }
          }
          else if (type == "message_stop") {
            LOG_TRACE("SSE: message_stop");
            // Single-done guard (same as [DONE]): exactly one on_done per request
            if (!impl->done_dispatched && http_status_ok(impl)) {
              impl->done_dispatched = true;
              dispatch_done(impl, 0, "", impl->last_stop_reason);
            }
          }
          else if (type == "error") {
            std::string msg = ev.value("error", json::object()).value("message", "Unknown API error");
            LOG_ERR("SSE: error \"" + msg + "\"");
            // API-level error (HTTP 200 with error event): unconditional error done
            if (!impl->done_dispatched) {
              impl->done_dispatched = true;
              dispatch_done(impl, -1, msg, impl->last_stop_reason);
            }
          }
          else if (type == "message_start") {
            LOG_TRACE("SSE: message_start");
            // Usage may ride on message_start (input_tokens). Defensive parse —
            // read whichever token-count field the endpoint returns ([UNVERIFIED]).
            // The start event normally carries only input_tokens; output_tokens
            // typically arrives on message_delta.
            if (ev.contains("message") && ev["message"].is_object() &&
                ev["message"].contains("usage") &&
                ev["message"]["usage"].is_object()) {
              auto& usage = ev["message"]["usage"];
              if (usage.contains("input_tokens")) {
                impl->last_input_tokens = usage.value("input_tokens", 0);
              } else if (usage.contains("prompt_tokens")) {
                impl->last_input_tokens = usage.value("prompt_tokens", 0);
              }
              if (usage.contains("output_tokens")) {
                impl->last_output_tokens = usage.value("output_tokens", 0);
              } else if (usage.contains("completion_tokens")) {
                impl->last_output_tokens = usage.value("completion_tokens", 0);
              }
            }
          }
          else if (type == "content_block_stop") {
            int idx = ev.value("index", -1);
            LOG_TRACE("SSE: content_block_stop index=" + std::to_string(idx));
            // Thinking block final (accumulated from deltas — the wire stop
            // event carries only {type,index}, no content_block object)
            auto th_it = impl->pending_thinking.find(idx);
            if (th_it != impl->pending_thinking.end()) {
              json thinking;
              thinking["type"] = "thinking";
              thinking["index"] = idx;
              thinking["thinking"] = th_it->second.thinking;
              thinking["signature"] = th_it->second.signature;
              std::string thinking_json_str = thinking.dump();
              LOG_TRACE("SSE: thinking final len=" + std::to_string(th_it->second.thinking.size()));
              if (impl->on_thinking) {
                impl->ffi_ring.push(FfiEventType::THINKING, thinking_json_str.size());
                impl->on_thinking(stable_str(impl, std::move(thinking_json_str)));
              }
              impl->pending_thinking.erase(th_it);
            }
            // Tool use final (block-complete delivery — never incremental)
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
              LOG_TRACE("SSE: tool_use final " + tool_json);
              if (impl->on_tool_call) {
                impl->ffi_ring.push(FfiEventType::TOOL_CALL, tool_json.size());
                impl->on_tool_call(stable_str(impl, std::move(tool_json)));
              }
              impl->pending_tool_uses.erase(it);
              impl->partial_jsons.erase(idx);
            }
          }
          else if (type == "message_delta") {
            if (ev.contains("delta") && ev["delta"].contains("stop_reason")) {
              impl->last_stop_reason = ev["delta"]["stop_reason"];
            }
            // Usage rides on message_delta (output_tokens). Defensive parse.
            if (ev.contains("usage") && ev["usage"].is_object()) {
              auto& usage = ev["usage"];
              if (usage.contains("output_tokens")) {
                impl->last_output_tokens = usage.value("output_tokens", 0);
              } else if (usage.contains("completion_tokens")) {
                impl->last_output_tokens = usage.value("completion_tokens", 0);
              }
              if (usage.contains("input_tokens")) {
                impl->last_input_tokens = usage.value("input_tokens", 0);
              } else if (usage.contains("prompt_tokens")) {
                impl->last_input_tokens = usage.value("prompt_tokens", 0);
              }
            }
            LOG_TRACE("SSE: message_delta stop_reason=" + impl->last_stop_reason);
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
// Done dispatch helper + HTTP status check (single-done + error-suppression)
// ---------------------------------------------------------------------------

/// True when the HTTP response is not an error status. Stream done events
/// (message_stop/[DONE]) are suppressed on HTTP >= 400 so the error branch
/// (which reports unconditionally) is never masked by a fake success done.
static bool http_status_ok(ModelGateway::Impl* impl) {
  long code = 0;
  curl_easy_getinfo(impl->curl, CURLINFO_RESPONSE_CODE, &code);
  return code < 400;
}

/// Dispatch a done callback. Called from two contexts (17.4): the curl thread
/// for in-stream done (message_stop/[DONE]/SSE error), and the FFI thread
/// after join for post-perform done (cancel/connection error/HTTP error/
/// fallback). Error strings are stored in pending_strings (the Dart isolate
/// copies them asynchronously).
static void dispatch_done(ModelGateway::Impl* impl, int code, const std::string& err,
                          const std::string& stop_reason) {
  impl->ffi_ring.push(FfiEventType::DONE, 0);
  LOG_TRACE("FFI: on_done(code=" + std::to_string(code) +
            " input=" + std::to_string(impl->last_input_tokens) +
            " output=" + std::to_string(impl->last_output_tokens) + ")");
  if (!impl->on_done) return;
  // stop_reason may bind to a TEMPORARY std::string (error/cancel paths pass the
  // literal ""), so .c_str() dangles as soon as this statement ends — while the
  // Dart NativeCallable.listener reads it asynchronously on the isolate event
  // loop. Route it through the stable pending_strings pool (like err) so the
  // pointer remains valid until the Dart isolate copies it.
  const char* stop = stable_str(impl, std::string(stop_reason));
  if (err.empty()) {
    impl->on_done(code, "", stop,
                  impl->last_input_tokens, impl->last_output_tokens);
  } else {
    impl->on_done(code, stable_str(impl, std::string(err)), stop,
                  impl->last_input_tokens, impl->last_output_tokens);
  }
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
// Cancellation (D7) — observed by the curl thread via XFERINFO callback
// ---------------------------------------------------------------------------

static int xferinfo_cb(void* userdata,
                       curl_off_t dltotal, curl_off_t dlnow,
                       curl_off_t ultotal, curl_off_t ulnow) {
  (void)dltotal; (void)dlnow; (void)ultotal; (void)ulnow;
  auto* impl = static_cast<ModelGateway::Impl*>(userdata);
  // Non-zero return aborts the transfer with CURLE_ABORTED_BY_CALLBACK. Also honor
  // the request-id targeted cancel (D8) for the in-flight case.
  bool generic_cancel = impl->cancel_flag.load(std::memory_order_relaxed);
  bool targeted_cancel = impl->request_id != 0 &&
      impl->cancel_request_id.load(std::memory_order_relaxed) == impl->request_id;
  return (generic_cancel || targeted_cancel) ? 1 : 0;
}

// ---------------------------------------------------------------------------
// Main execution — threaded with request serialization (D1)
// ---------------------------------------------------------------------------

int ModelGateway::execute(
  const char* api_key,
  const char* base_url,
  const char* model,
  const char* system_prompt,
  const char* messages_json,
  const char* tools_json,
  const char* thinking_mode,
  const char* thinking_effort,
  OnChunkCallback on_chunk,
  OnToolCallCallback on_tool_call,
  OnThinkingCallback on_thinking,
  OnDoneCallback on_done,
  int request_id
) {
  // ---- Request serialization: at most one active request ------------------
  // Held across spawn + join. A second concurrent send_message (e.g. from a
  // fresh worker after a session switch) blocks here until the previous
  // request fully terminates — impl_ state and the CURL handle are never
  // accessed concurrently (libcurl threadsafe requirement).
  std::lock_guard<std::mutex> lock(impl_->request_mutex);

  if (!impl_->curl) {
    LOG_ERR("CURL handle not initialized");
    if (on_done) on_done(-1, "Internal error: CURL not initialized", "", 0, 0);
    return -1;
  }

  // request-id targeted cancel (D8): the caller supplies the id (Dart bridge
  // assigns it at enqueue) so a cancel_request(id) can target THIS request even
  // before it starts. id==0 auto-assigns a monotonic id (C++ tests).
  int rid = (request_id != 0) ? request_id : impl_->next_request_id++;
  impl_->request_id = rid;

  // ---- Reset per-request state (single writer before the curl thread) -----
  // pending_strings is cleared here, while holding request_mutex: the previous
  // request's curl thread has joined (previous execute released the lock) AND
  // its done callback was already processed by the main isolate — the Dart
  // bridge serializes new sendMessage calls behind the active request's
  // completion, and done is the last callback message on the isolate queue.
  {
    std::lock_guard<std::mutex> plock(impl_->pending_mutex);
    impl_->pending_strings.clear();
  }
  impl_->cancel_flag.store(false, std::memory_order_relaxed);
  impl_->line_buf.clear();
  impl_->raw_body.clear();
  impl_->done_dispatched = false;
  impl_->last_stop_reason.clear();
  impl_->last_input_tokens = 0;
  impl_->last_output_tokens = 0;
  impl_->pending_thinking.clear();
  impl_->pending_tool_uses.clear();
  impl_->partial_jsons.clear();
  impl_->on_chunk = on_chunk;
  impl_->on_tool_call = on_tool_call;
  impl_->on_thinking = on_thinking;
  impl_->on_done = on_done;

  // Request-id targeted cancel (D8): if a cancel_request(rid) landed while THIS
  // request was enqueued-but-not-yet-running, abort immediately without touching
  // the network. The global cancel_flag was reset at :499 and cannot catch this
  // window; the persistent cancel_request_id can.
  if (rid != 0 && impl_->cancel_request_id.load(std::memory_order_relaxed) == rid) {
    LOG_INFO("Request #" + std::to_string(rid) + " cancelled before start (targeted)");
    impl_->done_dispatched = true;
    dispatch_done(impl_, -1, "cancelled", "");
    // Clear the latch so a later request that reuses this id (hot-restart) is not
    // spuriously cancelled; this path returns before the end-of-execute clear.
    impl_->cancel_request_id.store(0, std::memory_order_relaxed);
    return -1;
  }

  g_ffi_ring = &impl_->ffi_ring;  // register for crash handler visibility

  LOG_INFO("=== Request #" + std::to_string(rid) + " start ===");
  LOG_TRACE("execute: model=" + std::string(model ? model : "null") + " msgs=" + std::to_string(messages_json ? std::strlen(messages_json) : 0) + " bytes");

  // ---- Build JSON request body ---------------------------------------------
  json body;
  body["model"] = model;
  body["stream"] = true;

  // Thinking on/off + intensity (unified for DeepSeek /v1/messages, Anthropic format).
  // Docs/DeepSeekAPIDoc.md §2.5 "Thinking Mode（Anthropic 格式）":
  //   thinking.type        | ON/OFF switch: "enabled" | "disabled" — per §2.5 documented
  //                          switch. Our code also sends "adaptive" for the interactive
  //                          path (project/live-verified usage; §2.5 does NOT document
  //                          adaptive — see doc L212 note). Live-verified 2026-08-26:
  //                          thinking.type="disabled" turns thinking OFF; the endpoint
  //                          DEFAULTS thinking to enabled (default effort high), so
  //                          ABSENCE is NOT a disable — we must explicitly send it (see
  //                          summary + else branches).
  //   output_config.effort | intensity ONLY (low/high/max), NOT the on/off switch.
  //   reasoning.effort / reasoning_effort | chat/completions only; NO effect on
  //                          /v1/messages (live-verified) — do not use for on/off here.
  // Summary-profile request (compaction): thinking.type="disabled" + a small
  // max_tokens window (1024) — summarization only, never the interactive 16K path.
  const bool summary_mode = (thinking_mode && std::string(thinking_mode) == "summary");
  const bool thinking_enabled = (thinking_mode && std::string(thinking_mode) == "adaptive");
  if (thinking_enabled) {
    body["thinking"]["type"] = "adaptive";
    body["thinking"]["display"] = "summarized";
    if (thinking_effort && std::strlen(thinking_effort) > 0) {
      body["output_config"]["effort"] = thinking_effort;
    }
    body["max_tokens"] = 16000;
    LOG_INFO("Thinking: adaptive, effort=" + std::string(thinking_effort ? thinking_effort : "default"));
  } else if (summary_mode) {
    // Summary profile: thinking.type="disabled" + capped output. Overrides the
    // 4096 default. DeepSeek's /v1/messages endpoint DEFAULTS thinking to enabled
    // (Docs/DeepSeekAPIDoc.md §2.5 "默认行为": Thinking 默认启用, 默认 effort high — this
    // is the §2.5 prose, NOT a field-table line; §3.1 line ~228 is chat/completions),
    // so absence is NOT a disable — without thinking.type="disabled" the summary
    // burns its 1024-token budget on reasoning.
    body["thinking"]["type"] = "disabled";
    body["max_tokens"] = 1024;
    LOG_INFO("Summary profile: thinking disabled, max_tokens=1024");
  } else {
    // Interactive "disabled" path (agent has no / invalid thinkingEffort).
    // DeepSeek's Anthropic-format endpoint DEFAULTS thinking to enabled, so
    // absence is NOT a disable — we must explicitly send thinking.type="disabled"
    // or the model silently reasons. (R3-1: R1-1 only patched the summary branch.)
    body["thinking"]["type"] = "disabled";
    body["max_tokens"] = 4096;
    LOG_INFO("Thinking: disabled");
  }

  if (system_prompt && std::strlen(system_prompt) > 0) {
    body["system"] = system_prompt;
  }

  try {
    body["messages"] = json::parse(messages_json);
  } catch (const json::parse_error& e) {
    LOG_ERR("Failed to parse messages_json: " + std::string(e.what()));
    if (on_done) on_done(-1, "Invalid messages JSON", "", 0, 0);
    return -1;
  }

  if (tools_json && std::strlen(tools_json) > 0) {
    try {
      body["tools"] = json::parse(tools_json);
    } catch (const json::parse_error& e) {
      LOG_ERR("Failed to parse tools_json: " + std::string(e.what()));
      if (on_done) on_done(-1, "Invalid tools JSON", "", 0, 0);
      return -1;
    }
  }

  std::string body_str = body.dump();

  std::string url = (base_url && std::strlen(base_url) > 0)
      ? std::string(base_url) + "/v1/messages"
      : "https://api.anthropic.com/v1/messages";

  LOG_INFO("POST " + url);
  LOG_INFO("model=" + std::string(model));

  // ---- Curl thread (D1) ----------------------------------------------------
  // All CURLOPT setup + curl_easy_perform run on the dedicated thread: the
  // handle is touched by exactly one thread at any given time. Streaming
  // callbacks (on_chunk/on_thinking, and on_done from message_stop/[DONE])
  // fire from this thread in real-time while the stream is active.
  //
  // Post-perform done delivery (cancel/connection error/HTTP error/fallback)
  // happens on the FFI thread AFTER join (below): native callbacks invoked
  // outside the libcurl call stack were observed to never reach the Dart
  // isolate, while callbacks from the libcurl write_callback stack always do.
  // The FFI thread is the worker isolate's thread (standard VM callback path),
  // and the curl thread has fully terminated by then — so closing the Dart
  // NativeCallables after this done is still guaranteed safe (D7).
  CURLcode res = CURLE_OK;
  bool cancelled = false;
  long http_code = 0;

  std::thread curl_thread([&] {
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
    // Cancellation (D7): XFERINFO callback observes cancel_flag (invoked
    // frequently during the transfer loop); non-zero return aborts promptly.
    curl_easy_setopt(impl_->curl, CURLOPT_XFERINFOFUNCTION, xferinfo_cb);
    curl_easy_setopt(impl_->curl, CURLOPT_XFERINFODATA, impl_);
    curl_easy_setopt(impl_->curl, CURLOPT_NOPROGRESS, 0L);

    LOG_INFO("Sending request (timeout=" + std::to_string(impl_->timeout_secs) + "s)...");
    LOG_TRACE("body=" + body_str);

    res = curl_easy_perform(impl_->curl);

    // Request-id targeted cancellation (D8): the transfer can abort via the
    // targeted (cancel_request_id == request_id) path too — xferinfo_cb returns 1
    // for it WITHOUT setting the generic cancel_flag. So the post-perform
    // classification must recognize BOTH, otherwise an in-flight targeted cancel
    // is mislabeled "Connection error" instead of on_done(-1,"cancelled").
    bool abort_cancelled = impl_->cancel_flag.load(std::memory_order_relaxed) ||
        (impl_->request_id != 0 &&
         impl_->cancel_request_id.load(std::memory_order_relaxed) == impl_->request_id);
    if (res == CURLE_ABORTED_BY_CALLBACK && abort_cancelled) {
      // 14.7 (F5): the abort may arrive AFTER the stream's done was already
      // dispatched in real-time (success path — _endStreaming's cancelRequest
      // aborts the curl thread still finishing the connection close). That is
      // not a cancellation; only a stream that never delivered its done is.
      // This keeps the log honest ("complete", not "cancelled").
      cancelled = !impl_->done_dispatched;
      if (cancelled) {
        LOG_INFO("Request #" + std::to_string(rid) + " cancelled");
      }
      return;
    }

    if (res != CURLE_OK) {
      LOG_ERR("Connection error: " + std::string(curl_easy_strerror(res)));
      return;
    }

    curl_easy_getinfo(impl_->curl, CURLINFO_RESPONSE_CODE, &http_code);
    LOG_INFO("HTTP " + std::to_string(http_code));
  });

  // Block the FFI thread until the curl thread terminates (synchronous
  // contract: send_message returns only after the request completes).
  curl_thread.join();

  // ---- Post-perform done delivery on the FFI thread (see note above) ------
  if (cancelled) {
    // on_done(-1) delivered after join: the main isolate closes NativeCallables
    // only after processing this done, by which time the curl thread has fully
    // terminated (no callback after close).
    if (!impl_->done_dispatched) {
      impl_->done_dispatched = true;
      dispatch_done(impl_, -1, "cancelled", "");
    }
  } else if (res != CURLE_OK) {
    std::string err = "Connection error: " + std::string(curl_easy_strerror(res));
    // Unconditional error done — a partial stream must not mask the connection
    // error as a fake success (stream done is suppressed on error statuses via
    // http_status_ok / done_dispatched guard).
    if (!impl_->done_dispatched) {
      impl_->done_dispatched = true;
      dispatch_done(impl_, -1, err, "");
    }
  } else if (http_code == 401) {
    LOG_ERR("Authentication failed (HTTP 401)");
    if (!impl_->raw_body.empty()) {
      std::string preview = impl_->raw_body.size() > 2048
          ? impl_->raw_body.substr(0, 2048) + "..."
          : impl_->raw_body;
      LOG_ERR("API error body: " + preview);
    }
    // Unconditional error done — never masked by a stream's message_stop
    // (stream done is suppressed when http_status_ok() is false).
    if (!impl_->done_dispatched) {
      impl_->done_dispatched = true;
      dispatch_done(impl_, -1, "Authentication failed — invalid API key", "");
    }
  } else if (http_code >= 400) {
    std::string err = "API returned HTTP " + std::to_string(http_code);
    LOG_ERR(err);
    if (!impl_->raw_body.empty()) {
      std::string preview = impl_->raw_body.size() > 2048
          ? impl_->raw_body.substr(0, 2048) + "..."
          : impl_->raw_body;
      LOG_ERR("API error body: " + preview);
    }
    // Same suppression as 401: HTTP errors always surface as errors.
    if (!impl_->done_dispatched) {
      impl_->done_dispatched = true;
      dispatch_done(impl_, -1, err, "");
    }
  } else if (!impl_->done_dispatched) {
    // Success path — the stream's message_stop/[DONE] already delivered the
    // done callback in real-time; fallback guard for streams that end without
    // either marker.
    impl_->done_dispatched = true;
    dispatch_done(impl_, 0, "", impl_->last_stop_reason);
  }

  if (!cancelled) {
    LOG_INFO("=== Request #" + std::to_string(rid) + " complete ===");
  }
  // Request-id targeted cancel (D8): once THIS request (the one cancel_request_id
  // identifies) resolves, clear the latch so a later request that happens to reuse
  // the same id (e.g. after a hot-restart resets the Dart id counter to 1 while the
  // DLL's g_gateway persists) is not spuriously cancelled. Non-target requests leave
  // it alone (they are not the one being cancelled); cancel_flag is untouched.
  if (rid != 0 && impl_->cancel_request_id.load(std::memory_order_relaxed) == rid) {
    impl_->cancel_request_id.store(0, std::memory_order_relaxed);
  }
  return rid;
}

// ---------------------------------------------------------------------------
// Cancel (D7) — thread-safe, returns immediately
// ---------------------------------------------------------------------------

void ModelGateway::cancel() {
  impl_->cancel_flag.store(true, std::memory_order_relaxed);
}

// Request-id targeted cancel (D8): sets a persistent cancel_request_id that
// execute() checks at start AND xferinfo_cb checks mid-transfer, so the SPECIFIC
// request aborts even in the enqueue→start window (which the single global flag,
// reset by the next execute(), cannot catch).
void ModelGateway::cancel(int request_id) {
  if (request_id != 0) {
    impl_->cancel_request_id.store(request_id, std::memory_order_relaxed);
  } else {
    impl_->cancel_flag.store(true, std::memory_order_relaxed);
  }
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