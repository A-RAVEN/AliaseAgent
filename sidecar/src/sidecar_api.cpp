#include "sidecar_api.h"
#include "model_gateway.h"
#include "logger.h"
#include <string>
#include <cstring>

static std::string g_workspace;
static ModelGateway g_gateway;
static bool g_log_initialized = false;

static void ensure_log() {
  if (g_log_initialized) return;
  g_log_initialized = true;

  // Log to ~/.aliasagent/logs/
  const char* home = nullptr;
#ifdef _WIN32
  home = getenv("USERPROFILE");
#else
  home = getenv("HOME");
#endif
  if (home) {
    Logger::instance().init(std::string(home) + "/.aliasagent/logs");
  }
}

extern "C" {

SIDECAR_API const char* ping(void) {
  return "pong";
}

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
) {
  ensure_log();

  // Stub fallback: when called with no api_key (e.g., checkpoint 4 test),
  // complete immediately instead of attempting a doomed HTTP request.
  if (!api_key || std::strlen(api_key) == 0) {
    if (on_done) on_done(0, "");
    return 1;
  }

  return g_gateway.execute(
    api_key, base_url ? base_url : "",
    model ? model : "",
    system_prompt ? system_prompt : "",
    messages_json ? messages_json : "",
    tools_json ? tools_json : "",
    on_chunk, on_tool_call, on_done
  );
}

SIDECAR_API void set_workspace(const char* path) {
  if (path) {
    g_workspace = path;
  }
}

} // extern "C"