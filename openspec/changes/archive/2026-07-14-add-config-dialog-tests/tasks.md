## 1. ConfigService + AppShell DI

- [x] 1.1 `lib/services/config_service.dart`：`load()` 和 `save()` 新增可选 `String? configPath` 参数，默认值 `ConfigService.configPath`，向后兼容
- [x] 1.2 `lib/main.dart`：`AppShell` 新增可选 `ConfigResult Function()? configLoader` 参数（4-5 行：field + constructor param + `_loadConfig()` 中的调用），默认 `ConfigService.load`
- [x] 1.3 所有测试文件中添加 `tearDown(() { registry.clear(); resolver = null; })` — 清除全局 registry/resolver 状态，防止跨测试泄漏

## 2. ConfigService Unit Tests

- [x] 2.1 `test/unit/config_service_test.dart`：创建测试文件，测试 valid config.json → ConfigStatus.ok，AppConfig 正确解析（1 个 provider + 1 个 agent type）
- [x] 2.2 测试 config.json 不存在 → ConfigStatus.notFound
- [x] 2.3 测试 config.json 不是合法 JSON → ConfigStatus.malformed with error
- [x] 2.4 测试 provider entry 缺少 `api_key` 字段 → ConfigStatus.malformed（注意：缺失顶层 `providers` key 不会触发 malformed，只返回空 providers 的 ok）

## 3. AgentTypeRegistry + ProviderResolver Unit Tests

- [x] 3.1 `test/unit/agent_registry_test.dart`：创建测试文件，测试 register + lookup 正确返回
- [x] 3.2 测试 lookup 未注册 name → 返回 null
- [x] 3.3 测试 listNames → 返回所有已注册名
- [x] 3.4 测试 ProviderResolver.resolve() 正确返回 ProviderConfig；不存在返回 null（unknown provider 的验证在此层）

## 4. SetupDialog Widget Tests

- [x] 4.1 `test/widget/setup_dialog_test.dart`：创建测试文件，测试 dialog 渲染 API key TextField + "Start" 按钮（注意：按钮文字是 "Start" 不是 "Save"）
- [x] 4.2 测试空输入按 Start → dialog 不关闭（_error 显示 "Please enter an API key"）
- [x] 4.3 测试输入有效 key 按 Start → onComplete 回调触发。Save 写入通过 D1 的 configPath 参数重定向到 temp dir
- [x] 4.4 测试 barrierDismissible=false → 需通过 `showDialog()` 包装 SetupDialog 后 pump，tapAt 外部区域，验证 dialog 仍存在（或委托到 AppShell 测试 task 5.3）

## 5. AppShell Widget Tests

- [x] 5.1 `test/widget/app_shell_test.dart`：创建测试文件。注入延迟 configLoader → **第一帧** pump 后检查 CircularProgressIndicator（加载态）
- [x] 5.2 注入返回 `ConfigResult.malformed` 的 configLoader → 检查错误信息显示
- [x] 5.3 注入返回 `ConfigResult.notFound()` 的 configLoader → **第一帧** pump 后检查加载态，**第二帧** pump 后检查 SetupDialog 出现（postFrameCallback 延迟）

### 🔎 Checkpoint: 验收

| # | 验收项 | 通过标准 |
|---|--------|----------|
| A | DI 无副作用 | 不传 configPath/configLoader 时行为不变 |
| B | Unit tests 可运行 | `flutter test test/unit/` 全部通过 |
| C | Widget tests 可运行 | `flutter test test/widget/setup_dialog_test.dart test/widget/app_shell_test.dart` 全部通过 |
| D | 状态隔离 | 跨测试 registry/resolver 已 tearDown 清理 |
