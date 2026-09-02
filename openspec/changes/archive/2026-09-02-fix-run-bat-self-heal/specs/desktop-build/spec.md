# Desktop Build — Spec

## ADDED Requirements

### Requirement: Build failure self-heal
When `run.bat` triggers a `flutter build windows --debug` that fails, the launcher SHALL clean the stale native-assets incremental build cache under `.dart_tool\flutter_build` AND the native-assets hook cache under `.dart_tool\hooks_runner` (which holds the persisted `output.json` manifest that re-points at a removed native asset), then retry once before giving up, so a transient cache-driven failure recovers without requiring the user to run `flutter clean` manually. The self-heal SHALL NOT run a full `flutter clean` and SHALL NOT delete the `build\` output — the incremental compile artifacts remain, so the retry is an incremental rebuild. Clearing the hook cache forces the native-assets hook to re-download the sqlite3 native asset into a fresh per-process random-hash directory (the previously-downloaded native assets under `.dart_tool\hooks_runner` are discarded; this re-download is inherent churn). Recovery presupposes network access to re-download the sqlite3 native asset; when offline, the retry fails at the asset download and is surfaced as a network cause rather than recovering.

Note: `run.bat` SHALL abort on any critical command (cache clear, `flutter pub get`, sidecar/dependency copy, smoke test) failing with a non-zero code rather than silently continuing. The Flutter build is NOT an abort-on-failure command: its first failure SHALL trigger the self-heal (clear caches + retry) and a retry failure SHALL surface+classify (see the Build-failure-self-heal and Real-build-error-surfaced requirements), rather than a bare stop.

#### Scenario: Transient cache failure recovers
- **WHEN** the first Flutter build fails because the incremental cache references an already-removed native-asset source file
- **THEN** `run.bat` clears the `.dart_tool\flutter_build` incremental cache and the `.dart_tool\hooks_runner` native-assets hook cache, runs `flutter pub get`, retries the build, and the retried build succeeds — this recovery presupposes network access to re-download the sqlite3 native asset; if offline, the retry fails at the download step and is classified as a network cause (see the Retry-still-fails and Network-cause-classified scenarios)

#### Scenario: Targeted clear preserves build output
- **WHEN** the self-heal clears the incremental build cache and the native-assets hook cache
- **THEN** the `build\` output is not deleted, a full `flutter clean` is not executed, and the native-assets hook cache is rebuilt by re-downloading the sqlite3 native asset on the retry (the `download-*` directories under `.dart_tool\hooks_runner` are regenerated from the re-download rather than preserved)

#### Scenario: Critical command failure aborts
- **WHEN** a critical command (cache clear, `flutter pub get`, sidecar/dependency copy, or smoke test) exits with a non-zero code
- **THEN** `run.bat` stops with an error rather than silently continuing to the next step; the Flutter build is handled separately by the self-heal / surface-and-classify branches rather than a bare abort

#### Scenario: Retry success is non-silent
- **WHEN** the first build fails but the retried build succeeds
- **THEN** `run.bat` prints a notice that the first build failed and was automatically retried, rather than silently proceeding

#### Scenario: Retry still fails, falls through to surface and classify the cause
- **WHEN** the retried build still fails
- **THEN** `run.bat` proceeds to surface and classify the real error instead of showing only a build-failure shell

### Requirement: Real build error surfaced and classified
When a build fails after the self-heal retry, the launcher SHALL capture a verbose build log and classify the cause into network/environment, code error, or unknown (undetermined) using narrowly-scoped signatures, guiding the user rather than showing only a wrapped build-failure message (such as `MSB8066`). Classification SHALL be applied in priority order: code-error signatures first, then network signatures; when both are present the cause SHALL be reported as a code error (so an intermittent network word does not hide a real code bug). When the cause is undetermined, the launcher SHALL guide the user to open the log and read the first `Error:`/`fatal error` line as a fallback.

#### Scenario: Code cause classified (priority over network)
- **WHEN** the verbose build log matches compiler-error signatures (e.g. `fatal error C`, `error C`, `error LNK`, `unresolved external`), even if it also mentions download/network phrases
- **THEN** `run.bat` reports a real code error and points the user to the log

#### Scenario: Network cause classified
- **WHEN** the verbose build log matches network/download signatures (e.g. `Could not download`, `Trying to retrieve`, `HandshakeException`, `timed out`, `network is unreachable`, `resolve host`, pub get download failure) and does not match any compiler-error signature
- **THEN** `run.bat` reports a network/environment cause and states the app code is likely not at fault

#### Scenario: Indeterminate cause guided
- **WHEN** the verbose build log matches neither a compiler-error signature nor a network signature
- **THEN** `run.bat` reports the cause as undetermined and guides the user to open `%TEMP%\aliasagent_build.log` and read the first `Error:`/`fatal error` line, rather than asserting a network-or-code cause

### Requirement: Consistent sidecar build (no cross-configuration overwrite)
The launched app SHALL use a sidecar library built in the same configuration as the Flutter build, and the launcher SHALL NOT overwrite the run directory's sidecar with a different-configuration (Release) build.

#### Scenario: No cross-configuration overwrite
- **WHEN** `run.bat` builds and launches the app
- **THEN** the `sidecar.dll` in the run directory is the Debug-configuration build matching the app, and is not replaced by a Release-configuration build

#### Scenario: Sidecar built by the Flutter build
- **WHEN** `flutter build windows --debug` succeeds
- **THEN** the C++ sidecar library and its dependencies are built and installed into the run directory in the same (Debug) configuration

### Requirement: Build output verification before launch
Before launching, the launcher SHALL verify the app executable and the sidecar library exist, and SHALL report an explicit actionable error (including a possible missing vcpkg toolchain) if either is missing, rather than launching an app that is missing its library.

#### Scenario: App executable missing
- **WHEN** `alias_agent.exe` is absent after the build
- **THEN** `run.bat` reports the missing executable and does not launch

#### Scenario: Sidecar library missing
- **WHEN** `sidecar.dll` is absent after the build
- **THEN** `run.bat` reports the missing sidecar (including a likely vcpkg-not-found cause) and does not launch

### Requirement: Smoke test exercises the freshly built library
The launcher SHALL ensure the smoke test loads the sidecar library built by the current build (same configuration) with its matching runtime dependency DLLs, rather than a stale copy from a prior build. To that end it SHALL refresh the project-root `sidecar.dll` and its runtime dependency DLLs (`libcurl*.dll`, `zlib*.dll`) from the run-directory build, and SHALL fail with an explicit error rather than swallowing the copy result if any of them cannot be refreshed. The Debug-configuration guarantee strictly applies to `sidecar.dll` and its `-d`-flavored dependencies (Debug-to-Debug); the `libcurl*.dll` / `zlib*.dll` wildcards also carry release-named files (`libcurl.dll`/`zlib1.dll`), which are harmless redundancy and are intentionally kept (no no-mixing claim is made for libcurl/zlib — see the change design).

#### Scenario: Smoke test validates the current build
- **WHEN** `run.bat` refreshes the project-root `sidecar.dll` (Debug) and matching `libcurl*.dll` / `zlib*.dll` from the run-directory build, and each copy succeeds
- **THEN** the smoke test validates the freshly built library (Debug-configuration `sidecar.dll` with its `-d` dependencies) with its current dependencies

#### Scenario: Dependency refresh failure aborts
- **WHEN** any of the dependency refreshes (sidecar or libcurl/zlib) fails with a non-zero code
- **THEN** `run.bat` stops with an explicit error rather than launching or running the smoke test against a stale library
