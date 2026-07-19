#ifndef OPENAI_TRANSPORT_H
#define OPENAI_TRANSPORT_H

#include <string>
#include <vector>
#include <map>
#include <functional>
#include <curl/curl.h>

// ============================================================================
// OpenAI SSE event types
// ============================================================================

/// Callbacks for SSE streaming from OpenAI-compatible APIs.
/// Each callback receives parsed data from the SSE stream.
struct OpenAISseCallbacks {
  /// Called for content text deltas (choices[0].delta.content).
  std::function<void(const std::string& text)> on_text;

  /// Called when a tool call function is fully received (arguments assembled).
  /// json contains the complete tool call delta: {"id":"...","function":{"name":"...","arguments":"..."}}
  std::function<void(const std::string& tool_call_json)> on_tool_call;

  /// Called when finish_reason is received (choices[0].finish_reason).
  std::function<void(const std::string& finish_reason)> on_finish;

  /// Called on parse error with the error message.
  std::function<void(const std::string& error_msg)> on_error;
};

// ============================================================================
// OpenAI SSE parser state (per-request)
// ============================================================================

struct OpenAISseState {
  // Accumulated arguments per tool_calls index
  std::map<int, std::string> accumulated_args;
  // Captured tool_call_id per index
  std::map<int, std::string> tool_call_ids;
  // Captured function name per index
  std::map<int, std::string> function_names;
  // Parse error counter per request
  int parse_errors = 0;
  // Per-event aggregate size for function.arguments accumulation
  size_t aggregate_size = 0;
  bool finished = false;
  std::string finish_reason;
  std::string error_message;
};

// ============================================================================
// OpenAI HTTP request builder
// ============================================================================

/// Build a POST /v1/chat/completions request body (JSON string).
/// @param model The model name (e.g., "glm-4-flash", "moonshot-v1-auto")
/// @param messages_json JSON array of message objects
/// @param tools_json JSON array of tool definitions (can be "[]")
/// @param tool_choice JSON string for tool_choice (e.g., "\"required\"", or a JSON object)
/// @param extra_body_fields Additional top-level fields to merge (e.g., {"thinking":{"type":"disabled"}})
std::string build_openai_request(
  const std::string& model,
  const std::string& messages_json,
  const std::string& tools_json,
  const std::string& tool_choice_json,
  const std::string& extra_body_json = "{}"
);

// ============================================================================
// OpenAI SSE write callback
// ============================================================================

/// User data passed to the curl write callback.
struct OpenAITransferCtx {
  OpenAISseCallbacks callbacks;
  OpenAISseState state;
  std::string line_buf;
  std::string raw_body; // capped at 64KB for error logging
  bool aborted = false;
  std::string abort_reason;
};

/// Size guard constants
constexpr size_t LINE_BUF_MAX = 64 * 1024;       // 64KB per-line cap
constexpr size_t AGGREGATE_MAX = 1 * 1024 * 1024; // 1MB aggregate per-event cap
constexpr size_t RAW_BODY_MAX = 64 * 1024;        // 64KB raw body buffer
constexpr int MAX_PARSE_ERRORS = 10;

/// Curl write callback for OpenAI SSE streams.
/// Parses line-buffered SSE data, dispatches OpenAI-format events.
/// Returns 0 to abort transfer on error/overflow.
size_t openai_write_callback(char* ptr, size_t size, size_t nmemb, void* userdata);

// ============================================================================
// Curl handle setup for OpenAI transport
// ============================================================================

/// Create and configure a curl handle for OpenAI-compatible API requests.
/// Sets: POST, headers (Authorization: Bearer, Content-Type: application/json),
/// SSL_VERIFYPEER, ACCEPT_ENCODING, CONNECTTIMEOUT, TIMEOUT, User-Agent.
/// Caller owns the returned handle (must curl_easy_cleanup).
/// @param url Full URL (e.g., "https://open.bigmodel.cn/api/paas/v4/chat/completions")
/// @param api_key Bearer token
/// @param body_str Request body JSON
/// @param timeout_sec Total timeout in seconds
/// @param connect_timeout_sec Connection timeout in seconds
CURL* create_openai_curl_handle(
  const std::string& url,
  const std::string& api_key,
  const std::string& body_str,
  long timeout_sec,
  long connect_timeout_sec
);

#endif // OPENAI_TRANSPORT_H
