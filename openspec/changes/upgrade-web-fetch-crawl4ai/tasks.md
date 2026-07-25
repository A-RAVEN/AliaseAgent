## 1. Python worker

- [ ] 1.1 Create `scripts/fetch_worker.py`: stdin/stdout JSON worker using crawl4ai `AsyncWebCrawler`, outputs `{"ok":true,"url":"...","title":"...","content":"..."}`. Include basic URL scheme validation as defense-in-depth. Configure Playwright `page.route()` interceptor to abort requests to RFC 1918 / reserved IP ranges (JS SSRF mitigation)
- [ ] 1.2 Create `scripts/requirements.txt` with `crawl4ai` dependency

## 2. C++ process management & SSRF

- [ ] 2.1 Add `python_available` static flag, detect at sidecar init via `popen("python3 --version")` / `popen("python --version")` (flag cached; restart required to detect newly installed Python)
- [ ] 2.2 Implement platform-specific subprocess launcher with stdin/stdout pipes (Windows: `CreateProcess` + `CreatePipe`; POSIX: `fork` + `exec` + `dup2`), returning a process handle/PID for timeout kill
- [ ] 2.3 Add `resolve_script_path()` function: locate `fetch_worker.py` relative to sidecar DLL location (`GetModuleFileName` on Windows, `dladdr` on Linux), with fallback to installed path (`share/aliasagent/scripts/`)
- [ ] 2.4 Add SSRF pre-spawn check: parse URL hostname → if literal IP, check blocklist directly; if domain, `getaddrinfo` resolve → check each resolved IP against existing `is_blocked_ipv4`/`is_blocked_ipv6` blocklist → reject if any match
- [ ] 2.5 Implement 30s timeout with process-tree kill: on timeout, `TerminateProcess` (Win) or `killpg(SIGKILL)` (POSIX with `setpgid`), then close handles and fall back to curl
- [ ] 2.6 In `web_fetch_impl`, branch on `python_available`: if true, run SSRF check → launch subprocess → read result; if false or subprocess fails/times out, fall through to existing curl path

## 3. Response format upgrade

- [ ] 3.1 Update C++ curl fallback path response to include `"url"` and `"title":""` fields (matching crawl4ai path format for Dart-side consistency)
- [ ] 3.2 Remove `extract_mode` from tool definition in `lib/main.dart`; tool only requires `url`
- [ ] 3.3 Remove `extract_mode` parameter from `_executeTool` case `web_fetch`

## 4. Dart UI update

- [ ] 4.1 Update `_buildResultSections` for web_fetch: use `title` field as `ResultItem.title`; fall back to URL if title is empty
- [ ] 4.2 Update `_formatSearchResultForDisplay` for web_fetch: preserve markdown formatting

## 5. Script deployment

- [ ] 5.1 Add CMake `install(FILES scripts/fetch_worker.py DESTINATION share/aliasagent/scripts)` rule for installed builds
- [ ] 5.2 Add CMake `install(FILES scripts/requirements.txt DESTINATION share/aliasagent/scripts)` rule

## 6. Build & test

- [ ] 6.1 `flutter build windows --debug` succeeds
- [ ] 6.2 `flutter test` all pass (Dart-side tests unchanged)
- [ ] 6.3 Sidecar C++ tests: verify `strip_html_tags` and curl-constant tests in `sidecar/test/search_provider_test.cpp` still pass (existing code preserved, no changes needed)
- [ ] 6.4 Manual: verify web_fetch returns clean markdown with title (when Python+crawl4ai installed)
- [ ] 6.5 Manual: verify web_fetch gracefully falls back to curl when Python is not installed
- [ ] 6.6 Manual: verify SSRF blocks `http://192.168.1.1/` (literal IP) and `http://127.0.0.1.nip.io/` (DNS rebinding) without spawning subprocess
