## ADDED Requirements

### Requirement: Web fetch via crawl4ai subprocess
The system SHALL fetch web pages by invoking a Python worker (`fetch_worker.py`) as a subprocess using the platform's native process API (`CreateProcess` on Windows, `fork`+`exec` on POSIX), communicating through stdin/stdout pipes with newline-delimited JSON. The Python worker SHALL use crawl4ai's `AsyncWebCrawler` to render the page and extract clean Markdown content.

#### Scenario: Successful fetch with crawl4ai
- **WHEN** `web_fetch` is called with `{"url": "https://example.com/article"}`
- **THEN** the C++ sidecar SHALL launch `fetch_worker.py` as a subprocess, write the JSON request to its stdin, read the JSON response from its stdout, and return `{"ok":true, "url":"https://example.com/article", "title":"Article Title", "content":"# Clean Markdown..."}`

#### Scenario: Markdown output quality
- **WHEN** a page with navigation, footer, sidebar, and article body is fetched via crawl4ai
- **THEN** the returned `content` SHALL be clean Markdown focused on the main article body. The content SHALL NOT include verbatim copies of navigation menus, footer links, or sidebar text in their entirety.

#### Scenario: Page title extracted
- **WHEN** a page with `<title>Example Page</title>` is fetched via crawl4ai
- **THEN** the response SHALL include `"title":"Example Page"` extracted from page metadata

#### Scenario: Missing title
- **WHEN** a page without a title (or where crawl4ai cannot extract one) is fetched
- **THEN** the response SHALL include `"title":""` (empty string, not null)

### Requirement: SSRF protection — pre-spawn IP validation
The system SHALL validate the target URL's resolved IP address(es) against the existing SSRF blocklist BEFORE spawning the Python subprocess. This replaces the curl-specific `CURLOPT_OPENSOCKETFUNCTION` callback with explicit pre-spawn checks. The blocklist SHALL cover the same ranges as the current implementation: IPv4 `127.0.0.0/8`, `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `169.254.0.0/16`, `0.0.0.0/8`, `100.64.0.0/10`; IPv6 `::1/128`, `fe80::/10`, `fc00::/7`, `::ffff:0:0/96`, `64:ff9b::/96`.

#### Scenario: Literal private IPv4 blocked
- **WHEN** `web_fetch` is called with `http://192.168.1.1/admin`
- **THEN** the URL is parsed, the hostname `192.168.1.1` is recognized as a literal IPv4 address, the IP matches the blocklist, and the request is rejected with `{"ok":false,"error":"Fetch failed: internal address not allowed"}` without spawning a subprocess

#### Scenario: Literal loopback IPv6 blocked
- **WHEN** `web_fetch` is called with `http://[::1]:8080/admin`
- **THEN** the hostname `::1` is recognized as a literal IPv6 address, matches the blocklist, and the request is rejected without spawning a subprocess

#### Scenario: DNS-resolved private IP blocked
- **WHEN** `web_fetch` is called with `http://internal.example.com` and DNS resolves `internal.example.com` to `10.0.0.5`
- **THEN** the C++ sidecar SHALL resolve the hostname via `getaddrinfo`, check the resolved IP `10.0.0.5` against the blocklist, and reject the request without spawning a subprocess

#### Scenario: DNS rebinding mitigated
- **WHEN** `web_fetch` is called with `http://127.0.0.1.nip.io/` and DNS resolves to `127.0.0.1`
- **THEN** the C++ sidecar SHALL check the resolved IP `127.0.0.1` against the blocklist, detect it is in `127.0.0.0/8`, and reject the request

#### Scenario: Public IP allowed
- **WHEN** `web_fetch` is called with `https://docs.flutter.dev/get-started`
- **THEN** all resolved IPs pass the blocklist check and the subprocess is spawned normally

#### Scenario: file:// scheme blocked
- **WHEN** `web_fetch` is called with `file:///etc/passwd`
- **THEN** the scheme validation SHALL reject it with `{"ok":false,"error":"Fetch failed: URL scheme not allowed"}`

#### Scenario: Localhost hostname blocked
- **WHEN** `web_fetch` is called with `http://localhost:8080/admin`
- **THEN** the hostname check SHALL reject it with `{"ok":false,"error":"Fetch failed: internal address not allowed"}`

### Requirement: JavaScript sub-request SSRF mitigation
The system SHALL configure the Playwright browser context in the Python worker to intercept and block HTTP requests to private and reserved IP ranges, preventing page JavaScript from exfiltrating internal network data via `fetch()` or `XMLHttpRequest`.

#### Scenario: Page JS fetch to private IP blocked
- **WHEN** a page loaded via crawl4ai contains JavaScript that calls `fetch("http://192.168.1.1/admin")`
- **THEN** the Playwright `page.route()` interceptor SHALL abort the request, and the response content SHALL NOT include data from the internal endpoint

#### Scenario: Page JS fetch to cloud metadata blocked
- **WHEN** a page loaded via crawl4ai contains JavaScript that calls `fetch("http://169.254.169.254/latest/meta-data/")`
- **THEN** the Playwright route interceptor SHALL abort the request

### Requirement: Python availability detection and fallback
The system SHALL detect Python availability at sidecar startup and cache the result. If Python is unavailable, `web_fetch` SHALL fall back to the existing curl + `strip_html_tags` implementation.

#### Scenario: Python available — uses crawl4ai
- **WHEN** `python3` or `python` is found on PATH at sidecar startup
- **THEN** `web_fetch` SHALL use the subprocess path for all fetch requests

#### Scenario: Python unavailable — falls back to curl
- **WHEN** neither `python3` nor `python` is found on PATH at sidecar startup
- **THEN** `web_fetch` SHALL use the existing curl-based implementation, and SHALL log an info message recommending `pip install crawl4ai` for better quality

#### Scenario: Subprocess failure triggers fallback
- **WHEN** the Python subprocess exits with non-zero code or cannot be launched
- **THEN** `web_fetch` SHALL fall back to the curl-based implementation for that specific request, and SHALL log a warning with the subprocess error details

### Requirement: Subprocess timeout and process-tree cleanup
The system SHALL enforce a 30-second wall-clock timeout on the Python subprocess. On timeout, the subprocess and all its descendants SHALL be forcibly terminated using platform-specific mechanisms that cover the entire process tree. After termination, all process handles and pipe handles SHALL be closed to prevent resource leaks.

#### Scenario: Subprocess completes within timeout
- **WHEN** crawl4ai completes the fetch within 30 seconds
- **THEN** the result SHALL be read from stdout, the process handles SHALL be closed, and the result returned normally

#### Scenario: Subprocess exceeds timeout — entire tree killed
- **WHEN** the Python subprocess has not returned a result after 30 seconds
- **THEN** the Python process and all its descendant processes (including Chromium) SHALL be forcibly terminated, all handles SHALL be cleaned up, and `web_fetch` SHALL fall back to the curl implementation with a warning logged

#### Scenario: Process tree cleanup on normal exit
- **WHEN** the subprocess exits normally
- **THEN** the system SHALL close all pipe handles and wait for the process to be reaped (preventing zombie processes)

### Requirement: Python worker URL validation
The Python worker (`fetch_worker.py`) SHALL perform basic URL validation (scheme check for `http`/`https`) as defense-in-depth before passing the URL to crawl4ai. This SHALL NOT replace C++-side SSRF checks but SHALL prevent accidental misuse if the worker is invoked directly.

#### Scenario: Worker rejects non-HTTP URL
- **WHEN** fetch_worker.py receives `{"url": "file:///etc/passwd"}`
- **THEN** the worker SHALL return `{"ok":false,"error":"URL scheme not allowed"}` without calling crawl4ai

#### Scenario: Worker passes valid URL through
- **WHEN** fetch_worker.py receives `{"url": "https://example.com"}`
- **THEN** the worker SHALL proceed with crawl4ai extraction normally

### Requirement: Worker script discovery
The C++ sidecar SHALL locate `fetch_worker.py` using a path resolved from the sidecar shared library's own filesystem location, NOT from the current working directory. The resolution strategy SHALL support both development (building from source) and installed (packaged application) layouts.

#### Scenario: Script found in development layout
- **WHEN** the sidecar DLL/SO is located at `<project>/build/windows/x64/runner/Debug/sidecar.dll`
- **THEN** the sidecar SHALL find `fetch_worker.py` at `<project>/scripts/fetch_worker.py`

#### Scenario: Script found in installed layout
- **WHEN** the sidecar is installed to `<prefix>/lib/sidecar.dll` or `<prefix>/lib/sidecar.so`
- **THEN** the sidecar SHALL find `fetch_worker.py` at `<prefix>/share/aliasagent/scripts/fetch_worker.py`

### Requirement: Tool definition simplified
The `web_fetch` tool definition sent to the model SHALL only require `url`. The `extract_mode` parameter SHALL be removed.

#### Scenario: Tool definition has only url parameter
- **WHEN** the tool definitions are built for the model
- **THEN** `web_fetch` SHALL have a single required parameter `url` of type string

### Requirement: Response URL echo
The `web_fetch` success response SHALL include the requested `url` field echoing the original request URL.

#### Scenario: URL echoed in response
- **WHEN** `web_fetch` is called with `{"url": "https://example.com/page"}`
- **THEN** the success response SHALL include `"url":"https://example.com/page"`
