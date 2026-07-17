# Web Fetch — Spec

## ADDED Requirements

### Requirement: Web fetch tool definition
The system SHALL expose a `web_fetch` tool to the main model. The tool SHALL accept `url` (required) and `extract_mode` (optional, default `"text"`). v1 only supports `"text"` mode. `"markdown"` is deferred to a future change.

#### Scenario: Main model invokes web_fetch
- **WHEN** the main model calls `web_fetch` with `{"url": "https://example.com/article", "extract_mode": "text"}`
- **THEN** the Sidecar fetches the page, extracts text, and returns `{"ok":true,"content":"<extracted text>"}`

#### Scenario: Default extract mode
- **WHEN** the main model calls `web_fetch` with only `{"url": "https://example.com"}`
- **THEN** `extract_mode` defaults to `"text"`

### Requirement: SSRF protection — socket-level validation
The `web_fetch` tool SHALL validate connection targets at the socket level via `CURLOPT_OPENSOCKETFUNCTION` callback, which fires after DNS resolution but before `connect()`. This supersedes URL-string-level checks which are vulnerable to IPv6 variants, DNS rebinding, and redirect bypass. Scheme validation SHALL be case-insensitive. The tool SHALL follow HTTP redirects (`CURLOPT_FOLLOWLOCATION=1`, max 5 hops), re-validating each redirect target through the socket callback.

#### Scenario: HTTPS URL allowed
- **WHEN** `web_fetch` is called with `https://docs.flutter.dev/get-started`
- **THEN** the fetch proceeds normally; socket callback validates the resolved IP is public

#### Scenario: file:// scheme blocked
- **WHEN** `web_fetch` is called with `file:///etc/passwd`
- **THEN** the tool returns `{"ok":false,"error":"Fetch failed: URL scheme not allowed"}`

#### Scenario: Localhost hostname blocked
- **WHEN** `web_fetch` is called with `http://localhost:8080/admin`
- **THEN** the tool returns `{"ok":false,"error":"Fetch failed: internal address not allowed"}`

#### Scenario: IPv4 loopback blocked at socket level
- **WHEN** `web_fetch` is called with `http://127.0.0.1:6379/`
- **THEN** the `CURLOPT_OPENSOCKETFUNCTION` callback detects `127.0.0.1` in the blocklist and returns `CURL_SOCKOPT_ALREADY_CONNECTED`; fetch fails with internal address error

#### Scenario: IPv6 loopback blocked at socket level
- **WHEN** `web_fetch` is called with `http://[::1]:8080/admin`
- **THEN** the socket callback detects `::1` in the IPv6 blocklist and blocks the connection

#### Scenario: IPv6 link-local blocked
- **WHEN** `web_fetch` is called with `http://[fe80::1]:8080/`
- **THEN** the socket callback detects `fe80::/10` match and blocks the connection

#### Scenario: Private IPv4 blocked at socket level
- **WHEN** `web_fetch` is called with `http://192.168.1.1/admin` or `http://10.0.0.1/`
- **THEN** the socket callback blocks the connection; the tool returns `{"ok":false,"error":"Fetch failed: internal address not allowed"}`

#### Scenario: Cloud metadata endpoint blocked
- **WHEN** `web_fetch` is called with `http://169.254.169.254/latest/meta-data/`
- **THEN** the socket callback blocks the connection; the tool returns `{"ok":false,"error":"Fetch failed: internal address not allowed"}`

#### Scenario: CURLOPT_PROTOCOLS enforced
- **WHEN** the libcurl handle is configured
- **THEN** `CURLOPT_PROTOCOLS` is set to `CURLPROTO_HTTP | CURLPROTO_HTTPS` with no other protocols

#### Scenario: Case-insensitive scheme validation
- **WHEN** `web_fetch` is called with `HTTP://169.254.169.254/` (uppercase scheme)
- **THEN** the scheme is lowercased before comparison; `http:` matches; the socket callback subsequently blocks the internal IP

#### Scenario: DNS rebinding mitigated by socket callback
- **WHEN** `web_fetch` is called with `http://127.0.0.1.nip.io:6379/`
- **THEN** DNS resolves to `127.0.0.1`; the socket callback catches the resolved IP in the blocklist and blocks the connection

#### Scenario: HTTP redirect target re-validated
- **WHEN** `web_fetch` is called with `https://evil.com/redirect` that returns HTTP 301 to `http://169.254.169.254/`
- **THEN** curl follows the redirect; `CURLOPT_OPENSOCKETFUNCTION` fires again for the new target; the internal IP is detected and blocked

#### Scenario: Redirect protocol switch blocked
- **WHEN** an HTTP redirect attempts to switch protocols (e.g., HTTPS → FTP)
- **THEN** `CURLOPT_REDIR_PROTOCOLS_STR="http,https"` prevents the redirect

#### Scenario: IPv4 blocklist completeness
- **WHEN** the socket callback validates a resolved IP
- **THEN** the following ranges SHALL be blocked: `127.0.0.0/8`, `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `169.254.0.0/16`, `0.0.0.0/8`, `100.64.0.0/10`

#### Scenario: IPv6 blocklist completeness
- **WHEN** the socket callback validates a resolved IPv6 address
- **THEN** the following ranges SHALL be blocked: `::1/128`, `fe80::/10`, `fc00::/7`

### Requirement: Incremental size limit in write callback
The curl write callback (`CURLOPT_WRITEFUNCTION`) SHALL enforce a 100KB cumulative size limit incrementally. After each write, if `accumulated_size + chunk_size > 100KB`, the callback SHALL return 0 to abort the transfer immediately. This prevents zip bomb and infinite chunked response attacks from exhausting memory before post-processing truncation.

#### Scenario: Normal content under limit
- **WHEN** a page returns 50KB of text
- **THEN** the write callback accumulates all data normally; tag stripping is applied

#### Scenario: Oversized content aborted early
- **WHEN** a page has already delivered 100KB and more data arrives
- **THEN** the write callback returns 0; curl stops the transfer; the accumulated 100KB is processed normally

### Requirement: HTTP redirect behavior
The HTTP request SHALL follow redirects (`CURLOPT_FOLLOWLOCATION=1`, `CURLOPT_MAXREDIRS=5`). Each redirect target SHALL be re-validated by the `CURLOPT_OPENSOCKETFUNCTION` callback. `CURLOPT_REDIR_PROTOCOLS_STR` SHALL be set to `"http,https"` to prevent protocol-switch attacks.

#### Scenario: Redirect followed with re-validation
- **WHEN** a URL returns HTTP 301 to another public URL
- **THEN** curl follows the redirect; the socket callback validates the new target; the page is fetched

#### Scenario: Redirect to internal IP blocked
- **WHEN** an external URL redirects to `http://192.168.1.1/`
- **THEN** the socket callback blocks the redirect target; the tool returns `{"ok":false,"error":"Fetch failed: redirect to internal address not allowed"}`

### Requirement: Content-Type based extraction
The extraction strategy SHALL depend on the response Content-Type. HTML content (`text/html`) SHALL be stripped of tags. Non-HTML content SHALL be returned as raw text without tag stripping.

#### Scenario: HTML page extracted to text
- **WHEN** a page with `Content-Type: text/html` containing `<html><body><p>Hello world</p><script>alert(1)</script></body></html>` is fetched
- **THEN** the returned content is `"Hello world"` (tags stripped, script removed)

#### Scenario: JSON response returned raw
- **WHEN** a response has `Content-Type: application/json` with body `{"key": "value"}`
- **THEN** the raw body is returned untransformed (subject to 100KB truncation)

#### Scenario: Plain text returned as-is
- **WHEN** a response has `Content-Type: text/plain`
- **THEN** the raw body is returned without tag stripping

### Requirement: Fetch timeout and error handling
The HTTP request SHALL have a 15-second timeout. Unreachable hosts, TLS errors, and HTTP 4xx/5xx SHALL return structured error results.

#### Scenario: Connection timeout
- **WHEN** the target host does not respond within 15 seconds
- **THEN** the tool returns `{"ok":false,"error":"Fetch failed: timeout"}`

#### Scenario: HTTP error response
- **WHEN** the server returns HTTP 404 or 500
- **THEN** the tool returns `{"ok":false,"error":"Fetch failed: HTTP <code>"}`

### Requirement: Web fetch execution on worker isolate
The `web_fetch` FFI call SHALL execute on a Dart worker isolate, NOT the main UI isolate. The pattern SHALL follow the existing `sendMessage` isolate model.

#### Scenario: Web fetch does not block UI
- **WHEN** `web_fetch` is executing for 10+ seconds
- **THEN** the Flutter UI remains responsive
