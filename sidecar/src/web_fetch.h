#ifndef WEB_FETCH_H
#define WEB_FETCH_H

#include <string>
#include <cstdint>
#include <cstddef>

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

#endif // WEB_FETCH_H
