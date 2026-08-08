#include "sidecar_api.h"
#include "model_gateway.h"
#include "tools.h"
#include "logger.h"
#include "crash_handler.h"
#include "search_provider.h"
#include "web_fetch.h"
#include <string>
#include <cstring>

static ModelGateway g_gateway;
static bool g_log_initialized = false;
static bool g_debug_infra_initialized = false;
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

static void ensure_debug_infra() {
  if (g_debug_infra_initialized) return;
  g_debug_infra_initialized = true;

  crash_init(Logger::crash_dir().c_str());
}

extern "C" {

SIDECAR_API const char* ping(void) {
  return "pong";
}

SIDECAR_API void cancel_request(void) {
  ensure_log();
  g_gateway.cancel();
}

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
) {
  ensure_log();
  ensure_debug_infra();
  LOG_TRACE("send_message: model=" + std::string(model ? model : "null") + " api_key=<REDACTED>");

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
    thinking_mode ? thinking_mode : "",
    thinking_effort ? thinking_effort : "",
    on_chunk, on_tool_call, on_thinking, on_done
  );
}

SIDECAR_API const char* set_workspace(const char* path) {
  LOG_TRACE("set_workspace: path=" + std::string(path ? path : "null"));
  std::string err = tools::set_workspace(path ? path : "");
  if (err.empty()) return "";
  g_last_tool_result = err;
  return g_last_tool_result.c_str();
}

SIDECAR_API const char* read_file(const char* path) {
  LOG_TRACE("read_file: path=" + std::string(path ? path : "null"));
  if (!path) {
    g_last_tool_result = "{\"ok\":false,\"error\":\"No path provided\"}";
    return g_last_tool_result.c_str();
  }
  // Pass through — Dart side now wraps into JSON {"path":"..."} as needed
  g_last_tool_result = tools::read_file(path);
  return g_last_tool_result.c_str();
}

SIDECAR_API const char* list_dir(const char* path) {
  LOG_TRACE("list_dir: path=" + std::string(path ? path : "null"));
  if (!path) {
    g_last_tool_result = "{\"ok\":false,\"error\":\"No path provided\"}";
    return g_last_tool_result.c_str();
  }
  g_last_tool_result = tools::list_dir(path);
  return g_last_tool_result.c_str();
}

// ============================================================================
// Search & web fetch API (tasks 7.1-7.6)
//
// Thread-safety note: All search functions use per-function static string
// buffers (matching existing g_last_tool_result pattern). This is safe under
// the current assumption that Dart executes tool calls serially (_executeTool
// for loop). Concurrent FFI calls to the same function would race on the
// static buffer — if parallel tool execution is added in the future, a mutex
// or per-call allocation would be needed.
// ============================================================================

// Per-function static buffers (D9: static string pattern)
static std::string g_search_result;
static std::string g_fetch_result;
static std::string g_search_infra_result;
static std::string g_search_providers_result;

SIDECAR_API const char* ensure_search_infra(const char* search_config_json) {
  LOG_TRACE("ensure_search_infra called");
  try {
    g_search_infra_result = ensure_search_infra_impl(std::string(search_config_json ? search_config_json : "{}"));
    return g_search_infra_result.c_str();
  } catch (const std::exception& e) {
    static std::string err_static;
    err_static = "{\"ok\":false,\"error\":\"" + tools::json_escape(e.what()) + "\"}";
    LOG_ERR("ensure_search_infra exception: " + std::string(e.what()));
    return err_static.c_str();
  } catch (...) {
    LOG_ERR("ensure_search_infra: unknown exception");
    return "{\"ok\":false,\"error\":\"Unknown internal error\"}";
  }
}

SIDECAR_API const char* get_search_providers(void) {
  LOG_TRACE("get_search_providers called");
  try {
    g_search_providers_result = get_search_providers_json();
    return g_search_providers_result.c_str();
  } catch (const std::exception& e) {
    static std::string err_static;
    err_static = "[]";
    LOG_ERR("get_search_providers exception: " + std::string(e.what()));
    return err_static.c_str();
  } catch (...) {
    LOG_ERR("get_search_providers: unknown exception");
    return "[]";
  }
}

SIDECAR_API const char* web_search(const char* request_json) {
  LOG_TRACE("web_search called");
  try {
    g_search_result = dispatch_web_search(request_json ? request_json : "{}");
    return g_search_result.c_str();
  } catch (const std::exception& e) {
    static std::string err_static;
    err_static = "{\"ok\":false,\"error\":\"" + tools::json_escape(e.what()) + "\"}";
    LOG_ERR("web_search exception: " + std::string(e.what()));
    return err_static.c_str();
  } catch (...) {
    LOG_ERR("web_search: unknown exception");
    return "{\"ok\":false,\"error\":\"Unknown internal error\"}";
  }
}

SIDECAR_API const char* web_fetch(const char* request_json) {
  LOG_TRACE("web_fetch called");
  try {
    // Must cast to std::string to force compiler to pick the C++ overload
    // (std::string web_fetch(const std::string&)) instead of recursing into
    // this very function (const char* web_fetch(const char*)).
    g_fetch_result = web_fetch_impl(std::string(request_json ? request_json : "{}"));
    return g_fetch_result.c_str();
  } catch (const std::exception& e) {
    static std::string err_static;
    err_static = "{\"ok\":false,\"error\":\"Fetch failed: " + tools::json_escape(e.what()) + "\"}";
    LOG_ERR("web_fetch exception: " + std::string(e.what()));
    return err_static.c_str();
  } catch (...) {
    LOG_ERR("web_fetch: unknown exception");
    return "{\"ok\":false,\"error\":\"Fetch failed: unknown error\"}";
  }
}

// Per-function static buffers for file edit tools
static std::string g_write_file_result;
static std::string g_edit_file_result;

SIDECAR_API const char* write_file(const char* request_json) {
  LOG_TRACE("write_file called");
  if (!request_json) {
    g_write_file_result = "{\"ok\":false,\"error\":\"No request provided\"}";
    return g_write_file_result.c_str();
  }
  g_write_file_result = tools::write_file(request_json);
  return g_write_file_result.c_str();
}

SIDECAR_API const char* edit_file(const char* request_json) {
  LOG_TRACE("edit_file called");
  if (!request_json) {
    g_edit_file_result = "{\"ok\":false,\"error\":\"No request provided\"}";
    return g_edit_file_result.c_str();
  }
  g_edit_file_result = tools::edit_file(request_json);
  return g_edit_file_result.c_str();
}

} // extern "C"
