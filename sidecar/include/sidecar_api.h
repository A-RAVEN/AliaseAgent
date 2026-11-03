#ifndef SIDECAR_API_H
#define SIDECAR_API_H

// ============================================================================
// AliasAgent sidecar 导出接口（change `add-context-handles` 之后的契约）
//
// ## 上下文句柄
//
// 除下面 4 个机器/应用级接口外，每个导出函数的**第一个参数**都是上下文句柄
// （`const char* handle`）。句柄是不透明的、区分大小写的原始字符串，由
// `create_context` 返回；**不假设它等于会话 id**。
//
// 20 个带句柄的导出（相对上一版全部改了签名）：
//   cancel_request(handle, request_id)        send_message(handle, …)
//   get_workspace(handle)                     set_workspace(handle, path)
//   read_file(handle, path)
//   list_dir(handle, path)                    write_file(handle, request_json)
//   edit_file(handle, request_json)           glob_file(handle, request_json)
//   grep_file(handle, request_json)           read_image(handle, request_json)
//   read_clipboard_image(handle, request_json)
//   browser_navigate/click/type/snapshot(handle, request_json)
//   run_command(handle, request_json)         read_spill(handle, request_json)
//   web_search(handle, request_json)          web_fetch(handle, request_json)
//
// 4 个保持原样（机器/应用级，不要求上下文，启动时尚无上下文也能调用）：
//   ping(void)                                browser_available(void)
//   ensure_search_infra(search_config_json)   get_search_providers(void)
//
// 另增 2 个上下文导出：create_context(name) 与 dispose_context(handle)。
//
// ## 未知句柄
//
// 登记过才有上下文；未知或已销毁的句柄**不会被隐式创建**。错误形状按接口区分：
//   - 返回 JSON 的工具/取消接口：{"ok":false,"code":"unknown_context","error":"…"}；
//   - `set_workspace`：返回纯文本 `unknown_context: <handle>`（它本来就用空串表示成功）；
//   - `send_message`：返回负数，并通过 on_done 交付 unknown_context 错误，不发起 HTTP；
//   - `dispose_context`：未知句柄按幂等成功处理（第二次销毁不报错）。
//
// ## 返回字符串的寿命（线程本地）
//
// 凡返回 `const char*` 的接口，返回的指针由**调用线程自己的结果缓冲**持有：
//   - 同一线程下一次调用**同一个**导出函数之前有效；
//   - 不同线程并发调用（即使同一个上下文）互不覆盖；
//   - 调用方必须在拿到指针后**立即复制**（Dart 的 `toDartString()` 就是立即复制），
//     不得保存指针留待以后使用。
// `ping` 返回的是字符串字面量，不受这条约束。
//
// ## 保留名与销毁
//
// `create_context` 拒绝空名字（empty_context）、`no-session` 与 `_it_` 前缀
// （reserved_context），因为前者与启动清理的历史目录同名、后者是测试专用目录前缀；
// 同名上下文正在销毁时返回 context_disposing，不许新旧并存。销毁是幂等的，并且
// 会先在途调用排空再释放资源。
//
// ## 取消失败
//
// 取消后底层始终交付真实 done。若 Dart 桥的兜底等待到期仍无 done，桥会把该上下文
// 标为 `context_poisoned` 并拒绝后续请求，直到销毁（且底层真正排空）或进程重启 ——
// 它不会合成一个假的 done 去清掉旧回调字符串。
// ============================================================================

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
typedef void (*OnThinkingCallback)(const char* thinking_json);
/// The on_done callback now also carries the measured usage (input/output
/// token counts) so Dart can persist them to the message's token_count column.
/// The field dialect follows the Anthropic-format /v1/messages endpoint; the
/// exact DeepSeek naming is [UNVERIFIED], so the sidecar parses defensively and
/// passes 0 for any value the endpoint did not report.
typedef void (*OnDoneCallback)(int code, const char* err, const char* stop_reason,
                               int input_tokens, int output_tokens);

/// Ping: verify FFI bridge is working（机器级，无句柄；返回字符串字面量）
SIDECAR_API const char* ping(void);

/// 创建或复用上下文。返回 JSON：
///   成功 {"ok":true,"handle":"<原名>","created":true|false}
///   空名字 {"ok":false,"code":"empty_context","error":"…"}
///   no-session / _it_ 前缀 {"ok":false,"code":"reserved_context","error":"…"}
///   同名正在销毁 {"ok":false,"code":"context_disposing","error":"…"}
/// `created:true` 时调用方应初始化该上下文的工作区；`created:false` 表示状态仍在，
/// 不得重复覆盖。返回值遵守上面的线程本地寿命。
SIDECAR_API const char* create_context(const char* name);

/// 销毁上下文并释放其资源（浏览器上下文、spill 目录、模型网关）。返回 JSON 且
/// 幂等：{"ok":true,"handle":"…","disposed":true|false}。毒化且无法排空时返回
/// {"ok":false,"code":"dispose_not_drained","error":"…"} 并保留资源。
SIDECAR_API const char* dispose_context(const char* handle);

/// Cancel the send_message request whose id is `request_id` on `handle`
/// (request-id targeted). 只取消该上下文自己的请求；未知句柄返回
/// {"ok":false,"code":"unknown_context","error":"…"}。Thread-safe, returns
/// immediately; the curl thread aborts the transfer and delivers
/// on_done(-1, "cancelled") before the request returns.
SIDECAR_API const char* cancel_request(const char* handle, int request_id);

/// Send a message to the model, stream response via callbacks, on the context
/// `handle`. `request_id` is caller-supplied (Dart bridge assigns a unique id per
/// request) so cancel_request(handle, id) can target a specific request; it does
/// NOT use 0. Returns the request_id on success; 1 with on_done(0,"","",0,0) when
/// the api key is empty/null; a negative code with an unknown_context error
/// through on_done when the handle is not registered (no HTTP starts).
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
);

/// Read back the workspace root this context currently holds (read-only).
/// 成功 {"ok":true,"workspace":"…"}；空工作区如实返回空字符串，不替换成主目录。
/// 未知/已销毁句柄返回 {"ok":false,"code":"unknown_context","error":"…"}，不隐式创建。
/// 本接口不修改工作区、文件版本表、spill 序号、模型请求或浏览器状态；返回值遵守
/// 上面的线程本地寿命。
SIDECAR_API const char* get_workspace(const char* handle);

/// Set the workspace root for this context's read_file / list_dir tools.
/// Returns an error message on failure, or empty string on success. 未知句柄返回
/// 纯文本 `unknown_context: <handle>`（不伪装成成功空串）。
SIDECAR_API const char* set_workspace(const char* handle, const char* path);

/// Read a text file within the context's workspace.
/// Returns JSON: {"ok":true,"content":"..."} or {"ok":false,"error":"..."}
SIDECAR_API const char* read_file(const char* handle, const char* path);

/// List directory contents within the context's workspace.
/// Returns JSON: {"ok":true,"content":"[...]"} or {"ok":false,"error":"..."}
SIDECAR_API const char* list_dir(const char* handle, const char* path);

/// Initialize search infrastructure with per-provider API keys from config.
/// 机器级接口，无句柄。Idempotent — repeated calls return immediately.
/// Returns JSON: {"ok":true} or {"ok":false,"error":"..."}
SIDECAR_API const char* ensure_search_infra(const char* search_config_json);

/// Return configured search providers as JSON array（机器级，无句柄）。
/// Returns: [{"name":"...","description":"..."},...]
SIDECAR_API const char* get_search_providers(void);

/// Execute a web search across configured providers in parallel.
/// @param request_json  {"query":"...","providers":[...],"depth":"basic|deep","max_results":5}
/// Returns namespaced JSON result.
SIDECAR_API const char* web_search(const char* handle, const char* request_json);

/// Fetch a web page and extract text.
/// @param request_json  {"url":"...","extract_mode":"text"}
/// Returns JSON: {"ok":true,"content":"..."} or {"ok":false,"error":"..."}
SIDECAR_API const char* web_fetch(const char* handle, const char* request_json);

/// Create or overwrite a file within the context's workspace.
/// @param request_json  {"path":"...","content":"..."}
/// Returns JSON: {"ok":true,"path":"...","bytes_written":N,"created":true|false}
SIDECAR_API const char* write_file(const char* handle, const char* request_json);

/// Edit a file with a batch of replacement pairs.
/// @param request_json  {"path":"...","edits":[{"old_text":"...","new_text":"...","replace_all":false}]}
/// Returns JSON: {"ok":true,"replacements":N} or {"ok":false,"error":"...","diagnosis":{...}}
SIDECAR_API const char* edit_file(const char* handle, const char* request_json);

/// Find files within the context's workspace matching a glob pattern (ripgrep-backed).
/// @param request_json  {"pattern":"...","max_results":N}
/// Returns JSON: {"ok":true,"paths":[...],"count":N,"truncated":true|false}
SIDECAR_API const char* glob_file(const char* handle, const char* request_json);

/// Search file contents within the context's workspace using a regular expression
/// (ripgrep-backed).
/// @param request_json  {"pattern":"...","glob":"...","ignore_case":bool,"max_results":N}
/// Returns JSON: {"ok":true,"matches":[{"path":"...","line":N,"text":"..."}],
///                "count":N,"truncated":true|false}
SIDECAR_API const char* grep_file(const char* handle, const char* request_json);

/// Validate and describe an image file inside the context's workspace. The bytes
/// do NOT cross the FFI boundary: Dart reads the file and puts it into the
/// request as an `image` content block.
/// @param request_json  {"path":"..."}
/// Returns JSON: {"ok":true,
///                "content":"<path>a.png</path>\n<type>image</type>\n<content>\n…\n</content>",
///                "image":{"path":"a.png","media_type":"image/png",
///                         "width":4,"height":3,"bytes":130}}
///                or {"ok":false,"error":"..."}
SIDECAR_API const char* read_image(const char* handle, const char* request_json);

/// Read the current clipboard image, write it as a PNG file into `dest_dir`, and
/// return its path plus dimensions. The clipboard may hold PNG bytes (browsers)
/// or a raw DIB (screenshot tools); both end up as the same PNG on disk.
/// @param request_json  {"dest_dir":"<absolute directory>"} — created recursively
/// Returns JSON: {"ok":true,"path":"…","media_type":"image/png",
///                "width":W,"height":H,"bytes":N}
///           or {"ok":false,"error":"…"}；剪贴板里没有图时 error 恰为
///              "clipboard has no image"
SIDECAR_API const char* read_clipboard_image(const char* handle, const char* request_json);

/// Probe whether the browser tool stack is present (机器级，无句柄). One-shot.
/// Returns JSON: {"ok":true,"available":bool,...} or {"ok":false,"error":"..."}
SIDECAR_API const char* browser_available(void);

/// Drive the browser on this context's own browser session. Each maps to the
/// worker command and returns the worker's JSON response (the snapshot for the
/// model; the per-call counters are logged to sidecar.log outside the text).
/// request_json carries only tool params:
///   browser_navigate: {"url":"..."}
///   browser_click:    {"selector":"..."}
///   browser_type:     {"selector":"...","text":"..."}
///   browser_snapshot: {}
SIDECAR_API const char* browser_navigate(const char* handle, const char* request_json);
SIDECAR_API const char* browser_click(const char* handle, const char* request_json);
SIDECAR_API const char* browser_type(const char* handle, const char* request_json);
SIDECAR_API const char* browser_snapshot(const char* handle, const char* request_json);

/// Run one PowerShell command and return its exit code, stdout and stderr.
/// 命令字符串作为 `-Command` 的单个参数交出去，外层不再套第二层解析；
/// 每条流的**完整输出先落盘**到
/// `~/.aliasagent/spill/<上下文句柄的无损编码>/<序号>-<流>.txt`，
/// 超长时只内联头尾各 `preview_chars` 个字符并给出可取回的引用。spill 的归属键
/// 就是首参句柄；请求 JSON 里没有目录键字段。
/// @param request_json  {"command":"...","workdir":"...","timeout_ms":N,
///                       "max_timeout_ms":N,"preview_chars":N}
/// Returns JSON: {"ok":true,"exit_code":N,"stdout":"...","stderr":"...",
///                "timed_out":bool,"duration_ms":N,
///                "truncated":{"stdout":bool,"stderr":bool},
///                "spill":{"stdout":{"ref":"...","total_bytes":N,
///                                   "omitted_bytes":N,"head":"...","tail":"..."},...}}
///           or {"ok":false,"error":"..."}
SIDECAR_API const char* run_command(const char* handle, const char* request_json);

/// Read a byte range back out of a spill file written by run_command.
/// `offset` / `limit` 的单位都是**字节**；`limit` 省略时按 `preview_chars × 2` 取。
/// `ref` 先按平台规范化，再必须落在**该句柄对应上下文自己的 spill 目录**内：
/// 读别的上下文的引用（含 `<乙>/../<甲>/文件`）返回 ok:false，不会读到对方内容。
/// @param request_json  {"ref":"...","offset":N,"limit":N,"preview_chars":N}
/// Returns JSON: {"ok":true,"text":"...","bytes_read":N,"total_bytes":M}
///           or {"ok":false,"error":"..."}（错误文本按原因各不相同）
SIDECAR_API const char* read_spill(const char* handle, const char* request_json);

#ifdef __cplusplus
}
#endif

#endif // SIDECAR_API_H
