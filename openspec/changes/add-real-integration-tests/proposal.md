## Why

所有现有测试用 FakeSidecar 模拟 FFI 调用，导致三类致命 bug 漏网：sidecar DLL 依赖缺失（libcurl/zlib 未拷贝）、`ensure_search_infra` 无限递归栈溢出、工具定义未发送给 AI 模型。需要一层真实 DLL 集成测试作为自动化防线，在每次构建后验证基本功能不被破坏。

## What Changes

- 新增真实 sidecar DLL 集成测试，覆盖所有 `extern "C"` FFI 函数的调用路径
- 修复 `test/smoke/` 框架使其可实际运行，验证应用启动不红屏
- 所有新测试使用真实 `sidecar.dll`，不使用 FakeSidecar 或 MockServer
- 将 DLL 依赖检测从 smoke test 提升为独立验证步骤

## Capabilities

### New Capabilities
- `real-sidecar-tests`: 使用真实 sidecar.dll 的 Dart 集成测试，覆盖 set_workspace、read_file、list_dir、ensure_search_infra、get_search_providers、web_search、web_fetch 的 FFI 调用路径

### Modified Capabilities
- `smoke-test-runner`: 修复 `test/smoke/04_launch_and_verify.sh` 使其实际上可运行——启动应用验证窗口出现、进程存活、日志无错误、数据库可访问

## Impact

- `test/unit/sidecar_bridge_test.dart` — 扩展现有 DLL 加载测试
- `test/integration/real_sidecar_test.dart` — 新增，真实 FFI 调用测试
- `test/smoke/04_launch_and_verify.sh` — 修复并验证可通过
- `test/smoke/utils.sh` — 可能需要修复辅助函数
- `run.bat` — 确保 smoke test 集成到构建流程（已有步骤 3/4）
