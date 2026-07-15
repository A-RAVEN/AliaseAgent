# x64-windows-asan-static — custom vcpkg triplet for ASan builds
#
# Uses static CRT (/MT) + /fsanitize=address for all libraries.
# Required for sidecar_tests ASan builds so libcurl links with ASan runtime.
#
# Usage:
#   vcpkg install --triplet x64-windows-asan-static

set(VCPKG_TARGET_ARCHITECTURE x64)
set(VCPKG_CRT_LINKAGE static)
set(VCPKG_LIBRARY_LINKAGE static)

set(VCPKG_CMAKE_SYSTEM_NAME Windows)
set(VCPKG_PLATFORM_TOOLSET v143)

# ASan flags for MSVC
set(VCPKG_C_FLAGS "/fsanitize=address")
set(VCPKG_CXX_FLAGS "/fsanitize=address")
set(VCPKG_LINKER_FLAGS "/fsanitize=address")
