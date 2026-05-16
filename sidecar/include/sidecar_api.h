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
typedef void (*OnDoneCallback)(int code, const char* err);

/// Ping: verify FFI bridge is working
SIDECAR_API const char* ping(void);

/// Send a message to the model, stream response via callbacks
/// Returns a request_id (integer)
SIDECAR_API int send_message(
  const char* api_key,
  const char* base_url,
  const char* model,
  const char* system_prompt,
  const char* messages_json,
  const char* tools_json,
  OnChunkCallback on_chunk,
  OnToolCallCallback on_tool_call,
  OnDoneCallback on_done
);

/// Set the workspace root for read_file / list_dir tools
SIDECAR_API void set_workspace(const char* path);

#ifdef __cplusplus
}
#endif

#endif // SIDECAR_API_H