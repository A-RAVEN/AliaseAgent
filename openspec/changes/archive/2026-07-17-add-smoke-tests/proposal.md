## Why

当前缺少统一的自动化验证手段。每次改动后只能靠 `dart analyze` + `flutter build` + 手动启动应用来验证，效率低且容易遗漏。需要一套轻量级 smoke test 框架，利用截图 + MCP 图像分析 + 已有的 checkpoint 脚本，形成可一键运行的自动化验证流水线。

## What Changes

- 截图使用 PowerShell `CopyFromScreen`（Windows 自带，零外部依赖）
- 新增 `test/smoke/` 目录，包含一键运行脚本 `run_all.sh`
- Shell 工具函数：`launch_app`、`wait_for_window`、`capture_screenshot`、`verify_db`、`verify_logs`
- 串联现有 checkpoint 脚本到统一流程
- 截图 + MCP `ui_diff_check` 做视觉回归：对比改动前后的 UI 截图

## Capabilities

### New Capabilities
- `smoke-test-runner`: 统一测试入口，串联 build → analyze → checkpoint → launch → screenshot → verify logs → verify DB
- `visual-assertions`: 截图 + MCP 图像分析工具对比 UI 状态，验证关键界面元素（sidebar 标题、消息列表、工具卡片、错误提示）

### Modified Capabilities
（无 — 不改变现有功能需求）

## Impact

- `test/smoke/` — 新增目录，不影响现有代码
- 无应用代码变更，无 API 变更
