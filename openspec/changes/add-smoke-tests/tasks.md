## 1. 基础设施

- [ ] 1.1 下载 nircmd.exe：从 https://www.nirsoft.net/utils/nircmd.html 下载 64-bit 版本，放置到 `tools/nircmd.exe`
- [ ] 1.2 创建目录结构：`test/smoke/` + `test/smoke/references/` + `test/smoke/output/`，`.gitignore` 中忽略 `output/`
- [ ] 1.3 创建 `test/smoke/utils.sh`：`check_deps()`（验证 flutter/dart/nircmd/sqlite3 在 PATH）、`launch_app()`、`kill_app()`、`wait_for_window()`、`capture_screenshot()`、`verify_logs()`、`verify_db()`

## 2. 验证步骤脚本

- [ ] 2.1 创建 `test/smoke/01_build.sh`：调用 `flutter build windows --debug`
- [ ] 2.2 创建 `test/smoke/02_analyze.sh`：调用 `dart analyze lib/`
- [ ] 2.3 创建 `test/smoke/03_checkpoints.sh`：遍历 `test/checkpoint_*_verify.dart` 逐个 `dart run`
- [ ] 2.4 创建 `test/smoke/04_launch_and_verify.sh`：启动 app → 等待窗口 → 截图 → 检查日志 → 检查 DB → kill

## 3. 统一入口

- [ ] 3.1 创建 `test/smoke/run_all.sh`：串行调用 01-04 脚本，汇总 pass/fail，输出最终报告

## 4. 参考截图

- [ ] 4.1 在已知 good state 下截取 `empty_state.png`（空会话列表 + "No messages yet"）
- [ ] 4.2 在已知 good state 下截取 `auto_title.png`（sidebar 显示非默认标题）
- [ ] 4.3 在已知 good state 下截取 `tool_card.png`（消息列表中有工具调用卡片）
- [ ] 4.4 在已知 good state 下截取 `error.png`（消息列表中有错误提示气泡）

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
| H | 依赖检查有效 | 缺 nircmd 时 check_deps 报错并阻止后续步骤 |
| I | 工具卡片截图可用 | `capture_screenshot` + 有 tool call 的会话产出有效 PNG |
| J | 错误截图可用 | `capture_screenshot` + 触发 API 错误后产出有效 PNG |
