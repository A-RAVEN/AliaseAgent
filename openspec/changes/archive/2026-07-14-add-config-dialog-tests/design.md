## Context

`agent-config/spec.md` specifies config loading, setup dialog, provider resolution, and agent type registry behavior. Current tests register agent types manually (`registry.register(...)`) and use `const AppConfig(version: 1)` — they bypass the actual config loading and validation path entirely. Testing the real `ConfigService.load()`, `AppShell` boot flow, and `SetupDialog` requires careful test isolation from the real filesystem.

## Goals / Non-Goals

**Goals:**
- Unit test `ConfigService.load()` with temp directory files (valid JSON, missing file, malformed JSON)
- Widget test `SetupDialog`: validates input, creates config on submit
- Widget test `AppShell` boot: loading state, error display for malformed config, setup dialog trigger when no config exists
- Unit test `AgentTypeRegistry` and `ProviderResolver` edge cases (including unknown provider resolution)

**Non-Goals:**
- Not testing the actual `config.json` file I/O (unit tests use temp directory files with injected configPath)
- Not testing `ConfigService.save()` in isolation (setup dialog handles creation via injected savePath)
- Not testing provider API key encryption/decryption

## Decisions

### D1: ConfigService unit tests use temp directory via configPath parameter

Add optional `String? configPath` parameters to `ConfigService.load()` and `save()` — each defaults to the real path, so existing callers are unaffected. Tests inject a temp path:

```dart
// Production code change (backward-compatible):
static ConfigResult load({String? configPath}) {
  final file = File(configPath ?? ConfigService.configPath);
  // ...
}

// Test usage:
setUp(() {
  tempDir = Directory.systemTemp.createTempSync('config_test_');
  testConfigPath = '${tempDir.path}/config.json';
  File(testConfigPath).writeAsStringSync(validJson);
});
tearDown(() => tempDir.deleteSync(recursive: true));

final result = ConfigService.load(configPath: testConfigPath);
```

**选择**: Optional parameter injection. Minimal production change (2 parameters, backward-compatible). Follows the same DI philosophy as AppShell's configLoader.

### D2: SetupDialog tests via pump + tap

Pump `SetupDialog` in a MaterialApp, enter text, tap "Start":

```dart
await tester.enterText(find.byType(TextField), 'sk-ant-api-...');
await tester.tap(find.text('Start'));
// Verify onComplete was called
```

**选择**: Standard widget test pattern. SetupDialog is self-contained for input validation. Note: `SetupDialog._submit()` calls `ConfigService.save()` — with the D1 configPath parameter, tests inject a temp save path via `ConfigService.save(configPath: tempConfigPath)` to avoid polluting the real config directory. The barrierDismissible test (task 4.4) requires pumping via `showDialog()` (not direct widget pump), or is tested at the AppShell level where `showDialog` is already used.

### D3: AppShell boot states via injected config loader

`AppShell` currently calls `ConfigService.load()` synchronously in `_loadConfig()`. To test error/loading states, add an optional `ConfigResult Function()?` configLoader parameter:

```dart
class AppShell extends StatefulWidget {
  final ConfigResult Function()? configLoader;
  const AppShell({super.key, this.configLoader});
  // ...
}
```

Test injection pattern (produces malformed/notFound states for testing):
```dart
// Malformed config test
await tester.pumpWidget(MaterialApp(
  home: AppShell(configLoader: () => ConfigResult.malformed('bad json')),
));
```

**Important timing note**: `_showSetup()` in `_loadConfig()` uses `WidgetsBinding.instance.addPostFrameCallback`, so the SetupDialog only appears after the **second** `pump()` call. Tests for loading spinner (task 5.1) should assert the spinner on frame 0. Tests for setup dialog (task 5.3) must pump twice.

**选择**: Function injection (sync `ConfigResult Function()`). Unlike ChatScreen which injects class instances, AppShell injects a factory function. The default value `ConfigService.load` works directly because the return type is `ConfigResult` (not `Future`). This is ~4-5 lines of production change (field, constructor param, updated `_loadConfig()` call).

## Risks / Trade-offs

- [R] ConfigService tests touch real filesystem → Mitigation: D1 adds `configPath` parameter to `load()`/`save()`, tests use temp dirs with setUp/tearDown cleanup
- [R] AppShell DI needs production code change → 4-5 lines: field + constructor param + updated `_loadConfig()`, backward compatible via default value
- [R] SetupDialog._submit() calls ConfigService.save() static → Mitigation: D1 configPath parameter redirects to temp dir during tests
- [R] Global `registry` and `resolver` state leaks across tests → Mitigation: all test files that pump AppShell must add `tearDown(() { registry.clear(); resolver = null; })`
- [R] SetupDialog barrierDismissible test needs overlay → Mitigation: task 4.4 tests via `showDialog()` wrapper (two-pump pattern) or delegates to AppShell-level test (task 5.3)
- [R] `_showSetup()` uses `addPostFrameCallback` → Tests need double-pump: first pump renders the frame, second pump fires the post-frame callback and renders the dialog. Documented in tasks 5.1/5.3.
