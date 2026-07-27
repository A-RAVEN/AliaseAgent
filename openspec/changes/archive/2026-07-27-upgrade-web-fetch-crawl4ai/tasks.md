## 1. Python worker

- [x] 1.1 Create `scripts/fetch_worker.py`: stdin/stdout JSON worker using crawl4ai `AsyncWebCrawler`, outputs `{"ok":true,"url":"...","title":"...","content":"..."}`. Include basic URL scheme validation as defense-in-depth. Configure Playwright `page.route()` interceptor to abort requests to RFC 1918 / reserved IP ranges (JS SSRF mitigation)
- [x] 1.2 Create `scripts/requirements.txt` with `crawl4ai` dependency

## 2. C++ process management & SSRF

- [x] 2.1 Add `python_available` static flag, detect at sidecar init via `popen("python3 --version")` / `popen("python --version")` (flag cached; restart required to detect newly installed Python)
- [x] 2.2 Implement platform-specific subprocess launcher with stdin/stdout pipes (Windows: `CreateProcess` + `CreatePipe`; POSIX: `fork` + `exec` + `dup2`), returning a process handle/PID for timeout kill
- [x] 2.3 Add `resolve_script_path()` function: locate `fetch_worker.py` relative to sidecar DLL location (`GetModuleFileName` on Windows, `dladdr` on Linux), with fallback to installed path (`share/aliasagent/scripts/`)
- [x] 2.4 Add SSRF pre-spawn check: parse URL hostname → if literal IP, check blocklist directly; if domain, `getaddrinfo` resolve → check each resolved IP against existing `is_blocked_ipv4`/`is_blocked_ipv6` blocklist → reject if any match
- [x] 2.5 Implement 30s timeout with process-tree kill: on timeout, `TerminateProcess` (Win) or `killpg(SIGKILL)` (POSIX with `setpgid`), then close handles and fall back to curl
- [x] 2.6 In `web_fetch_impl`, branch on `python_available`: if true, run SSRF check → launch subprocess → read result; if false or subprocess fails/times out, fall through to existing curl path

## 3. Response format upgrade

- [x] 3.1 Update C++ curl fallback path response to include `"url"` and `"title":""` fields (matching crawl4ai path format for Dart-side consistency)
- [x] 3.2 Remove `extract_mode` from tool definition in `lib/main.dart`; tool only requires `url`
- [x] 3.3 Remove `extract_mode` parameter from `_executeTool` case `web_fetch`

## 4. Dart UI update

- [x] 4.1 Update `_buildResultSections` for web_fetch: use `title` field as `ResultItem.title`; fall back to URL if title is empty
- [x] 4.2 Update `_formatSearchResultForDisplay` for web_fetch: preserve markdown formatting

## 5. Script deployment

- [x] 5.1 Add CMake `install(FILES scripts/fetch_worker.py DESTINATION share/aliasagent/scripts)` rule for installed builds
- [x] 5.2 Add CMake `install(FILES scripts/requirements.txt DESTINATION share/aliasagent/scripts)` rule

## 6. Build & test

- [x] 6.1 `flutter build windows --debug` succeeds
- [x] 6.2 `flutter test` all pass (Dart-side tests unchanged)
- [x] 6.3 Sidecar C++ tests: verify `strip_html_tags` and curl-constant tests in `sidecar/test/search_provider_test.cpp` still pass (existing code preserved, no changes needed)
- [ ] 6.4 Manual: verify web_fetch returns clean markdown with title (when Python+crawl4ai installed)
- [ ] 6.5 Manual: verify web_fetch gracefully falls back to curl when Python is not installed
- [ ] 6.6 Manual: verify SSRF blocks `http://192.168.1.1/` (literal IP) and `http://127.0.0.1.nip.io/` (DNS rebinding) without spawning subprocess

## 7. Hotfix — bilibili 测试发现的问题

- [x] 7.1 Fix `fetch_worker.py`: `ensure_ascii=False` → `ensure_ascii=True`（line 65，覆盖 success 和 error 两条路径的共享 print）
- [x] 7.2 Remove 100KB cap: 删除 `FetchWriteCtx::MAX_RESPONSE_SIZE` 常量（web_fetch.h）和 write callback 中的累积检查（web_fetch.cpp），添加 `CURLOPT_MAXFILESIZE`（10MB）作为替代防护，更新 web_fetch.h/cpp 中描述 cap 的 stale 注释
- [x] 7.3 Update `search_provider_test.cpp`: 将 "write callback caps at 100KB" TEST_CASE（lines 559-577）改为验证无 cap 行为（正常追加、返回 total）（需用户授权修改测试）
- [x] 7.4 Capture subprocess stderr: 创建 stderr pipe（含正确的 handle 管理：父进程关 write end、读端 non-blocking），成功时 LOG_DEBUG、失败/超时时 LOG_WARN，截断到 4KB
- [x] 7.5 Rebuild + test: `flutter build windows --debug`, `flutter test`, sidecar_tests 全部通过
- [x] 7.6 Manual: re-test bilibili URL（crawl4ai 路径）— verify returns markdown with title
- [ ] 7.7 Manual: test curl fallback with >100KB page（禁用 Python 或 crawl4ai 不可用时）— verify 不再报 CURLE_WRITE_ERROR

## 8. 修复 Windows pipe 死锁（stdout + stderr）

- [x] 8.1 Increase `CreatePipe` buffer: stdin/stdout/stderr 三个管道的 `nSize` 参数从 0（默认 4KB）改为 `1024*1024`（1MB）
- [x] 8.2 Rewrite Windows read loop: `PeekNamedPipe` 同时轮询 hStdOutRd 和 hStdErrRd + `WaitForSingleObject(100ms)` 交替循环。进程退出/超时后做最终 drain（两个管道都 PeekNamedPipe+ReadFile 直到 avail==0），保留 30s 总超时
- [x] 8.3 POSIX 加固: 将 pipe_stderr[0] 加入 `select()` 的 fd_set，并发读 stderr
- [x] 8.4 Rebuild + self-test: 编译通过后，用 C++ sidecar_tests 或直接运行 app 验证 bilibili（>4KB stdout + >4KB stderr）不死锁。注意：Python subprocess.communicate() 不能复现此死锁（它内部用线程并发读），不能用它做验证
- [x] 8.5 Manual: app 内测试 bilibili — verify crawl4ai 路径成功返回 markdown with title
