## 1. Real Sidecar FFI Tests — `test/unit/sidecar_bridge_test.dart`

- [ ] 1.1 DLL load test: verify `DynamicLibrary.open('sidecar.dll')` succeeds and `read_file` symbol resolves
- [ ] 1.2 `set_workspace` test: call with project root path, verify returns non-null string without crash
- [ ] 1.3 `read_file` test: read `pubspec.yaml`, verify JSON response contains `"ok":true` and file content
- [ ] 1.4 `list_dir` test: list `test/unit/` directory, verify JSON response contains `"ok":true` and `sidecar_bridge_test.dart` in the array
- [ ] 1.5 `ensure_search_infra("{}")` test: call with empty config, verify returns `{"ok":true}` within 5 seconds (no hang)
- [ ] 1.6 `get_search_providers` test: call after `ensure_search_infra`, verify returns valid JSON array

## 2. Real Sidecar FFI Tests — `test/integration/real_sidecar_test.dart`

- [ ] 2.1 `read_file` integration: read a real file, verify content matches expected
- [ ] 2.2 `list_dir` integration: list real directories with files and subdirectories, verify format
- [ ] 2.3 Tool execution: verify `read_file` + `list_dir` work in sequence without state corruption

## 3. Smoke Test Fix — `test/smoke/04_launch_and_verify.sh`

- [ ] 3.1 Fix `launch_app` in `utils.sh`: ensure it finds `build/windows/x64/runner/Debug/alias_agent.exe` and returns PID
- [ ] 3.2 Fix `wait_for_window`: use `powershell -Command "Get-Process alias_agent"` for window detection
- [ ] 3.3 Fix `verify_logs`: check `%USERPROFILE%\.aliasagent\logs\sidecar.log` for `[ERROR]` lines
- [ ] 3.4 Fix `verify_db`: check `%USERPROFILE%\.aliasagent\aliasagent.db` exists and has tables
- [ ] 3.5 Fix `capture_screenshot` in `utils.sh`: use PowerShell `CopyFromScreen` for screenshot capture
- [ ] 3.6 Run `04_launch_and_verify.sh` end-to-end and confirm exit code 0

## 4. Run.bat Integration

- [ ] 4.1 Update `run.bat` step 3 smoke test to run the new real sidecar tests via `flutter test test/unit/sidecar_bridge_test.dart`
- [ ] 4.2 Verify `run.bat` works end-to-end: build → smoke test pass → app launches → no red screen
