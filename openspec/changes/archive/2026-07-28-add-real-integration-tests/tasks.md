## 1. Real Sidecar FFI Tests — `test/unit/sidecar_bridge_test.dart`

- [x] 1.1 DLL load test: verify `DynamicLibrary.open('sidecar.dll')` succeeds（已有，需补 symbol resolve 断言）
- [x] 1.2 `ping` test: call ping(), verify returns "pong"
- [x] 1.3 `set_workspace` test: call with project root path, verify returns non-null string without crash
- [x] 1.4 `read_file` test: **先调 set_workspace**，再读 `pubspec.yaml`，verify JSON response contains `"ok":true` and file content
- [x] 1.5 `list_dir` test: **先调 set_workspace**，再列 `test/unit/` 目录，verify JSON response contains `"ok":true` and `sidecar_bridge_test.dart` in the array
- [x] 1.6 `ensure_search_infra("{}")` test: call with empty config, verify returns `{"ok":true}` within 5 seconds (no hang)（已有）
- [x] 1.7 `get_search_providers` test: call after `ensure_search_infra`, verify returns valid JSON array（已有）

## 2. Web Fetch SSRF 前置检查测试

- [x] 2.1 `web_fetch` SSRF literal IPv4: call web_fetch with `{"url":"http://192.168.1.1/"}`, verify returns `{"ok":false}` with "internal address" error（不需要网络，SSRF 检查在发请求前拒绝）
- [x] 2.2 `web_fetch` SSRF loopback: call web_fetch with `{"url":"http://127.0.0.1:8080/"}`, verify returns SSRF error
- [x] 2.3 `web_fetch` SSRF file scheme: call web_fetch with `{"url":"file:///etc/passwd"}`, verify returns scheme error
- [x] 2.4 `web_fetch` SSRF localhost: call web_fetch with `{"url":"http://localhost/admin"}`, verify returns SSRF error

## 3. Real Sidecar Integration Tests — `test/integration/real_sidecar_test.dart`

- [x] 3.1 `read_file` integration: read a real file, verify content matches expected
- [x] 3.2 `list_dir` integration: list real directories with files and subdirectories, verify format
- [x] 3.3 Tool execution sequence: verify set_workspace → read_file → list_dir work in sequence without state corruption

## 4. Smoke Test 验证

- [x] 4.1 `launch_app` in `utils.sh`: 已实现（找 exe 路径、返回 PID）
- [x] 4.2 `wait_for_window`: 已实现（PowerShell Get-Process + MainWindowTitle）
- [x] 4.3 `verify_logs`: 已实现（grep ERROR）
- [x] 4.4 `verify_db`: 已实现（sqlite3 检查 sessions/messages 表）
- [x] 4.5 `capture_screenshot`: 已实现（PowerShell CopyFromScreen）
- [x] 4.6 Run `04_launch_and_verify.sh` end-to-end and confirm exit code 0

## 5. Run.bat Integration

- [x] 5.1 `run.bat` step 3 已运行 `flutter test test\unit\sidecar_bridge_test.dart`
- [x] 5.2 Verify `run.bat` works end-to-end: build → test pass → app launches → no red screen
