#ifndef MODEL_GATEWAY_H
#define MODEL_GATEWAY_H

#include "sidecar_api.h"
#include <string>

/// Build Anthropic Messages API HTTP request and parse SSE stream.
/// Owns the curl handle for a single request.
class ModelGateway {
public:
  struct Impl;
  Impl* impl_;

  ModelGateway();
  ~ModelGateway();

  /// Execute a streaming send_message request. Blocks until complete or error.
  /// Returns the request_id on success, -1 on error.
  int execute(
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
  );

  /// Set network timeout in seconds (default 120).
  void set_timeout(long seconds);
};

#endif