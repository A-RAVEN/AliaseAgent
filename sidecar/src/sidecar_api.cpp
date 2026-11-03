#include "sidecar_api.h"

#include <cstdlib>
#include <mutex>
#include <string>

#include "context.h"
#include "context_api.h"
#include "crash_handler.h"
#include "logger.h"

// ============================================================================
// 导出的薄壳（change add-context-handles，第二步）
//
// 这里只剩三件事：初始化日志/崩溃设施、把句柄交给 context_api 解析、把调用转给
// context_api。返回字符串由 context_api 里**每个入口专用的 thread_local 槽**持有，
// 本文件不再有 g_*_result，也不再有任何 err_static。
// ============================================================================

namespace {

std::once_flag g_log_once;
std::once_flag g_debug_infra_once;

void ensure_log() {
  std::call_once(g_log_once, []() {
    const char* home = nullptr;
#ifdef _WIN32
    home = std::getenv("USERPROFILE");
#else
    home = std::getenv("HOME");
#endif
    if (home) {
      Logger::instance().init(std::string(home) + "/.aliasagent/logs");
    }
  });
}

void ensure_debug_infra() {
  std::call_once(g_debug_infra_once, []() { crash_init(Logger::crash_dir().c_str()); });
}

}  // namespace

extern "C" {

SIDECAR_API const char* ping(void) { return "pong"; }

SIDECAR_API const char* create_context(const char* name) {
  ensure_log();
  return context_api::create_context_json(name);
}

SIDECAR_API const char* dispose_context(const char* handle) {
  ensure_log();
  return context_api::dispose_context_json(handle);
}

SIDECAR_API const char* cancel_request(const char* handle, int request_id) {
  ensure_log();
  return context_api::cancel_request(handle, request_id);
}

SIDECAR_API int send_message(
  const char* handle,
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
  ensure_log();
  ensure_debug_infra();
  return context_api::send_message(
      handle, api_key, base_url, model, system_prompt, messages_json, tools_json,
      thinking_mode, thinking_effort, on_chunk, on_tool_call, on_thinking, on_done,
      request_id);
}

SIDECAR_API const char* set_workspace(const char* handle, const char* path) {
  return context_api::set_workspace(handle, path);
}

SIDECAR_API const char* get_workspace(const char* handle) {
  return context_api::get_workspace(handle);
}

SIDECAR_API const char* read_file(const char* handle, const char* path) {
  return context_api::read_file(handle, path);
}

SIDECAR_API const char* list_dir(const char* handle, const char* path) {
  return context_api::list_dir(handle, path);
}

SIDECAR_API const char* ensure_search_infra(const char* search_config_json) {
  return context_api::ensure_search_infra(search_config_json);
}

SIDECAR_API const char* get_search_providers(void) {
  return context_api::get_search_providers();
}

SIDECAR_API const char* web_search(const char* handle, const char* request_json) {
  return context_api::web_search(handle, request_json);
}

SIDECAR_API const char* web_fetch(const char* handle, const char* request_json) {
  return context_api::web_fetch(handle, request_json);
}

SIDECAR_API const char* write_file(const char* handle, const char* request_json) {
  return context_api::write_file(handle, request_json);
}

SIDECAR_API const char* edit_file(const char* handle, const char* request_json) {
  return context_api::edit_file(handle, request_json);
}

SIDECAR_API const char* glob_file(const char* handle, const char* request_json) {
  return context_api::glob_file(handle, request_json);
}

SIDECAR_API const char* grep_file(const char* handle, const char* request_json) {
  return context_api::grep_file(handle, request_json);
}

SIDECAR_API const char* read_image(const char* handle, const char* request_json) {
  return context_api::read_image(handle, request_json);
}

SIDECAR_API const char* read_clipboard_image(const char* handle, const char* request_json) {
  return context_api::read_clipboard_image(handle, request_json);
}

SIDECAR_API const char* browser_available(void) {
  return context_api::browser_available();
}

SIDECAR_API const char* browser_navigate(const char* handle, const char* request_json) {
  return context_api::browser_navigate(handle, request_json);
}

SIDECAR_API const char* browser_click(const char* handle, const char* request_json) {
  return context_api::browser_click(handle, request_json);
}

SIDECAR_API const char* browser_type(const char* handle, const char* request_json) {
  return context_api::browser_type(handle, request_json);
}

SIDECAR_API const char* browser_snapshot(const char* handle, const char* request_json) {
  return context_api::browser_snapshot(handle, request_json);
}

SIDECAR_API const char* run_command(const char* handle, const char* request_json) {
  return context_api::run_command(handle, request_json);
}

SIDECAR_API const char* read_spill(const char* handle, const char* request_json) {
  return context_api::read_spill(handle, request_json);
}

} // extern "C"
