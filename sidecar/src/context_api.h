#ifndef CONTEXT_API_H
#define CONTEXT_API_H

// 接收 `Context&` 的内部包装层（change `add-context-handles`，design 决策 11）。
//
// 正式导出函数与 sidecar 测试都走这一层：导出函数只负责「按句柄解析上下文」，
// 具体实现全在这里；测试传自己的 Context& 调同一批函数，所以测到的就是产品路径
// （包括返回字符串的线程本地缓冲），不是另起一份临时字符串。
//
// 每个返回 JSON 的入口把结果放进 `result_buffer` 里**该入口专用的 Slot**，
// 返回的指针按调用线程各自有效。

#include <memory>
#include <string>

#include "context.h"
#include "sidecar_api.h"

namespace context_api {

/// 把一个上下文绑定到当前线程，并登记一次在途调用（析构时注销并恢复绑定）。
class Lease {
 public:
  explicit Lease(context::Context& ctx);
  ~Lease();
  Lease(const Lease&) = delete;
  Lease& operator=(const Lease&) = delete;

 private:
  context::Context& ctx_;
  context::Context* previous_;
};

// ---- 上下文生命周期 --------------------------------------------------------

/// 注册表查找或创建；`created` 写入这次是否新建。
std::shared_ptr<context::Context> ensure_context(const std::string& name, bool* created);

/// 测试用：清空注册表（不删 spill 目录）。
void reset_registry_for_tests();

// ---- 句柄解析与生命周期（导出函数走这些）----------------------------------

/// 解析句柄：登记过且不在销毁中才返回对象；否则返回空。
std::shared_ptr<context::Context> resolve_handle(const char* handle);

/// create_context 的 JSON 实现。
/// 成功 {"ok":true,"handle":…,"created":true|false}；空名 empty_context；
/// no-session / _it_ 前缀 reserved_context；同名正在销毁 context_disposing。
const char* create_context_json(const char* name);

/// dispose_context 的 JSON 实现（幂等）。未知句柄按已销毁处理。
const char* dispose_context_json(const char* handle);

// ---- 工具（全部接收 Context&）---------------------------------------------

/// 设置 ctx 的工作区。成功返回空串，失败返回错误文本（形状与既有导出一致）。
const char* set_workspace(context::Context& ctx, const char* path);

/// 读取 ctx 当前保存的工作区（只读）。成功 {"ok":true,"workspace":…}；
/// 空工作区如实返回空串；不修改工作区、文件版本表、spill 序号或浏览器状态。
const char* get_workspace(context::Context& ctx);

/// 读文件。`path` 是纯路径（既有导出语义）。
const char* read_file(context::Context& ctx, const char* path);

/// 列目录。`path` 是纯路径。
const char* list_dir(context::Context& ctx, const char* path);

const char* write_file(context::Context& ctx, const char* request_json);
const char* edit_file(context::Context& ctx, const char* request_json);
const char* glob_file(context::Context& ctx, const char* request_json);
const char* grep_file(context::Context& ctx, const char* request_json);
const char* read_image(context::Context& ctx, const char* request_json);
const char* read_clipboard_image(context::Context& ctx, const char* request_json);
const char* run_command(context::Context& ctx, const char* request_json);
const char* read_spill(context::Context& ctx, const char* request_json);

const char* browser_navigate(context::Context& ctx, const char* request_json);
const char* browser_click(context::Context& ctx, const char* request_json);
const char* browser_type(context::Context& ctx, const char* request_json);
const char* browser_snapshot(context::Context& ctx, const char* request_json);

const char* web_search(context::Context& ctx, const char* request_json);
const char* web_fetch(context::Context& ctx, const char* request_json);

// ---- 机器/应用级（不需要上下文）-------------------------------------------

const char* ensure_search_infra(const char* search_config_json);
const char* get_search_providers();
const char* browser_available();

// ---- 句柄版入口：导出函数直接调用；未知句柄的错误写进**该函数自己的槽**-----
// 返回 JSON 的接口给 {"ok":false,"code":"unknown_context","error":"..."}；
// set_workspace 给纯文本 "unknown_context: <handle>"；
// send_message 返回负数并经 on_done 报错；cancel_request 给 JSON 错误。

const char* set_workspace(const char* handle, const char* path);
const char* get_workspace(const char* handle);
const char* read_file(const char* handle, const char* path);
const char* list_dir(const char* handle, const char* path);
const char* write_file(const char* handle, const char* request_json);
const char* edit_file(const char* handle, const char* request_json);
const char* glob_file(const char* handle, const char* request_json);
const char* grep_file(const char* handle, const char* request_json);
const char* read_image(const char* handle, const char* request_json);
const char* read_clipboard_image(const char* handle, const char* request_json);
const char* run_command(const char* handle, const char* request_json);
const char* read_spill(const char* handle, const char* request_json);
const char* browser_navigate(const char* handle, const char* request_json);
const char* browser_click(const char* handle, const char* request_json);
const char* browser_type(const char* handle, const char* request_json);
const char* browser_snapshot(const char* handle, const char* request_json);
const char* web_search(const char* handle, const char* request_json);
const char* web_fetch(const char* handle, const char* request_json);

const char* cancel_request(const char* handle, int request_id);

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
    int request_id);

// ---- 模型请求 --------------------------------------------------------------

/// 在 ctx 的网关上执行一次流式请求；返回值同 ModelGateway::execute。
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
    int request_id);

/// 取消 ctx 自己的某个请求（请求 id 定向）。
void cancel_request(context::Context& ctx, int request_id);

}  // namespace context_api

#endif  // CONTEXT_API_H
