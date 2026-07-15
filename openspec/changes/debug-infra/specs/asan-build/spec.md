# ASan Build Mode — Spec

## ADDED Requirements

### Requirement: ASan CMake option
The CMake build SHALL support an `-DENABLE_ASAN=ON` option that enables AddressSanitizer for the `sidecar_tests` executable target only.

#### Scenario: ASan enabled via CMake flag
- **WHEN** CMake is configured with `-DENABLE_ASAN=ON`
- **THEN** the `sidecar_tests` target is compiled with `/fsanitize=address` (MSVC) or `-fsanitize=address` (GCC/Clang)
- **AND** the `sidecar` shared library target is NOT compiled with sanitizer flags

#### Scenario: ASan disabled by default
- **WHEN** CMake is configured without `-DENABLE_ASAN`
- **THEN** no sanitizer flags are applied to any target

### Requirement: ASan runtime static linking
On Windows MSVC, the ASan runtime SHALL be statically linked (`/fsanitize=address` with no `/INFERASANLIBS` dependency) to avoid requiring `clang_rt.asan_dynamic-x86_64.dll` at runtime.

#### Scenario: ASan sidecar_tests runs without external DLL
- **WHEN** `sidecar_tests` is built with ASan enabled
- **THEN** the executable runs without requiring any ASan DLL in PATH

### Requirement: ASan vcpkg triplet
A custom vcpkg triplet `x64-windows-asan-static` SHALL be provided to compile all C++ dependencies (libcurl) with ASan flags and static CRT.

#### Scenario: libcurl compiled with ASan
- **WHEN** vcpkg installs libcurl using the `x64-windows-asan-static` triplet
- **THEN** libcurl is compiled with `/fsanitize=address` and links with the static ASan runtime

### Requirement: Rebuild script ASan parameter
The rebuild script SHALL accept an `--asan` flag that passes `-DENABLE_ASAN=ON` through to CMake.

#### Scenario: rebuild with --asan
- **WHEN** `rebuild_sidecar.bat Debug --asan` is executed
- **THEN** sidecar is built with ASan enabled for the test target
- **AND** only the Debug build type accepts the `--asan` flag

### Requirement: ASan scope limited to sidecar_tests
ASan instrumentation SHALL NOT be applied to `sidecar.dll` loaded by the Flutter process.

#### Scenario: sidecar.dll is not ASan-instrumented
- **WHEN** ASan build is enabled
- **THEN** `sidecar.dll` loads successfully in the Flutter process without shadow memory conflicts
