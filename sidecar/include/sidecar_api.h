#ifndef SIDECAR_API_H
#define SIDECAR_API_H

#ifdef __cplusplus
extern "C" {
#endif

#ifdef _WIN32
  #ifdef SIDECAR_EXPORTS
    #define SIDECAR_API __declspec(dllexport)
  #else
    #define SIDECAR_API __declspec(dllimport)
  #endif
#else
  #define SIDECAR_API __attribute__((visibility("default")))
#endif

/// Callback types for async streaming
typedef void (*OnChunkCallback)(const char* text);
typedef void (*OnToolCallCallback)(const char* json);
typedef void (*OnThinkingCallback)(const char* thinking_json);
typedef void (*OnDoneCallback)(int code, const char* err, const char* stop_reason);

/// Ping: verify FFI bridge is working
SIDECAR_API const char* ping(void);

/// Cancel the in-flight send_message request (if any). Thread-safe, returns
/// immediately; no-op when no request is active. The curl thread aborts the
/// transfer and delivers on_done(-1, "cancelled") before the request returns.
SIDECAR_API void cancel_request(void);

/// Send a message to the model, stream response via callbacks
/// Returns a request_id (integer)
SIDECAR_API int send_message(
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
  OnDoneCallback on_done
);

/// Set the workspace root for read_file / list_dir tools.
/// Returns an error message on failure, or empty string on success.
SIDECAR_API const char* set_workspace(const char* path);

/// Read a text file within the workspace.
/// Returns JSON: {"ok":true,"content":"..."} or {"ok":false,"error":"..."}
SIDECAR_API const char* read_file(const char* path);

/// List directory contents within the workspace.
/// Returns JSON: {"ok":true,"content":"[...]"} or {"ok":false,"error":"..."}
SIDECAR_API const char* list_dir(const char* path);

/// Initialize search infrastructure with per-provider API keys from config.
/// Idempotent — repeated calls return immediately.
/// Returns JSON: {"ok":true} or {"ok":false,"error":"..."}
SIDECAR_API const char* ensure_search_infra(const char* search_config_json);

/// Return configured search providers as JSON array.
/// Returns: [{"name":"...","description":"..."},...]
SIDECAR_API const char* get_search_providers(void);

/// Execute a web search across configured providers in parallel.
/// @param request_json  {"query":"...","providers":[...],"depth":"basic|deep","max_results":5}
/// Returns namespaced JSON result.
SIDECAR_API const char* web_search(const char* request_json);

/// Fetch a web page and extract text.
/// @param request_json  {"url":"...","extract_mode":"text"}
/// Returns JSON: {"ok":true,"content":"..."} or {"ok":false,"error":"..."}
SIDECAR_API const char* web_fetch(const char* request_json);

/// Create or overwrite a file within the workspace.
/// @param request_json  {"path":"...","content":"..."}
/// Returns JSON: {"ok":true,"path":"...","bytes_written":N,"created":true|false}
SIDECAR_API const char* write_file(const char* request_json);

/// Edit a file by replacing exact text (with whitespace normalization).
/// @param request_json  {"path":"...","old_text":"...","new_text":"...","replace_all":false}
/// Returns JSON: {"ok":true,"replacements":N} or {"ok":false,"error":"...","diagnosis":{...}}
SIDECAR_API const char* edit_file(const char* request_json);

#ifdef __cplusplus
}
#endif

#endif // SIDECAR_API_H