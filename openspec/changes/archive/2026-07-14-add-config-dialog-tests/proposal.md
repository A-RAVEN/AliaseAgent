## Why

The agent config, provider, and setup dialog flows are specified in `agent-config/spec.md` but have almost zero automated test coverage. The current test infrastructure (Fake repos, FakeSidecar, widget/integration test patterns) can exercise these flows: first-launch setup dialog, config validation errors, provider resolution failures, and agent type registry edge cases. Adding these tests prevents regressions in the config boot path.

## What Changes

- **Production code**: Add DI parameters to `ConfigService` (`configPath` optional param on `load()`/`save()`) and `AppShell` (`configLoader` optional param)
- Add widget tests for `SetupDialog`: renders, validates API key, creates config on submit
- Add widget tests for `AppShell`: displays config error for malformed JSON, shows loading spinner, triggers setup dialog when no config exists
- Add unit tests for `ConfigService`: valid config, missing file, malformed JSON, missing provider
- Add unit tests for `AgentTypeRegistry` and `ProviderResolver`: lookup, registration, missing name, missing provider

## Capabilities

### New Capabilities
- `config-service-tests`: Unit tests for ConfigService.load() covering valid/missing/malformed config, and provider + agent type edge cases
- `setup-dialog-tests`: Widget tests for SetupDialog rendering, input validation, and config creation flow
- `app-shell-tests`: Widget tests for AppShell boot states (loading, error display, setup trigger)

### Modified Capabilities
<!-- None — pure test addition -->

## Impact

- `lib/services/config_service.dart` — add optional `configPath` param to `load()` and `save()`
- `lib/main.dart` — AppShell add optional `configLoader` param (4-5 lines)
- `test/unit/config_service_test.dart` — new file
- `test/unit/agent_registry_test.dart` — new file
- `test/widget/setup_dialog_test.dart` — new file
- `test/widget/app_shell_test.dart` — new file
- Minimal, backward-compatible production changes
