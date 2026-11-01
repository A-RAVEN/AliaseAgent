#include "context_api.h"

#include <chrono>
#include <exception>
#include <string>
#include <thread>

#include <nlohmann/json.hpp>

#include "browser.h"
#include "command_tool.h"
#include "logger.h"
#include "model_gateway.h"
#include "result_buffer.h"
#include "search_provider.h"
#include "spill.h"
#include "tools.h"
#include "web_fetch.h"

namespace context_api {

namespace {

// 每个导出入口一个固定编号的线程本地槽：`Context&` 版（测试入口）与句柄版
// （导出函数走的那条）共用同一个槽，所以测试碰到的存储就是产品用的那一份。
enum SlotId {
  kSlotSetWorkspace = 0,
  kSlotReadFile,
  kSlotListDir,
  kSlotWriteFile,
  kSlotEditFile,
  kSlotGlobFile,
  kSlotGrepFile,
  kSlotReadImage,
  kSlotReadClipboardImage,
  kSlotRunCommand,
  kSlotReadSpill,
  kSlotBrowserNavigate,
  kSlotBrowserClick,
  kSlotBrowserType,
  kSlotBrowserSnapshot,
  kSlotWebSearch,
  kSlotWebFetch,
  kSlotEnsureSearchInfra,
  kSlotSearchProviders,
  kSlotBrowserAvailable,
  kSlotCreateContext,
  kSlotDisposeContext,
  kSlotCancelRequest,
};

result_buffer::Slot& op_slot(SlotId id) {
  return result_buffer::slot_at(static_cast<int>(id));
}

std::string error_json(const std::string& message) {
  return "{\"ok\":false,\"error\":\"" + tools::json_escape(message) + "\"}";
}

std::string unknown_context_json(const char* handle) {
  const std::string name = handle ? handle : "";
  return "{\"ok\":false,\"code\":\"unknown_context\",\"error\":\"unknown context: " +
         tools::json_escape(name) + "\"}";
}

const char* fail(result_buffer::Slot& slot, const std::string& message) {
  return slot.set(error_json(message));
}

/// 统一兜住异常，并把错误写回**同一个** slot —— 不再有函数局部 err_static。
template <typename Fn>
const char* guarded(result_buffer::Slot& slot, const char* what, Fn&& fn) {
  try {
    return fn();
  } catch (const std::exception& e) {
    LOG_ERR(std::string(what) + " exception: " + e.what());
    return fail(slot, e.what());
  } catch (...) {
    LOG_ERR(std::string(what) + ": unknown exception");
    return fail(slot, "Unknown internal error");
  }
}

std::string require_request(const char* request_json) {
  return std::string(request_json ? request_json : "{}");
}

std::string json_dump(const nlohmann::json& j) {
  return j.dump(-1, ' ', false, nlohmann::json::error_handler_t::replace);
}

}  // namespace

// ============================================================================
// Lease
// ============================================================================

Lease::Lease(context::Context& ctx) : ctx_(ctx), previous_(context::Context::bind(&ctx)) {
  ctx_.enter();
}

Lease::~Lease() {
  ctx_.leave();
  context::Context::bind(previous_);
}

std::shared_ptr<context::Context> ensure_context(const std::string& name, bool* created) {
  return context::Registry::instance().acquire(name, created);
}

void reset_registry_for_tests() { context::reset_registry_for_tests(); }

std::shared_ptr<context::Context> resolve_handle(const char* handle) {
  if (!handle) return std::shared_ptr<context::Context>();
  const std::string name(handle);
  if (name.empty()) return std::shared_ptr<context::Context>();
  auto ctx = context::Registry::instance().find(name);
  if (!ctx || ctx->disposing()) return std::shared_ptr<context::Context>();
  return ctx;
}

// ============================================================================
// 上下文生命周期
// ============================================================================

const char* create_context_json(const char* name) {
  result_buffer::Slot& slot = op_slot(kSlotCreateContext);
  const std::string handle = name ? name : "";
  if (handle.empty()) {
    return slot.set(json_dump(nlohmann::json{{"ok", false},
                                             {"code", "empty_context"},
                                             {"error", "context name is empty"}}));
  }
  if (handle == "no-session" || handle.rfind("_it_", 0) == 0) {
    return slot.set(json_dump(nlohmann::json{
        {"ok", false},
        {"code", "reserved_context"},
        {"error", "context name is reserved: " + handle}}));
  }

  std::shared_ptr<context::Context> ctx;
  const context::Registry::CreateOutcome outcome =
      context::Registry::instance().create(handle, &ctx);
  switch (outcome) {
    case context::Registry::CreateOutcome::Disposing:
      return slot.set(json_dump(nlohmann::json{
          {"ok", false},
          {"code", "context_disposing"},
          {"error", "context is being disposed: " + handle}}));
    case context::Registry::CreateOutcome::Existed:
      return slot.set(json_dump(nlohmann::json{
          {"ok", true}, {"handle", handle}, {"created", false}}));
    case context::Registry::CreateOutcome::Created:
      break;
  }
  // 新建：扫描该目录已有 `NNNNNN-*.txt` 的最大序号并从此之后继续，避免进程重启
  // 后从 1 重来覆盖旧文件（旧引用会读到新内容）。
  spill::initialize_sequence_for_context(*ctx);
  return slot.set(json_dump(
      nlohmann::json{{"ok", true}, {"handle", handle}, {"created", true}}));
}

const char* dispose_context_json(const char* handle) {
  result_buffer::Slot& slot = op_slot(kSlotDisposeContext);
  const std::string name = handle ? handle : "";
  if (name.empty()) {
    return slot.set(json_dump(
        nlohmann::json{{"ok", true}, {"handle", name}, {"disposed", false}}));
  }
  for (;;) {
    auto ctx = context::Registry::instance().find(name);
    if (!ctx) {
      // 未知或已经销毁：幂等成功。
      return slot.set(json_dump(
          nlohmann::json{{"ok", true}, {"handle", name}, {"disposed", false}}));
    }
    if (ctx->dispose_failed()) {
      return slot.set(json_dump(nlohmann::json{
          {"ok", false},
          {"code", "dispose_not_drained"},
          {"error",
           "context is poisoned and its in-flight calls did not drain; resources kept: " +
               name}}));
    }
    if (!ctx->try_mark_disposing()) {
      // 另一个线程正在销毁同一句柄：等它从注册表移除后幂等返回。
      std::this_thread::sleep_for(std::chrono::milliseconds(5));
      continue;
    }
    // 毒化且仍有在途调用：无法证明排空，不假装释放（保留网关与 spill 目录）。
    if (ctx->poisoned() && ctx->in_flight() > 0) {
      ctx->mark_dispose_failed();
      return slot.set(json_dump(nlohmann::json{
          {"ok", false},
          {"code", "dispose_not_drained"},
          {"error",
           "context is poisoned and its in-flight calls did not drain; resources kept: " +
               name}}));
    }
    // 关闭入口 → 取消模型请求 → 等在途调用归零 → 关浏览器上下文、删 spill、移除。
    ctx->cancel_model_if_any();
    ctx->wait_for_idle();
    browser::close_context(*ctx);
    spill::remove_context_dir(name);
    context::Registry::instance().remove(name);
    return slot.set(json_dump(
        nlohmann::json{{"ok", true}, {"handle", name}, {"disposed", true}}));
  }
}

// ============================================================================
// 工具（Context& 版：测试入口）
// ============================================================================

const char* set_workspace(context::Context& ctx, const char* path) {
  result_buffer::Slot& slot = op_slot(kSlotSetWorkspace);
  Lease lease(ctx);
  std::lock_guard<std::mutex> gate(ctx.write_gate());
  LOG_TRACE("set_workspace: path=" + std::string(path ? path : "null"));
  std::string err = tools::set_workspace(path ? path : "");
  return slot.set(err);
}

const char* read_file(context::Context& ctx, const char* path) {
  result_buffer::Slot& slot = op_slot(kSlotReadFile);
  Lease lease(ctx);
  LOG_TRACE("read_file: path=" + std::string(path ? path : "null"));
  if (!path) return fail(slot, "No path provided");
  return slot.set(tools::read_file(path));
}

const char* list_dir(context::Context& ctx, const char* path) {
  result_buffer::Slot& slot = op_slot(kSlotListDir);
  Lease lease(ctx);
  LOG_TRACE("list_dir: path=" + std::string(path ? path : "null"));
  if (!path) return fail(slot, "No path provided");
  return slot.set(tools::list_dir(path));
}

const char* write_file(context::Context& ctx, const char* request_json) {
  result_buffer::Slot& slot = op_slot(kSlotWriteFile);
  Lease lease(ctx);
  std::lock_guard<std::mutex> gate(ctx.write_gate());
  LOG_TRACE("write_file called");
  if (!request_json) return fail(slot, "No request provided");
  return slot.set(tools::write_file(request_json));
}

const char* edit_file(context::Context& ctx, const char* request_json) {
  result_buffer::Slot& slot = op_slot(kSlotEditFile);
  Lease lease(ctx);
  std::lock_guard<std::mutex> gate(ctx.write_gate());
  LOG_TRACE("edit_file called");
  if (!request_json) return fail(slot, "No request provided");
  return slot.set(tools::edit_file(request_json));
}

const char* glob_file(context::Context& ctx, const char* request_json) {
  result_buffer::Slot& slot = op_slot(kSlotGlobFile);
  Lease lease(ctx);
  LOG_TRACE("glob_file called");
  if (!request_json) return fail(slot, "No request provided");
  return slot.set(tools::glob_file(request_json));
}

const char* grep_file(context::Context& ctx, const char* request_json) {
  result_buffer::Slot& slot = op_slot(kSlotGrepFile);
  Lease lease(ctx);
  LOG_TRACE("grep_file called");
  if (!request_json) return fail(slot, "No request provided");
  return slot.set(tools::grep_file(request_json));
}

const char* read_image(context::Context& ctx, const char* request_json) {
  result_buffer::Slot& slot = op_slot(kSlotReadImage);
  Lease lease(ctx);
  LOG_TRACE("read_image called");
  if (!request_json) return fail(slot, "No request provided");
  return slot.set(tools::read_image(request_json));
}

const char* read_clipboard_image(context::Context& ctx, const char* request_json) {
  result_buffer::Slot& slot = op_slot(kSlotReadClipboardImage);
  Lease lease(ctx);
  LOG_TRACE("read_clipboard_image called");
  if (!request_json) return fail(slot, "No request provided");
  return slot.set(tools::read_clipboard_image(request_json));
}

const char* run_command(context::Context& ctx, const char* request_json) {
  result_buffer::Slot& slot = op_slot(kSlotRunCommand);
  Lease lease(ctx);
  std::lock_guard<std::mutex> gate(ctx.write_gate());
  LOG_TRACE("run_command called");
  return guarded(slot, "run_command",
                 [&]() { return slot.set(command_tool::run_command(require_request(request_json))); });
}

const char* read_spill(context::Context& ctx, const char* request_json) {
  result_buffer::Slot& slot = op_slot(kSlotReadSpill);
  Lease lease(ctx);
  LOG_TRACE("read_spill called");
  return guarded(slot, "read_spill", [&]() {
    return slot.set(spill::read_request(ctx, require_request(request_json)));
  });
}

const char* browser_navigate(context::Context& ctx, const char* request_json) {
  result_buffer::Slot& slot = op_slot(kSlotBrowserNavigate);
  Lease lease(ctx);
  LOG_TRACE("browser_navigate called");
  return guarded(slot, "browser_navigate",
                 [&]() { return slot.set(browser::browser_navigate(require_request(request_json))); });
}

const char* browser_click(context::Context& ctx, const char* request_json) {
  result_buffer::Slot& slot = op_slot(kSlotBrowserClick);
  Lease lease(ctx);
  LOG_TRACE("browser_click called");
  return guarded(slot, "browser_click",
                 [&]() { return slot.set(browser::browser_click(require_request(request_json))); });
}

const char* browser_type(context::Context& ctx, const char* request_json) {
  result_buffer::Slot& slot = op_slot(kSlotBrowserType);
  Lease lease(ctx);
  LOG_TRACE("browser_type called");
  return guarded(slot, "browser_type",
                 [&]() { return slot.set(browser::browser_type(require_request(request_json))); });
}

const char* browser_snapshot(context::Context& ctx, const char* request_json) {
  result_buffer::Slot& slot = op_slot(kSlotBrowserSnapshot);
  Lease lease(ctx);
  LOG_TRACE("browser_snapshot called");
  return guarded(slot, "browser_snapshot",
                 [&]() { return slot.set(browser::browser_snapshot(require_request(request_json))); });
}

const char* web_search(context::Context& ctx, const char* request_json) {
  result_buffer::Slot& slot = op_slot(kSlotWebSearch);
  Lease lease(ctx);
  LOG_TRACE("web_search called");
  return guarded(slot, "web_search",
                 [&]() { return slot.set(dispatch_web_search(require_request(request_json))); });
}

const char* web_fetch(context::Context& ctx, const char* request_json) {
  result_buffer::Slot& slot = op_slot(kSlotWebFetch);
  Lease lease(ctx);
  LOG_TRACE("web_fetch called");
  try {
    return slot.set(web_fetch_impl(require_request(request_json)));
  } catch (const std::exception& e) {
    LOG_ERR(std::string("web_fetch exception: ") + e.what());
    return fail(slot, std::string("Fetch failed: ") + e.what());
  } catch (...) {
    LOG_ERR("web_fetch: unknown exception");
    return fail(slot, "Fetch failed: unknown error");
  }
}

// ============================================================================
// 机器/应用级接口（不需要上下文）
// ============================================================================

const char* ensure_search_infra(const char* search_config_json) {
  result_buffer::Slot& slot = op_slot(kSlotEnsureSearchInfra);
  LOG_TRACE("ensure_search_infra called");
  return guarded(slot, "ensure_search_infra", [&]() {
    return slot.set(ensure_search_infra_impl(std::string(search_config_json ? search_config_json : "{}")));
  });
}

const char* get_search_providers() {
  result_buffer::Slot& slot = op_slot(kSlotSearchProviders);
  LOG_TRACE("get_search_providers called");
  try {
    return slot.set(get_search_providers_json());
  } catch (const std::exception& e) {
    LOG_ERR(std::string("get_search_providers exception: ") + e.what());
    return slot.set("[]");
  } catch (...) {
    LOG_ERR("get_search_providers: unknown exception");
    return slot.set("[]");
  }
}

const char* browser_available() {
  result_buffer::Slot& slot = op_slot(kSlotBrowserAvailable);
  LOG_TRACE("browser_available called");
  try {
    return slot.set(browser::browser_available());
  } catch (const std::exception& e) {
    LOG_ERR(std::string("browser_available exception: ") + e.what());
    return slot.set("{\"ok\":true,\"available\":false,\"error\":\"" +
                    tools::json_escape(e.what()) + "\"}");
  } catch (...) {
    LOG_ERR("browser_available: unknown exception");
    return slot.set(
        "{\"ok\":true,\"available\":false,\"error\":\"Unknown internal error\"}");
  }
}

// ============================================================================
// 模型请求
// ============================================================================

int send_message(
    context::Context& ctx,
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
    int request_id) {
  Lease lease(ctx);
  LOG_TRACE("send_message: model=" + std::string(model ? model : "null") + " api_key=<REDACTED>");

  // 既有的空 key 早退：不是「未知句柄」，也不是这次要改的错误语义。
  if (!api_key || api_key[0] == '\0') {
    if (on_done) on_done(0, "", "", 0, 0);
    return 1;
  }

  return ctx.gateway().execute(
      api_key, base_url ? base_url : "", model ? model : "",
      system_prompt ? system_prompt : "", messages_json ? messages_json : "",
      tools_json ? tools_json : "", thinking_mode ? thinking_mode : "",
      thinking_effort ? thinking_effort : "", on_chunk, on_tool_call, on_thinking,
      on_done, request_id);
}

void cancel_request(context::Context& ctx, int request_id) {
  Lease lease(ctx);
  ctx.gateway().cancel(request_id);
}

int send_message(
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
    int request_id) {
  auto ctx = resolve_handle(handle);
  if (!ctx) {
    // 未知句柄：负数 + 经 on_done 报错；这不是一次真实模型请求，不进入队列。
    const std::string err = "unknown_context: " + std::string(handle ? handle : "");
    if (on_done) on_done(-2, err.c_str(), "", 0, 0);
    return -2;
  }
  return send_message(*ctx, api_key, base_url, model, system_prompt, messages_json,
                      tools_json, thinking_mode, thinking_effort, on_chunk, on_tool_call,
                      on_thinking, on_done, request_id);
}

const char* cancel_request(const char* handle, int request_id) {
  result_buffer::Slot& slot = op_slot(kSlotCancelRequest);
  auto ctx = resolve_handle(handle);
  if (!ctx) return slot.set(unknown_context_json(handle));
  cancel_request(*ctx, request_id);
  return slot.set("{\"ok\":true}");
}

// ============================================================================
// 句柄版工具入口（导出函数直接调用）：未知句柄的错误写进该函数自己的槽
// ============================================================================

const char* set_workspace(const char* handle, const char* path) {
  auto ctx = resolve_handle(handle);
  if (!ctx) {
    return op_slot(kSlotSetWorkspace)
        .set("unknown_context: " + std::string(handle ? handle : ""));
  }
  return set_workspace(*ctx, path);
}

const char* read_file(const char* handle, const char* path) {
  auto ctx = resolve_handle(handle);
  if (!ctx) return op_slot(kSlotReadFile).set(unknown_context_json(handle));
  return read_file(*ctx, path);
}

const char* list_dir(const char* handle, const char* path) {
  auto ctx = resolve_handle(handle);
  if (!ctx) return op_slot(kSlotListDir).set(unknown_context_json(handle));
  return list_dir(*ctx, path);
}

const char* write_file(const char* handle, const char* request_json) {
  auto ctx = resolve_handle(handle);
  if (!ctx) return op_slot(kSlotWriteFile).set(unknown_context_json(handle));
  return write_file(*ctx, request_json);
}

const char* edit_file(const char* handle, const char* request_json) {
  auto ctx = resolve_handle(handle);
  if (!ctx) return op_slot(kSlotEditFile).set(unknown_context_json(handle));
  return edit_file(*ctx, request_json);
}

const char* glob_file(const char* handle, const char* request_json) {
  auto ctx = resolve_handle(handle);
  if (!ctx) return op_slot(kSlotGlobFile).set(unknown_context_json(handle));
  return glob_file(*ctx, request_json);
}

const char* grep_file(const char* handle, const char* request_json) {
  auto ctx = resolve_handle(handle);
  if (!ctx) return op_slot(kSlotGrepFile).set(unknown_context_json(handle));
  return grep_file(*ctx, request_json);
}

const char* read_image(const char* handle, const char* request_json) {
  auto ctx = resolve_handle(handle);
  if (!ctx) return op_slot(kSlotReadImage).set(unknown_context_json(handle));
  return read_image(*ctx, request_json);
}

const char* read_clipboard_image(const char* handle, const char* request_json) {
  auto ctx = resolve_handle(handle);
  if (!ctx) return op_slot(kSlotReadClipboardImage).set(unknown_context_json(handle));
  return read_clipboard_image(*ctx, request_json);
}

const char* run_command(const char* handle, const char* request_json) {
  auto ctx = resolve_handle(handle);
  if (!ctx) return op_slot(kSlotRunCommand).set(unknown_context_json(handle));
  return run_command(*ctx, request_json);
}

const char* read_spill(const char* handle, const char* request_json) {
  auto ctx = resolve_handle(handle);
  if (!ctx) return op_slot(kSlotReadSpill).set(unknown_context_json(handle));
  return read_spill(*ctx, request_json);
}

const char* browser_navigate(const char* handle, const char* request_json) {
  auto ctx = resolve_handle(handle);
  if (!ctx) return op_slot(kSlotBrowserNavigate).set(unknown_context_json(handle));
  return browser_navigate(*ctx, request_json);
}

const char* browser_click(const char* handle, const char* request_json) {
  auto ctx = resolve_handle(handle);
  if (!ctx) return op_slot(kSlotBrowserClick).set(unknown_context_json(handle));
  return browser_click(*ctx, request_json);
}

const char* browser_type(const char* handle, const char* request_json) {
  auto ctx = resolve_handle(handle);
  if (!ctx) return op_slot(kSlotBrowserType).set(unknown_context_json(handle));
  return browser_type(*ctx, request_json);
}

const char* browser_snapshot(const char* handle, const char* request_json) {
  auto ctx = resolve_handle(handle);
  if (!ctx) return op_slot(kSlotBrowserSnapshot).set(unknown_context_json(handle));
  return browser_snapshot(*ctx, request_json);
}

const char* web_search(const char* handle, const char* request_json) {
  auto ctx = resolve_handle(handle);
  if (!ctx) return op_slot(kSlotWebSearch).set(unknown_context_json(handle));
  return web_search(*ctx, request_json);
}

const char* web_fetch(const char* handle, const char* request_json) {
  auto ctx = resolve_handle(handle);
  if (!ctx) return op_slot(kSlotWebFetch).set(unknown_context_json(handle));
  return web_fetch(*ctx, request_json);
}

}  // namespace context_api
