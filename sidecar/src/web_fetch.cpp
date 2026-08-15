#include "web_fetch.h"
#include "tools.h"
#include "logger.h"
#include "subprocess.h"
#include <nlohmann/json.hpp>
#include <curl/curl.h>
#include <string>
#include <cstring>
#include <algorithm>
#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <chrono>
#include <thread>

// Platform-specific subprocess headers
#ifdef _WIN32
#include <windows.h>
#include <winsock2.h>
#include <ws2tcpip.h>
#pragma comment(lib, "ws2_32.lib")
#else
#include <unistd.h>
#include <sys/wait.h>
#include <signal.h>
#include <sys/select.h>
#include <fcntl.h>
#include <netdb.h>
#include <arpa/inet.h>
#endif

using json = nlohmann::json;

// ============================================================================
// Constants
// ============================================================================

// Write callback — appends received data to FetchWriteCtx body.
// Size protection via CURLOPT_MAXFILESIZE (pre-transfer) and 15s timeout.

// Timeout values
static const long FETCH_TIMEOUT_SEC = 15L;
static const long FETCH_CONNECT_TIMEOUT_SEC = 15L;

// Max redirect hops
static const long MAX_REDIRECTS = 5L;

// Subprocess timeout (30s for crawl4ai — browser startup + render)
static const long SUBPROCESS_TIMEOUT_SEC = 30L;

// ============================================================================
// Python availability detection (cached at startup)
// ============================================================================

static bool g_python_available = false;
static bool g_python_checked = false;
#ifdef _WIN32
static const char* PYTHON_BINARIES[] = {"python", "python3", nullptr};
#else
static const char* PYTHON_BINARIES[] = {"python3", "python", nullptr};
#endif

static void detect_python() {
  if (g_python_checked) return;
  g_python_checked = true;
  for (int i = 0; PYTHON_BINARIES[i] != nullptr; ++i) {
    std::string cmd = std::string(PYTHON_BINARIES[i]) + " --version";
#ifdef _WIN32
    FILE* fp = _popen(cmd.c_str(), "r");
#else
    FILE* fp = popen(cmd.c_str(), "r");
#endif
    if (fp) {
      char buf[128] = {0};
      if (fgets(buf, sizeof(buf), fp) && buf[0] != '\0') {
        int ret = -1;
#ifdef _WIN32
        ret = _pclose(fp);
#else
        ret = pclose(fp);
#endif
        if (ret == 0) {
          g_python_available = true;
          LOG_INFO("Python detected: " + std::string(buf));
          return;
        }
      } else {
#ifdef _WIN32
        _pclose(fp);
#else
        pclose(fp);
#endif
      }
    }
  }
  LOG_INFO("Python not found on PATH — web_fetch will use curl fallback");
}

// ============================================================================
// Script path resolution
// ============================================================================

/// Locate fetch_worker.py relative to the sidecar DLL/SO location.
/// Searches: ../scripts/ (dev layout), ../share/aliasagent/scripts/ (installed layout)
static std::string resolve_script_path() {
#ifdef _WIN32
  char dll_path[MAX_PATH] = {0};
  HMODULE hModule = nullptr;
  // Get handle to this DLL — use a static variable address trick
  static int dummy = 0;
  GetModuleHandleExA(
    GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
    (LPCSTR)&dummy, &hModule);
  if (hModule) {
    GetModuleFileNameA(hModule, dll_path, sizeof(dll_path));
  }
#else
  char dll_path[4096] = {0};
  // Read /proc/self/maps to find the .so path (simpler than dladdr for static builds)
  FILE* maps = fopen("/proc/self/maps", "r");
  if (maps) {
    char line[4096];
    while (fgets(line, sizeof(line), maps)) {
      if (strstr(line, "sidecar.so") || strstr(line, "libsidecar")) {
        char* path_start = strchr(line, '/');
        if (path_start) {
          char* end = strchr(path_start, '\n');
          if (end) *end = '\0';
          strncpy(dll_path, path_start, sizeof(dll_path) - 1);
          break;
        }
      }
    }
    fclose(maps);
  }
#endif

  std::string dir;
  if (dll_path[0] != '\0') {
    dir = dll_path;
    size_t last_sep = dir.find_last_of("\\/");
    if (last_sep != std::string::npos) {
      dir = dir.substr(0, last_sep);
    }
  }

  // Check candidate paths
  const char* candidates[] = {
    "/../scripts/fetch_worker.py",
    "/scripts/fetch_worker.py",
    "/../share/aliasagent/scripts/fetch_worker.py",
    "/share/aliasagent/scripts/fetch_worker.py",
  };

  for (const auto* suffix : candidates) {
    std::string candidate = dir + suffix;
    FILE* test = fopen(candidate.c_str(), "r");
    if (test) {
      fclose(test);
      LOG_INFO("Found fetch_worker.py at: " + candidate);
      return candidate;
    }
  }

  // Last resort: check CWD-relative
  const char* cwd_candidates[] = {
    "scripts/fetch_worker.py",
    "../scripts/fetch_worker.py",
  };
  for (const auto* c : cwd_candidates) {
    FILE* test = fopen(c, "r");
    if (test) {
      fclose(test);
      LOG_INFO("Found fetch_worker.py at (CWD): " + std::string(c));
      return c;
    }
  }

  LOG_INFO("fetch_worker.py not found");
  return "scripts/fetch_worker.py";  // best guess; launch will fail if missing
}

// ============================================================================
// SSRF pre-spawn check (hostname → IP resolution + blocklist)
// ============================================================================

/// Check if a hostname (already extracted from URL) resolves to a blocked IP.
/// Returns true if BLOCKED (SSRF), false if safe.
static bool is_hostname_ssrf_blocked(const std::string& hostname) {
  // First: check if it's a literal IPv4 address
  struct in_addr ip4;
#ifdef _WIN32
  if (InetPtonA(AF_INET, hostname.c_str(), &ip4) == 1) {
#else
  if (inet_pton(AF_INET, hostname.c_str(), &ip4) == 1) {
#endif
    uint32_t ip = ntohl(ip4.s_addr);
    if (is_blocked_ipv4(ip)) {
      LOG_WARN("SSRF: blocked literal IPv4 address: " + hostname);
      return true;
    }
    return false;  // valid public IP literal, allow
  }

  // Check if it's a literal IPv6 address (bracket notation stripped by caller)
  struct in6_addr ip6;
#ifdef _WIN32
  if (InetPtonA(AF_INET6, hostname.c_str(), &ip6) == 1) {
#else
  if (inet_pton(AF_INET6, hostname.c_str(), &ip6) == 1) {
#endif
    if (is_blocked_ipv6(ip6.s6_addr)) {
      LOG_WARN("SSRF: blocked literal IPv6 address: " + hostname);
      return true;
    }
    return false;
  }

  // Not a literal IP — resolve via DNS and check ALL returned addresses
  struct addrinfo hints = {};
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_STREAM;
  struct addrinfo* result = nullptr;

  int ret = getaddrinfo(hostname.c_str(), nullptr, &hints, &result);
  if (ret != 0) {
    LOG_WARN("SSRF: DNS resolution failed for " + hostname + " — " + gai_strerror(ret));
    // Conservative: block on DNS failure (don't allow blind bypass)
    return true;
  }

  bool blocked = false;
  for (struct addrinfo* rp = result; rp != nullptr; rp = rp->ai_next) {
    if (rp->ai_family == AF_INET) {
      struct sockaddr_in* addr4 = reinterpret_cast<struct sockaddr_in*>(rp->ai_addr);
      uint32_t ip = ntohl(addr4->sin_addr.s_addr);
      if (is_blocked_ipv4(ip)) {
        LOG_WARN("SSRF: DNS-resolved blocked IPv4: " + hostname);
        blocked = true;
        break;
      }
    } else if (rp->ai_family == AF_INET6) {
      struct sockaddr_in6* addr6 = reinterpret_cast<struct sockaddr_in6*>(rp->ai_addr);
      if (is_blocked_ipv6(addr6->sin6_addr.s6_addr)) {
        LOG_WARN("SSRF: DNS-resolved blocked IPv6: " + hostname);
        blocked = true;
        break;
      }
    }
  }

  freeaddrinfo(result);
  return blocked;
}

// ============================================================================
// crawl4ai subprocess execution with timeout
// ============================================================================

/// Run the crawl4ai Python subprocess and return the JSON result string.
/// On failure (timeout, subprocess error, script not found), returns empty string
/// so the caller can fall back to curl.
static std::string run_crawl4ai_subprocess(const std::string& url,
                                            const std::string& script_path) {
  // Detect Python binary
  const char* python_bin = nullptr;
  for (int i = 0; PYTHON_BINARIES[i] != nullptr; ++i) {
    std::string cmd = std::string(PYTHON_BINARIES[i]) + " --version";
#ifdef _WIN32
    FILE* test = _popen(cmd.c_str(), "r");
#else
    FILE* test = popen(cmd.c_str(), "r");
#endif
    if (test) {
#ifdef _WIN32
      _pclose(test);
#else
      pclose(test);
#endif
      python_bin = PYTHON_BINARIES[i];
      break;
    }
  }
  if (!python_bin) {
    LOG_WARN("web_fetch: Python not available at subprocess call time");
    return "";
  }

  std::vector<std::string> argv;
  argv.push_back(python_bin);
  argv.push_back(script_path);

  json req;
  req["url"] = url;
  std::string req_str = req.dump() + "\n";

  subprocess::Options opts;
  opts.stdin_data = req_str;
  opts.timeout_seconds = SUBPROCESS_TIMEOUT_SEC;
  subprocess::Result res = subprocess::run(argv, opts);

  if (!res.started) {
    LOG_WARN("web_fetch: failed to start subprocess");
    return "";
  }
  if (res.timed_out) {
    LOG_WARN("web_fetch: subprocess timed out after " +
             std::to_string(SUBPROCESS_TIMEOUT_SEC) + "s");
    return "";
  }
  if (!res.stderr_data.empty()) {
    if (res.exit_code == 0) {
      LOG_TRACE("web_fetch: subprocess stderr: " + res.stderr_data);
    } else {
      LOG_WARN("web_fetch: subprocess stderr: " + res.stderr_data);
    }
  }
  // crawl4ai uses non-zero exit = failure (this skeleton's semantics — the
  // rg search tools use rg's 0/1/2 three-state exit codes instead).
  if (res.exit_code != 0) {
    LOG_WARN("web_fetch: subprocess failed (exit=" + std::to_string(res.exit_code) + ")");
    return "";
  }

  // Parse output — first line is JSON
  if (res.stdout_data.empty()) {
    LOG_WARN("web_fetch: subprocess produced no output");
    return "";
  }

  // Strip trailing newline
  while (!res.stdout_data.empty() &&
         (res.stdout_data.back() == '\n' || res.stdout_data.back() == '\r')) {
    res.stdout_data.pop_back();
  }
  LOG_INFO("web_fetch: crawl4ai returned " + std::to_string(res.stdout_data.size()) + " bytes");
  return res.stdout_data;
}

// ============================================================================
// URL pre-flight helpers (task 3.2)
// ============================================================================

/// Case-insensitive string comparison
bool iequals(const std::string& a, const std::string& b) {
  if (a.size() != b.size()) return false;
  for (size_t i = 0; i < a.size(); ++i) {
    if (std::tolower(static_cast<unsigned char>(a[i])) !=
        std::tolower(static_cast<unsigned char>(b[i])))
      return false;
  }
  return true;
}

/// Extract the MIME type from a Content-Type value (part before ';').
std::string extract_mime_type(const std::string& content_type) {
  size_t semi = content_type.find(';');
  if (semi != std::string::npos) {
    return content_type.substr(0, semi);
  }
  return content_type;
}

// ============================================================================
// SSRF socket-level protection (task 3.1)
// ============================================================================

/// Check if an IPv4 address is in the blocklist.
bool is_blocked_ipv4(uint32_t ip_host_order) {
  uint8_t b0 = (ip_host_order >> 24) & 0xFF;
  // 0.0.0.0/8
  if (b0 == 0) return true;
  // 10.0.0.0/8
  if (b0 == 10) return true;
  // 127.0.0.0/8
  if (b0 == 127) return true;
  // 169.254.0.0/16
  if (b0 == 169 && ((ip_host_order >> 16) & 0xFF) == 254) return true;
  // 172.16.0.0/12
  if (b0 == 172 && ((ip_host_order >> 16) & 0xFF) >= 16 && ((ip_host_order >> 16) & 0xFF) <= 31) return true;
  // 192.168.0.0/16
  if (b0 == 192 && ((ip_host_order >> 16) & 0xFF) == 168) return true;
  // 100.64.0.0/10 (100.64.0.0 – 100.127.255.255)
  if (b0 == 100 && ((ip_host_order >> 16) & 0xFF) >= 64 && ((ip_host_order >> 16) & 0xFF) <= 127) return true;
  return false;
}

/// Check if an IPv6 address is in the blocklist.
bool is_blocked_ipv6(const unsigned char* bytes) {
  // ::1/128 (loopback) — first 15 bytes 0x00, last byte 0x01
  {
    bool is_loopback = true;
    for (int i = 0; i < 15; ++i) {
      if (bytes[i] != 0x00) { is_loopback = false; break; }
    }
    if (is_loopback && bytes[15] == 0x01) return true;
  }

  // ::ffff:0:0/96 (IPv4-mapped IPv6) — first 10 bytes 0x00, bytes 10-11 = 0xFF 0xFF
  {
    bool is_ipv4_mapped = true;
    for (int i = 0; i < 10; ++i) {
      if (bytes[i] != 0x00) { is_ipv4_mapped = false; break; }
    }
    if (is_ipv4_mapped && bytes[10] == 0xFF && bytes[11] == 0xFF) {
      // Extract embedded IPv4 (bytes 12-15)
      uint32_t embedded_ip = (static_cast<uint32_t>(bytes[12]) << 24) |
                             (static_cast<uint32_t>(bytes[13]) << 16) |
                             (static_cast<uint32_t>(bytes[14]) << 8)  |
                              static_cast<uint32_t>(bytes[15]);
      return is_blocked_ipv4(embedded_ip);
    }
  }

  // 64:ff9b::/96 (NAT64 Well-Known Prefix, RFC 6052)
  // First 12 bytes: 0x00 0x64 0xff 0x9b 0x00 ... 0x00
  if (bytes[0] == 0x00 && bytes[1] == 0x64 && bytes[2] == 0xff && bytes[3] == 0x9b) {
    bool is_nat64 = true;
    for (int i = 4; i < 12; ++i) {
      if (bytes[i] != 0x00) { is_nat64 = false; break; }
    }
    if (is_nat64) {
      // Extract embedded IPv4 (bytes 12-15)
      uint32_t embedded_ip = (static_cast<uint32_t>(bytes[12]) << 24) |
                             (static_cast<uint32_t>(bytes[13]) << 16) |
                             (static_cast<uint32_t>(bytes[14]) << 8)  |
                              static_cast<uint32_t>(bytes[15]);
      return is_blocked_ipv4(embedded_ip);
    }
  }

  // fe80::/10 (link-local) — first byte 0xFE, second byte 0x80-0xBF
  if (bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80) return true;

  // fc00::/7 (unique local) — first byte 0xFC or 0xFD
  if (bytes[0] == 0xFC || bytes[0] == 0xFD) return true;

  return false;
}

/// CURLOPT_OPENSOCKETFUNCTION callback.
/// Validates the resolved socket address against the SSRF blocklist.
/// Fires after DNS resolution but before connect(), for every connection
/// (including redirect targets). Creates the actual socket and returns it,
/// or returns CURL_SOCKET_BAD to block the connection.
static curl_socket_t opensocket_callback(void* clientp, curlsocktype purpose,
                                             struct curl_sockaddr* address) {
  (void)clientp;
  (void)purpose;

  if (!address) {
    LOG_WARN("SSRF: opensocket callback received null address — blocking (default-deny)");
    return CURL_SOCKET_BAD;
  }

  // curl_sockaddr::addr is a struct sockaddr (by value on Windows)
  struct sockaddr* sa = &address->addr;

  if (address->family == AF_INET) {
    struct sockaddr_in* addr4 = reinterpret_cast<struct sockaddr_in*>(sa);
    uint32_t ip = ntohl(addr4->sin_addr.s_addr);
    if (is_blocked_ipv4(ip)) {
      LOG_WARN("SSRF: blocked IPv4 connection to " +
               std::to_string((ip >> 24) & 0xFF) + "." +
               std::to_string((ip >> 16) & 0xFF) + "." +
               std::to_string((ip >> 8) & 0xFF) + "." +
               std::to_string(ip & 0xFF));
      return CURL_SOCKET_BAD;
    }
  } else if (address->family == AF_INET6) {
    struct sockaddr_in6* addr6 = reinterpret_cast<struct sockaddr_in6*>(sa);
    if (is_blocked_ipv6(addr6->sin6_addr.s6_addr)) {
      LOG_WARN("SSRF: blocked IPv6 connection");
      return CURL_SOCKET_BAD;
    }
  } else {
    // Default-deny for unknown address families
    LOG_WARN("SSRF: blocked connection — unknown sa_family=" +
             std::to_string(address->family));
    return CURL_SOCKET_BAD;
  }

  // Create the actual socket and return it
  curl_socket_t sockfd = socket(address->family, address->socktype, address->protocol);
  return sockfd;
}

// ============================================================================
// Write callback — appends received data
// ============================================================================

size_t fetch_write_callback(char* ptr, size_t size, size_t nmemb, void* userdata) {
  auto* ctx = static_cast<FetchWriteCtx*>(userdata);
  size_t total = size * nmemb;
  ctx->body.append(ptr, total);
  ctx->accumulated += total;
  return total;
}

// ============================================================================
// HTML tag stripping (task 3.4)
// ============================================================================

std::string strip_html_tags(const std::string& html) {
  std::string result;
  result.reserve(html.size());
  bool in_tag = false;
  bool in_script_style = false;
  std::string tag_name;
  bool last_was_space = false;

  for (size_t i = 0; i < html.size(); ++i) {
    char c = html[i];

    if (c == '<') {
      in_tag = true;
      tag_name.clear();
      continue;
    }

    if (in_tag) {
      if (c == '>') {
        in_tag = false;
        // Check if we're entering/leaving a script or style block
        std::string lower;
        for (char tc : tag_name) lower += static_cast<char>(std::tolower(static_cast<unsigned char>(tc)));
        if (!in_script_style && (lower == "script" || lower == "style")) {
          in_script_style = true;
        } else if (in_script_style && (lower == "/script" || lower == "/style")) {
          in_script_style = false;
        }
        tag_name.clear();
      } else if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
        // Tag name ended, attributes starting — still in tag
        // Mark the tag name as complete so we know what tag it is
      } else if (tag_name.empty() ||
                 (!tag_name.empty() && tag_name.find(' ') == std::string::npos)) {
        tag_name += c;
      }
      continue;
    }

    if (in_script_style) {
      continue; // skip script/style body
    }

    // Handle whitespace — compress to single space
    if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
      if (!last_was_space && !result.empty()) {
        result += ' ';
        last_was_space = true;
      }
    } else {
      result += c;
      last_was_space = false;
    }
  }

  // Trim trailing whitespace
  while (!result.empty() && (result.back() == ' ' || result.back() == '\n')) {
    result.pop_back();
  }
  // Trim leading whitespace
  size_t start = 0;
  while (start < result.size() && (result[start] == ' ' || result[start] == '\n')) {
    start++;
  }
  if (start > 0) result = result.substr(start);

  return result;
}

// ============================================================================
// Main web_fetch implementation (tasks 3.4, 3.5, 3.6)
// ============================================================================

std::string web_fetch_impl(const std::string& request_json) {
  try {
    auto req = json::parse(request_json);

    // Validate URL
    if (!req.contains("url") || !req["url"].is_string()) {
      return "{\"ok\":false,\"error\":\"URL is required\"}";
    }

    std::string url = req["url"].get<std::string>();
    if (url.empty()) {
      return "{\"ok\":false,\"error\":\"URL is empty\"}";
    }

    // extract_mode is deprecated — crawl4ai always produces markdown, curl produces tag-stripped text
    // Keep parameter parsing for backward compat but ignore the value

    // ---- URL pre-flight checks (task 3.2) ----

    // Case-insensitive scheme validation — lowercase before compare
    std::string url_lower = url;
    for (auto& c : url_lower) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));

    if (url_lower.rfind("http://", 0) != 0 && url_lower.rfind("https://", 0) != 0) {
      return "{\"ok\":false,\"error\":\"Fetch failed: URL scheme not allowed\"}";
    }

    // Reject localhost hostname (case-insensitive)
    // Extract hostname: after "://" and before next '/' or ':'
    size_t host_start = url_lower.find("://");
    if (host_start != std::string::npos) {
      host_start += 3;
      size_t host_end = url_lower.find_first_of("/:@", host_start);
      if (host_end == std::string::npos) host_end = url_lower.size();
      std::string hostname = url_lower.substr(host_start, host_end - host_start);

      if (hostname == "localhost") {
        return "{\"ok\":false,\"error\":\"Fetch failed: internal address not allowed\"}";
      }
    }

    LOG_INFO("web_fetch: url=" + url);

    // ---- Try crawl4ai subprocess if Python is available ----

    detect_python();  // lazy-init at first web_fetch call

    if (g_python_available) {
      // SSRF pre-spawn check: validate resolved IPs before spawning subprocess
      // Extract hostname (already done above for localhost, redo for IP check)
      std::string ssrf_hostname;
      size_t hs = url_lower.find("://");
      if (hs != std::string::npos) {
        hs += 3;
        // Strip IPv6 bracket notation [::1] → ::1
        std::string raw_host;
        size_t he = url_lower.find_first_of("/:@", hs);
        if (he == std::string::npos) he = url_lower.size();
        raw_host = url_lower.substr(hs, he - hs);
        if (!raw_host.empty() && raw_host.front() == '[' && raw_host.back() == ']') {
          ssrf_hostname = raw_host.substr(1, raw_host.size() - 2);
        } else {
          ssrf_hostname = raw_host;
        }
      }

      if (!ssrf_hostname.empty() && is_hostname_ssrf_blocked(ssrf_hostname)) {
        return "{\"ok\":false,\"error\":\"Fetch failed: internal address not allowed\"}";
      }

      // Launch subprocess
      std::string script_path = resolve_script_path();
      std::string subprocess_result = run_crawl4ai_subprocess(url, script_path);

      if (!subprocess_result.empty()) {
        // Validate that the subprocess returned valid JSON
        try {
          auto parsed = json::parse(subprocess_result);
          if (parsed.contains("ok") && parsed["ok"].is_boolean() && parsed["ok"].get<bool>()) {
            // Ensure url field is present
            if (!parsed.contains("url")) parsed["url"] = url;
            if (!parsed.contains("title")) parsed["title"] = "";
            LOG_INFO("web_fetch: crawl4ai success — " +
                     std::to_string(parsed.value("content", "").size()) + " chars");
            return parsed.dump();
          }
          // Subprocess returned ok:false — fall through to curl
          LOG_WARN("web_fetch: crawl4ai returned error: " +
                   parsed.value("error", "unknown"));
        } catch (...) {
          LOG_WARN("web_fetch: crawl4ai returned invalid JSON — falling back to curl");
        }
      }
      LOG_INFO("web_fetch: crawl4ai path failed — falling back to curl");
    }

    // ---- Setup curl (fallback) ----

    CURL* curl = curl_easy_init();
    if (!curl) {
      return "{\"ok\":false,\"error\":\"Fetch failed: curl init error\"}";
    }

    FetchWriteCtx write_ctx;

    // Task 3.5: Configure curl options
    curl_easy_setopt(curl, CURLOPT_URL, url.c_str());
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, fetch_write_callback);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, &write_ctx);
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, FETCH_TIMEOUT_SEC);
    curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT, FETCH_CONNECT_TIMEOUT_SEC);
    curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 1L);
    curl_easy_setopt(curl, CURLOPT_MAXREDIRS, MAX_REDIRECTS);
    curl_easy_setopt(curl, CURLOPT_REDIR_PROTOCOLS_STR, "http,https");
    curl_easy_setopt(curl, CURLOPT_PROTOCOLS, CURLPROTO_HTTP | CURLPROTO_HTTPS);
    curl_easy_setopt(curl, CURLOPT_ACCEPT_ENCODING, "");
    curl_easy_setopt(curl, CURLOPT_MAXFILESIZE, 10L * 1024 * 1024);  // 10MB — reject oversized responses pre-transfer
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, 1L);
    curl_easy_setopt(curl, CURLOPT_USERAGENT, "AliasAgent/1.0 WebFetcher");
    curl_easy_setopt(curl, CURLOPT_OPENSOCKETFUNCTION, opensocket_callback);
    curl_easy_setopt(curl, CURLOPT_OPENSOCKETDATA, nullptr);

    // ---- Execute ----

    CURLcode res = curl_easy_perform(curl);

    // Check for errors (task 3.6)
    if (res != CURLE_OK) {
      std::string curl_err = curl_easy_strerror(res);
      curl_easy_cleanup(curl);

      // Determine error type
      if (res == CURLE_OPERATION_TIMEDOUT || res == CURLE_COULDNT_CONNECT) {
        return "{\"ok\":false,\"error\":\"Fetch failed: timeout\"}";
      }
      if (res == CURLE_SSL_CONNECT_ERROR || res == CURLE_SSL_CERTPROBLEM ||
          res == CURLE_SSL_CIPHER || res == CURLE_SSL_CACERT) {
        return "{\"ok\":false,\"error\":\"Fetch failed: TLS error\"}";
      }
      if (res == CURLE_COULDNT_RESOLVE_HOST) {
        return "{\"ok\":false,\"error\":\"Fetch failed: host not found\"}";
      }
      if (res == CURLE_UNSUPPORTED_PROTOCOL) {
        return "{\"ok\":false,\"error\":\"Fetch failed: URL scheme not allowed\"}";
      }

      // Check if the error looks like an SSRF block
      // (libcurl may report "Connection refused" or similar for CURL_SOCKET_BAD)
      return "{\"ok\":false,\"error\":\"Fetch failed: " + tools::json_escape(curl_err) + "\"}";
    }

    // Check HTTP status code
    long http_code = 0;
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &http_code);

    if (http_code >= 400) {
      curl_easy_cleanup(curl);
      return "{\"ok\":false,\"error\":\"Fetch failed: HTTP " + std::to_string(http_code) + "\"}";
    }

    // Check Content-Type for extraction strategy
    char* content_type_ptr = nullptr;
    curl_easy_getinfo(curl, CURLINFO_CONTENT_TYPE, &content_type_ptr);

    std::string body = std::move(write_ctx.body);
    curl_easy_cleanup(curl);

    // Task 3.4: Content-Type based extraction
    // NULL Content-Type → treat as raw (conservative default)
    if (content_type_ptr == nullptr) {
      LOG_INFO("web_fetch: no Content-Type — returning raw text (" +
               std::to_string(body.size()) + " bytes)");
    } else {
      std::string content_type(content_type_ptr);
      std::string mime_type = extract_mime_type(content_type);

      // Case-insensitive exact equality match on MIME type
      if (iequals(mime_type, "text/html")) {
        LOG_INFO("web_fetch: Content-Type=" + content_type + " — stripping HTML tags");
        body = strip_html_tags(body);
      } else {
        LOG_INFO("web_fetch: Content-Type=" + content_type + " — returning raw text");
      }
    }

    // Build result JSON (includes url + title for consistency with crawl4ai path)
    json result;
    result["ok"] = true;
    result["url"] = url;
    result["title"] = "";
    result["content"] = body;
    return result.dump();

  } catch (const json::parse_error& e) {
    return "{\"ok\":false,\"error\":\"Fetch failed: invalid request JSON — " +
           tools::json_escape(e.what()) + "\"}";
  } catch (const std::exception& e) {
    return "{\"ok\":false,\"error\":\"Fetch failed: " +
           tools::json_escape(e.what()) + "\"}";
  } catch (...) {
    return "{\"ok\":false,\"error\":\"Fetch failed: unknown error\"}";
  }
}
