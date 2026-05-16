#include "sidecar_api.h"
#include <string>

static std::string g_workspace;

extern "C" {

SIDECAR_API const char* ping(void) {
  return "pong";
}

SIDECAR_API int send_message(
  const char* /*api_key*/,
  const char* /*base_url*/,
  const char* /*model*/,
  const char* /*system_prompt*/,
  const char* /*messages_json*/,
  const char* /*tools_json*/,
  OnChunkCallback /*on_chunk*/,
  OnToolCallCallback /*on_tool_call*/,
  OnDoneCallback on_done
) {
  // Stub: immediately complete with success
  if (on_done) {
    on_done(0, "");
  }
  return 1;
}

SIDECAR_API void set_workspace(const char* path) {
  if (path) {
    g_workspace = path;
  }
}

} // extern "C"