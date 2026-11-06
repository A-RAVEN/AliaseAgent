#ifndef WEB_FETCH_H
#define WEB_FETCH_H

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <mutex>
#include <string>

#include <nlohmann/json.hpp>

namespace context {
class Context;
}

// ============================================================================
// web_fetch — fetch a URL and return extracted text
// ============================================================================

/// Fetch a web page and return JSON: {"ok":true,"url":"...","title":"...","content":"..."}
/// or {"ok":false,"error":"..."}
///
/// Features:
/// - crawl4ai subprocess path (clean Markdown output) with curl fallback
/// - SSRF protection: URL pre-flight + DNS/IP resolution + blocklist
/// - CURLOPT_OPENSOCKETFUNCTION (curl path socket-level validation)
/// - CURLOPT_MAXFILESIZE (10MB pre-transfer size guard)
/// - Content-Type based extraction (text/html → tag strip, else raw)
/// - 15s timeout (curl), 30s timeout (subprocess)
///
/// @param request_json  {"url":"..."}
std::string web_fetch_impl(const std::string& request_json);

// ============================================================================
// HTML tag stripping utility (exposed for testing)
// ============================================================================

/// Strip HTML tags from a string, producing plain text.
/// Removes <script>, <style>, and all other tags. Compresses whitespace.
std::string strip_html_tags(const std::string& html);

// ============================================================================
// Internal utilities exposed for testing (task 9.5a, 9.7, 9.7a)
// ============================================================================

/// Case-insensitive string comparison.
bool iequals(const std::string& a, const std::string& b);

/// Extract the MIME type from a Content-Type value (part before ';').
std::string extract_mime_type(const std::string& content_type);

/// Check if an IPv4 address (host byte order) is in the SSRF blocklist.
/// @param ip_host_order  IP address in host byte order (after ntohl).
bool is_blocked_ipv4(uint32_t ip_host_order);

/// Check if an IPv6 address is in the SSRF blocklist.
/// @param bytes  16 bytes of the IPv6 address (sin6_addr.s6_addr).
bool is_blocked_ipv6(const unsigned char* bytes);

/// Write callback context for web_fetch.
struct FetchWriteCtx {
    std::string body;
    size_t accumulated = 0;
};

/// Write callback for web_fetch — appends received data to body.
size_t fetch_write_callback(char* ptr, size_t size, size_t nmemb, void* userdata);

// ============================================================================
// 体积被拒时的说明（fix-silent-truncation 5.3 / 5.4，抽出来为了能被单测直接调）
// ============================================================================

/// 响应体上限（与 `CURLOPT_MAXFILESIZE` 用同一个数）。这是**内存保护**，不是内容预算。
long long web_fetch_max_response_bytes();

// ============================================================================
// Python 探测的并发前提（change parallelize-readonly-tool-calls，design D9）
// ============================================================================

/// Python 探测的缓存状态：一份状态只探测一次。
///
/// 生产路径用一份进程级静态状态（`web_fetch.cpp` 里的 `detect_python()`）；测试
/// 可以自建一份，复现"多线程同时首次探测"这个调用形态。
struct PythonProbeState {
    std::once_flag once;
    std::atomic<bool> available{false};
};

/// 对 `state` 执行一次（且仅一次）Python 探测，返回探测结果。
///
/// 探测体只在 `std::call_once` 里跑一次，结果写进 `state.available` 后再对其它
/// 线程可见 —— 原实现用两个裸 bool 无锁读写，后到的线程可能读到"已置 checked、
/// 未置 available"的中间态，把"Python 可用"误判成"不可用"。
bool web_fetch_run_python_probe(PythonProbeState& state);

/// 当 libcurl 因为体积上限（或跳转次数）中止时，拼一条给用户与模型看的说明。
/// 说明里必须含：上限多少、服务端声明多大（读不到就写"未知大小"）、正文没被读取、
/// 以及本次抓取的网址 —— 好让"这个页面太大"和"网络坏了"能分清。
/// @param curl_result       libcurl 的返回码
/// @param declared_bytes    服务端声明的体积；<0 表示读不到
/// @param url               本次抓取的网址
/// @return 说明字符串；不是这两种错误时返回空串（由调用方走原来的通用分支）
std::string describe_fetch_size_rejection(int curl_result, long long declared_bytes,
                                          const std::string& url);

// ============================================================================
// 成功结果的 spill 交付形状（change `migrate-web-fetch-to-spill` 任务 2.1）
// ============================================================================

/// 把一次**成功**抓取的结果正文接进 spill 交付通道（`tool-output-spill` 能力）：
/// 完整正文先落盘到本上下文的 spill 目录（流名 `content`），再按 `preview_chars × 2`
/// 决定交付形态 —— 不超过阈值 ⇒ 内联全文；超过 ⇒ 头尾各 `preview_chars` 个字符 +
/// 省略说明，并把引用写进结果。
///
/// 写回 `result` 的字段：
///   - `content`：形状后的内联文本（就是交给模型与卡片的那份）；
///   - `truncated`：是否发生了头尾省略；
///   - `spill.content`：落盘成功时的信封（`ref` / `total_bytes` / `omitted_bytes` /
///     `head` / `tail`），落盘失败时没有这个键。
///
/// 写盘失败（规范"写盘失败必须可见"，对 `web_fetch` 同样适用）：
///   - 正文不超过 `preview_chars × 2` ⇒ 保持成功、原样内联全文（此时不丢内容）；
///   - 正文超过 `preview_chars × 2` ⇒ 整条结果改为 `{"ok":false,...}`，错误里带目录
///     与系统原因，SHALL NOT 只给头尾预览冒充完整正文。
///
/// `web_fetch_impl` 有**两个独立的成功 return**（crawl4ai 与 curl 兜底），不存在天然
/// 汇合点 —— 两个出口都必须各调它一次（漏一个即那条路径仍不落盘）。
///
/// @param ctx            要写入哪个上下文的 spill 目录（归属键就是它的名字）
/// @param result         成功结果 JSON，原地改写
/// @param preview_chars  头尾各留多少字符（来自请求字段，缺省 `spill::kDefaultPreviewChars`）
/// @return 是否因为写盘失败而把结果改成了 `ok:false`
bool web_fetch_shape_success_result(context::Context& ctx, nlohmann::json& result,
                                    long long preview_chars);

#endif // WEB_FETCH_H
