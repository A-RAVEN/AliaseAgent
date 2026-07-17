## 1. 基础设施

- [x] 1.1 创建目录结构：`test/smoke/` + `test/smoke/references/` + `test/smoke/output/`，`.gitignore` 中忽略 `output/`
- [x] 1.2 创建 `test/smoke/utils.sh`：`check_deps()`（验证 flutter/dart/powershell/sqlite3 在 PATH）、`launch_app()`、`kill_app()`、`wait_for_window()`、`capture_screenshot()`（PowerShell CopyFromScreen）、`verify_logs()`、`verify_db()`

## 2. 验证步骤脚本

- [x] 2.1 创建 `test/smoke/01_build.sh`：调用 `flutter build windows --debug`
- [x] 2.2 创建 `test/smoke/02_analyze.sh`：调用 `dart analyze lib/`
- [x] 2.3 创建 `test/smoke/03_checkpoints.sh`：遍历 `test/checkpoint_*_verify.dart` 逐个 `dart run`
- [x] 2.4 创建 `test/smoke/04_launch_and_verify.sh`：启动 app → 等待窗口 → 截图 → 检查日志 → 检查 DB → kill

## 3. 统一入口

- [x] 3.1 创建 `test/smoke/run_all.sh`：串行调用 01-04 脚本，汇总 pass/fail，输出最终报告

## 4. 参考截图

- [x] ~~4.1~~ superseded by `add-integration-visual-tests` (automated visual regression pipeline)
- [x] ~~4.2~~ superseded by `add-integration-visual-tests`
- [x] ~~4.3~~ superseded by `add-integration-visual-tests`
- [x] ~~4.4~~ superseded by `add-integration-visual-tests`

### 🔎 Checkpoint: 验收

| # | 验收项 | 通过标准 |
|---|--------|----------|
| A | 一键运行 | `bash test/smoke/run_all.sh` 完整执行所有步骤 |
| B | 编译验证有效 | 代码有编译错误时 step 1 报告失败 |
| C | 分析验证有效 | 代码有 warning 时 step 2 报告失败 |
| D | 检查点有效 | 所有 checkpoint_X_verify.dart 通过 |
| E | 截图可用 | `capture_screenshot empty_state` 产出非零 PNG |
| F | 日志检查有效 | sidecar.log 有 ERROR 时 step 4 报告失败 |
| G | DB 检查有效 | DB 缺失表时 step 4 报告失败 |
| H | 依赖检查有效 | 缺 powershell 时 check_deps 报错并阻止后续步骤 |
| I | 工具卡片截图可用 | `capture_screenshot` + 有 tool call 的会话产出有效 PNG |
| J | 错误截图可用 | `capture_screenshot` + 触发 API 错误后产出有效 PNG |
