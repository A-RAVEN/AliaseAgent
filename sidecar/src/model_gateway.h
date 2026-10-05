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
  /// Returns the request_id on success, -1 on error. `request_id` is caller-
  /// supplied (Dart bridge assigns it per request); 0 auto-assigns a monotonic id
  /// (used by C++ tests).
  int execute(
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
    int request_id = 0
  );

  /// Set network timeout in seconds (default 120).
  void set_timeout(long seconds);

  /// Cancel the in-flight request (if any). Thread-safe; returns immediately.
  /// The curl thread observes the flag (XFERINFO callback), aborts the
  /// transfer (CURLE_ABORTED_BY_CALLBACK) and delivers on_done(-1,"cancelled").
  void cancel();

  /// Request-id targeted cancel (design D8): cancel the SPECIFIC request whose
  /// id is `request_id`, even if it is only enqueued (not yet running). Sets a
  /// per-request cancel id that execute() checks at start AND during the transfer
  /// (XFERINFO), so a cancel that lands in the enqueue→start window still aborts
  /// that request — which the single global cancel_flag cannot (execute() resets it).
  void cancel(int request_id);
};

// ---------------------------------------------------------------------------
// API 报错原因（fix-silent-truncation 8.5 / 8.6 / 8.7，抽出来为了能被单测直接调）
// ---------------------------------------------------------------------------

/// 从端点返回的错误正文里抠出**服务端给的原因**：优先 `{"error":{"message":…}}`，
/// 其次 `{"message":…}`，都没有就退回正文前若干字节（去掉换行）。
/// 抠不出任何东西时返回空串 —— 调用方据此说明"服务端没有给出更多信息"，不许编。
/// 纯函数：不联网。
std::string describe_api_error_reason(const std::string& raw_body);

#endif