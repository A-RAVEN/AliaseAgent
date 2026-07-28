## Why

所有现有测试用 FakeSidecar 模拟 FFI 调用，导致三类致命 bug 漏网：sidecar DLL 依赖缺失（libcurl/zlib 未拷贝）、`ensure_search_infra` 无限递归栈溢出、工具定义未发送给 AI 模型。需要一层真实 DLL 集成测试作为自动化防线，在每次构建后验证基本功能不被破坏。

此外，web_fetch 升级为 crawl4ai subprocess 架构后，引入了新的运行时依赖链（Python → crawl4ai → Chromium → fetch_worker.py）和 OS 级故障面（pipe 死锁、进程超时、SSRF 前置检查），这些是 mock 测试完全无法覆盖的。

## What Changes

- 新增真实 sidecar DLL 集成测试，覆盖所有离线可测的 `extern "C"` FFI 函数（ping、set_workspace、read_file、list_dir、ensure_search_infra、get_search_providers）
- 新增 web_fetch subprocess 路径的离线可测面：SSRF 前置检查（字面 IP 拦截）、Python 检测逻辑
- 修复 `test/smoke/` 框架使其可实际运行，验证应用启动不红屏
- 所有新测试使用真实 `sidecar.dll`，不使用 FakeSidecar 或 MockServer

## Capabilities

### New Capabilities
- `real-sidecar-tests`: 使用真实 sidecar.dll 的 Dart 集成测试，覆盖 ping、set_workspace、read_file、list_dir、ensure_search_infra、get_search_providers 的 FFI 调用路径，以及 web_fetch SSRF 前置检查

### Modified Capabilities
- `smoke-test-runner`: 修复 `test/smoke/04_launch_and_verify.sh` 使其实际上可运行——启动应用验证窗口出现、进程存活、日志无错误、数据库可访问

## Impact

- `test/unit/sidecar_bridge_test.dart` — 扩展现有 DLL 加载测试，新增 ping/set_workspace/read_file/list_dir
- `test/integration/real_sidecar_test.dart` — 新增，真实 FFI 调用集成测试
- `test/smoke/04_launch_and_verify.sh` — 验证可通过（脚本已实现）
- `run.bat` — 已集成 smoke test 步骤
