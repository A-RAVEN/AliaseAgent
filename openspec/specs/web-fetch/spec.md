# web-fetch Specification

## Purpose
本文件规定 `web_fetch` 工具的行为：抓取路径（Python 抓取器优先、curl 兜底）、防内网访问、体积与超时保护，以及被拒时说明里必须交代的内容，以及结果正文的 spill 交付形态。
## Requirements
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

### Requirement: Concurrent pipe reading (deadlock prevention)
The system SHALL read stdout and stderr pipes concurrently while waiting for the subprocess to exit, on both Windows and POSIX. The system SHALL NOT wait for the process to exit before reading pipe data. After the process exits or is killed, the system SHALL perform a final drain of both pipes (reading until no data remains) before closing handles. Pipe buffers SHALL be created with a size of at least 1MB to accommodate typical output volumes.

#### Scenario: Large stdout does not deadlock
- **WHEN** the subprocess writes >4KB to stdout (e.g., a 45KB JSON result for a large page)
- **THEN** the parent process SHALL read stdout data concurrently via non-blocking I/O, the subprocess SHALL NOT block on stdout write, and the full output SHALL be captured

#### Scenario: Large stderr does not deadlock
- **WHEN** the subprocess writes >4KB to stderr (e.g., environment variable dump + progress logs)
- **THEN** the parent process SHALL read stderr data concurrently via non-blocking I/O, the subprocess SHALL NOT block on stderr write

#### Scenario: Final drain after process exit
- **WHEN** the subprocess exits and there is still data in the stdout or stderr pipe buffer
- **THEN** the system SHALL read all remaining data from both pipes before closing handles and processing the result

#### Scenario: Final drain after timeout kill
- **WHEN** the subprocess is killed after timeout and there is partial data in the pipe buffer
- **THEN** the system SHALL read all available remaining data from both pipes before closing handles

### Requirement: Subprocess stderr capture
The system SHALL capture the subprocess's stderr output via a dedicated pipe and log it to sidecar.log. On success, stderr SHALL be logged at TRACE level. On failure or timeout, stderr SHALL be logged at WARN level. The stderr pipe read SHALL use non-blocking I/O to prevent hangs from orphaned descendant processes holding the write end.

#### Scenario: Successful fetch logs stderr at DEBUG
- **WHEN** the subprocess completes successfully and produced stderr output (e.g., crawl4ai progress logs)
- **THEN** the stderr content SHALL be logged via LOG_DEBUG with prefix "web_fetch: subprocess stderr:"

#### Scenario: Failed fetch logs stderr at WARN
- **WHEN** the subprocess exits with non-zero code or times out
- **THEN** the stderr content SHALL be logged via LOG_WARN with prefix "web_fetch: subprocess stderr:"

#### Scenario: Orphaned descendant does not hang stderr read
- **WHEN** the subprocess is killed but a Chromium descendant still holds the stderr write end
- **THEN** the non-blocking stderr read SHALL return available data without blocking indefinitely

### Requirement: Curl fallback size protection
The curl fallback path SHALL use `CURLOPT_MAXFILESIZE` (10MB) to reject responses whose Content-Length exceeds the limit before transfer begins. The previous 100KB incremental write callback cap SHALL be removed. For chunked responses without Content-Length, the 15-second timeout SHALL serve as the transfer volume bound.

**越界必须可见且可恢复**（并入 `truncation-visibility` 的总规则）：当响应因为体积被拒（Content-Length 超过上限）时，`web_fetch` 返回的错误说明 SHALL 写明：①这是因为体积上限而不是网络故障；②上限是多少、以及服务端声明的体积是多少（读不到就说明读不到）；③被拒的响应体**没有**被读取。错误说明里 SHALL 含本次实际请求的网址。

**现状与改动点**（写进规范是为了让判据有对照）：`CURLOPT_MAXFILESIZE` 已在用（10MB）。提案时点该拒绝**没有专门分支**（落到 `Fetch failed: <libcurl 的英文错误文本>`，无上限数字、无网址）；change `fix-silent-truncation` 已补上专门分支（`sidecar/src/web_fetch.cpp` 的 `CURLE_FILESIZE_EXCEEDED` 一支，写出上限与实际请求网址），与本段三条件对齐。本要求在已归档状态上只追加下面两条新场景（spill 交付形态），既有的三个原始场景与"体积被拒"场景文字保持原样。

#### Scenario: Response with large Content-Length rejected

- **WHEN** the curl fallback fetches a URL whose server responds with `Content-Length: 50000000` (50MB)
- **THEN** curl SHALL abort before downloading the body, and `web_fetch` SHALL return an error

#### Scenario: Normal page under limit fetched fully

- **WHEN** the curl fallback fetches a 500KB HTML page
- **THEN** the full response body SHALL be received and processed without truncation

#### Scenario: Chunked response bounded by timeout

- **WHEN** the curl fallback fetches a chunked response (no Content-Length) that streams indefinitely
- **THEN** the 15-second timeout SHALL terminate the transfer

#### Scenario: 体积被拒时的说明要指名上限与网址

- **WHEN** 响应因为 Content-Length 超过 10MB 而被拒
- **THEN** 错误说明 SHALL 含上限（10MB）、服务端声明的体积、以及本次请求的网址；只回 `Fetch failed: <libcurl 英文原文>` SHALL 算不满足本场景

#### Scenario: 正文超预览阈值时交付 spill 引用而不是硬切

- **WHEN** `web_fetch` 抓回的正文长度超过 `preview_chars × 2`（`spill.preview_chars`，默认 1000）
- **THEN** 模型可见正文 SHALL 为"头 `preview_chars` 字符 + 省略说明（含省略字节数、总量、spill 引用与 `read_spill` 读回参数）+ 尾 `preview_chars` 字符"，末尾另带一行 spill 引用；SHALL NOT 出现"只保留前 N 个字符、不交代略去多少与如何取回"的形态（旧 Dart 侧 2000 字符硬切连同其三个点标记废除）

#### Scenario: 通用截断的再取入口带网址

- **WHEN** `web_fetch` 的结果正文超过通用截断阈值，被替换成"头 + 尾 + 标记"
- **THEN** 标记里 SHALL 含本次抓取的网址（`refetch via web_fetch "<网址>"` 这样的可执行形态）；`web_fetch` 的输入参数没有 `path`，因此 SHALL NOT 依赖 `path` 来拼这个入口

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

### Requirement: web_fetch 结果交付给模型的形态

`web_fetch` 成功结果交付给模型的正文 SHALL 按以下形态拼装（Dart 侧后处理，替换旧的"前 2000 字符加三个点"）：

1. 第一行标题（页面 `<title>`，为空时用网址）、第二行网址；
2. 正文为 C++ 侧 spill 形状后的内联文本：不超阈值时就是完整正文；超阈值时为头尾预览加省略说明；
3. 落了盘时，**最后一行** SHALL 是 `[spill refs: content=<引用> (<总字节> bytes, <省略字节> omitted) …read_spill(ref, offset, limit)]` 形态的引用行——放最后一行是为了重放阶段的通用省略（保头保尾）掐不到取回入口；
4. 正文为空时 SHALL 给 `(fetched empty page)` 提示（既有行为保留），此时不产生 spill 引用；
5. 交付给界面结果卡片的文本 SHALL 与发给模型的正文为同一份字符串（SHALL NOT 为卡片另行取一份未形状化的全文或另切一份）；卡片结果行按既有 UI 机制显示前 200 字符折叠摘要、完整正文保留在工具调用记录里，该显示机制 SHALL NOT 被本要求禁止，其存在 SHALL 在用户文档披露。

#### Scenario: 短正文完整内联且不出现省略字样
- **WHEN** `web_fetch` 抓回 800 字符的正文（默认配置，阈值 1000×2）
- **THEN** 模型可见正文 SHALL 含全部 800 字符，且 SHALL NOT 含"省略"字样

#### Scenario: 长正文的取回入口在最后一行
- **WHEN** `web_fetch` 抓回 19,806 字符的正文（用例构造值，规模取自提案时点在真机日志观察过的被切样本）
- **THEN** 模型可见正文最后一行 SHALL 是带引用与 `read_spill` 参数的 spill 引用行；模型按该引用调用 `read_spill` SHALL 能读回头尾之外的中间段原文

#### Scenario: 引用行随请求体重放不被掐断
- **WHEN** 会话重放一轮历史 `web_fetch` 调用、其正文再次经过通用省略处理
- **THEN** 交付的 `tool_result` 正文 SHALL 仍含可辨认的 spill 引用信息（`[spill refs:` 标记被保留或被"中间的原文可用 read_spill 读回"的尾注指到）

#### Scenario: 卡片与模型拿同一份字符串
- **WHEN** 渲染一轮长正文 `web_fetch` 的结果卡片
- **THEN** 卡片内容项拿到的文本 SHALL 与发给模型的正文为同一字符串（同为预览加引用行形态）；卡片结果行的 200 字符折叠摘要按第 5 项处理——它显示的是这份字符串的开头，不另取第二份正文

