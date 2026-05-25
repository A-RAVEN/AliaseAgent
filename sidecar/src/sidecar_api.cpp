#include "sidecar_api.h"
#include "model_gateway.h"
#include "tools.h"
#include "logger.h"
#include <string>
#include <cstring>

static ModelGateway g_gateway;
static bool g_log_initialized = false;
static std::string g_last_tool_result; // thread-unsafe but single-threaded usage

static void ensure_log() {
  if (g_log_initialized) return;
  g_log_initialized = true;

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
  OnThinkingCallback on_thinking,
  OnDoneCallback on_done
) {
  ensure_log();

  if (!api_key || std::strlen(api_key) == 0) {
    if (on_done) on_done(0, "", "");
    return 1;
  }

  return g_gateway.execute(
    api_key, base_url ? base_url : "",
    model ? model : "",
    system_prompt ? system_prompt : "",
    messages_json ? messages_json : "",
    tools_json ? tools_json : "",
    on_chunk, on_tool_call, on_thinking, on_done
  );
}

SIDECAR_API const char* set_workspace(const char* path) {
  std::string err = tools::set_workspace(path ? path : "");
  if (err.empty()) return "";
  g_last_tool_result = err;
  return g_last_tool_result.c_str();
}

SIDECAR_API const char* read_file(const char* path) {
  if (!path) {
    g_last_tool_result = "{\"ok\":false,\"error\":\"No path provided\"}";
    return g_last_tool_result.c_str();
  }
  g_last_tool_result = tools::read_file(path);
  return g_last_tool_result.c_str();
}

SIDECAR_API const char* list_dir(const char* path) {
  if (!path) {
    g_last_tool_result = "{\"ok\":false,\"error\":\"No path provided\"}";
    return g_last_tool_result.c_str();
  }
  g_last_tool_result = tools::list_dir(path);
  return g_last_tool_result.c_str();
}

} // extern "C"
