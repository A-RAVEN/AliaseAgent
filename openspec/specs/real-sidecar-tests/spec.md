## ADDED Requirements

### Requirement: ping FFI call returns pong
The system SHALL verify that `ping` FFI function returns "pong", confirming basic FFI bridge connectivity.

#### Scenario: ping returns pong
- **WHEN** `ping` is called via FFI
- **THEN** the function returns the string "pong"

### Requirement: set_workspace FFI call succeeds
The system SHALL verify that `set_workspace` FFI function can be called and returns a valid result.

#### Scenario: set valid workspace directory
- **WHEN** `set_workspace` is called with a valid directory path
- **THEN** the function returns without crash and the return value is a non-null string

### Requirement: read_file FFI call returns correct content
The system SHALL verify that `read_file` FFI function can read a known file and return correct content.

#### Scenario: read existing text file
- **WHEN** `read_file` is called with the path to `pubspec.yaml`
- **THEN** the return JSON contains `"ok":true` and content contains the string "alias_agent"

### Requirement: list_dir FFI call returns JSON array
The system SHALL verify that `list_dir` FFI function can list a known directory.

#### Scenario: list project test directory
- **WHEN** `list_dir` is called with the path to `test/unit/`
- **THEN** the return JSON contains `"ok":true` and content is a valid JSON array containing `sidecar_bridge_test.dart`

### Requirement: ensure_search_infra returns ok without hanging
The system SHALL verify that `ensure_search_infra("{}")` completes within 5 seconds and returns success.

#### Scenario: empty config returns ok
- **WHEN** `ensure_search_infra` is called with empty config `"{}"`
- **THEN** the function returns within 5 seconds and the response JSON contains `"ok":true`

### Requirement: get_search_providers returns valid JSON
The system SHALL verify that `get_search_providers` returns a parseable JSON array.

#### Scenario: get providers after init
- **WHEN** `get_search_providers` is called after `ensure_search_infra("{}")`
- **THEN** the function returns a valid JSON array (may be empty if no providers configured)

### Requirement: sidecar DLL loads without missing dependencies
The system SHALL verify that `DynamicLibrary.open('sidecar.dll')` succeeds.

#### Scenario: DLL loads successfully
- **WHEN** `DynamicLibrary.open` is called with the path to `sidecar.dll`
- **THEN** no `ArgumentError` is thrown, indicating all DLL dependencies are resolved, and `read_file` symbol can be looked up

### Requirement: web_fetch SSRF pre-spawn check blocks internal IPs
The system SHALL verify that `web_fetch` rejects internal/private IP addresses at the SSRF pre-spawn check stage, without making any network request.

#### Scenario: Literal private IPv4 blocked
- **WHEN** `web_fetch` is called with `{"url":"http://192.168.1.1/"}`
- **THEN** the function returns `{"ok":false}` with an error containing "internal address" or "not allowed", without spawning a subprocess or making a network request

#### Scenario: Loopback blocked
- **WHEN** `web_fetch` is called with `{"url":"http://127.0.0.1:8080/"}`
- **THEN** the function returns an SSRF error

#### Scenario: file:// scheme blocked
- **WHEN** `web_fetch` is called with `{"url":"file:///etc/passwd"}`
- **THEN** the function returns a scheme error containing "not allowed"

#### Scenario: localhost hostname blocked
- **WHEN** `web_fetch` is called with `{"url":"http://localhost/admin"}`
- **THEN** the function returns an SSRF error containing "internal address"

### Requirement: read_file requires set_workspace first
The system SHALL call `set_workspace` before `read_file` or `list_dir` in all tests, as these functions resolve paths relative to the workspace directory.

#### Scenario: read_file after set_workspace
- **WHEN** `set_workspace` is called with the project root, then `read_file` is called with `pubspec.yaml`
- **THEN** the file content is returned successfully

### Requirement: Live tests are window-based integration tests (规范形态)
文件工具 live 测试 SHALL 为**窗口版 integration_test**（`integration_test/` 目录，`IntegrationTestWidgetsFlutterBinding` + `pumpWidget(MyApp)`，在真实桌面窗口运行完整应用，可见真实 AI 回答的 UI 渲染），而不是 headless flutter_tester 套件。运行 SHALL 使用窗口版规范命令 `flutter test --tags live --run-skipped integration_test/live_file_tools_test.dart -d windows`。隔离：live 套件 SHALL **无条件**在无完整 config / API 不可用时 `markTestSkipped`（不失败、不静默运行、不 fallback 到错误默认端点）；`dart_test.yaml` 的 `tags.live.skip` 对 `flutter test integration_test/... -d windows` **已实测生效**（task 12.1 探针确认），故套件带 `live` tag 且默认跳过、显式命令触发（`--tags live --run-skipped`）。本要求仅约束本 change 新建的窗口版套件；既有 `integration_test/real_api_test.dart` 不强制改造。

> 验证基础：tag 语义已从本地 SDK 源码确认（flutter_test `widget_tester.dart:56-61` re-export `Tags`、`test_core` `loader.dart:219` config skip 仅由 `--run-skipped` 解除），对 integration_test 的适用性经 task 12.1 探针实测确认（默认跳过、`--run-skipped` 解除并运行）。

#### Scenario: Window-based live run is visible
- **WHEN** the window-based live suite is run on a desktop device
- **THEN** the full app renders in a real window and the model's streaming reply / tool cards are visible on screen

#### Scenario: Default run excludes live tests
- **WHEN** `flutter test integration_test` is run without the live flag
- **THEN** `live`-tagged tests are reported as skipped with the configured reason

#### Scenario: Missing config skips gracefully
- **WHEN** the live suite runs without a complete config (api_key, base_url, or model missing) or the API is unavailable
- **THEN** the suite skips with a clear reason rather than failing or firing calls against a wrong default endpoint

### Requirement: Live tests cover file search/edit tools end-to-end in the window
窗口版 live 套件（`integration_test/live_file_tools_test.dart`）SHALL 通过真实模型在真实应用窗口中驱动真实 sidecar，覆盖 add-file-tools 能力：`glob_file`、`grep_file`、批量 `edits` 数组形式的 `edit_file`，以及唯一匹配拒绝路径。断言 SHALL 通过 UI 状态（`ToolCallCard` 出现且 `done`、必要时捕获 `error`）+ `ToolCallActivity.input`（工具参数，如 `edits` 数组长度）+ 文件最终状态（line/comment-token 锚定，不做全局子串计数）。套件 SHALL 包含四个场景：自然多工具、批量 edits 数组、唯一匹配拒绝/自愈、glob_file 专项。

#### Scenario: Natural multi-tool completion
- **WHEN** the model is asked (in the app chat input) to find and replace all TODO comments using the file tools
- **THEN** `ToolCallCard`s for both `grep_file` and `edit_file` appear and reach `done`, and the fixture files end containing `DONE`

#### Scenario: Batch edits array is exercised live
- **WHEN** a single file contains ≥2 distinct TODO comments and the model is instructed to fix them in one `edit_file` call with all replacements in one `edits` array
- **THEN** some `ToolCallActivity` has `input['edits'].length >= 2` and reaches `done`, and the fixture files end with at least one TODO line replaced to read `// DONE` and no line beginning with `// TODO` (line-anchored, per design D4)

#### Scenario: Unique-match handling with self-correction
- **WHEN** a fixture contains two identical match targets and the model is asked to change only one without using `replace_all`
- **THEN** the countA region has a `DONE` comment token and no `TODO` token, the countB region has a `TODO` token and no `DONE` token (comment-token-anchored region assertions), an `edit_file` tool card appears, and the run reports whether a rejection (`error` card) occurred — the rejection is maximized in probability but not deterministically guaranteed

#### Scenario: glob_file invoked live
- **WHEN** the model is asked (in the app chat input) to locate files by glob pattern using `glob_file` only
- **THEN** a `glob_file` `ToolCallCard` appears and reaches `done`, and its returned paths are workspace-relative and include the expected fixture files

### Requirement: Live test output observability
窗口版 live 测试（真实模型驱动）SHALL 在**断言前及所有失败路径（等待超时 / 错误状态检测）**输出该轮**实际工具调用**（toolName / 完整 input / status / result）与涉及文件的**最终状态**（如有工具调用/文件修改；无工具调用的用例如实报告"无工具调用"），使失败可归因；不输出测试内容即规范违规。同一要求约束 `live_file_tools_test.dart`（本 change 的窗口版 live 套件，其窗口版形态与端到端覆盖需求已在本 spec 中）。

#### Scenario: Tool calls are dumped before assertions
- **WHEN** a live test reaches its assertion phase with tool calls having occurred this turn
- **THEN** the test SHALL print each `ToolCallCard`'s `toolName`, `status`, complete `input`, and a result preview BEFORE the file-state assertions run

#### Scenario: Failure paths dump before fail/skip
- **WHEN** a live test fails (wait timeout / error-status detection) before or during its assertions
- **THEN** the test SHALL print the tool-call and file-state evidence BEFORE calling `fail(...)` or `markTestSkipped(...)`, so the failure is attributable

#### Scenario: Conversation-never-completes timeout still dumps
- **WHEN** the wait-for-turn-complete helper throws its bare `TimeoutException`
- **THEN** the dump SHALL run before the exception propagates (call-site try/on with dump, then fail/rethrow)

#### Scenario: File state is dumped for file-modifying tests
- **WHEN** a live test involves `edit_file` / `write_file` and reaches its assertions
- **THEN** the test SHALL dump the affected files' final content, attributable per-file
