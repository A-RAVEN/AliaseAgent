cmake_minimum_required(VERSION 3.20)
project(sidecar LANGUAGES CXX C)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# ASan build mode — applies to sidecar_tests only (NOT sidecar.dll)
option(ENABLE_ASAN "Enable AddressSanitizer for sidecar_tests" OFF)

# Platform detection
if(WIN32)
  set(PLATFORM_LIB ws2_32)
  add_definitions(-D_CRT_SECURE_NO_WARNINGS -DWIN32_LEAN_AND_MEAN -DNOMINMAX)
elseif(APPLE)
  set(PLATFORM_LIB)
else()
  set(PLATFORM_LIB pthread)
endif()

# nlohmann/json (header-only, vendored)
set(JSON_INCLUDE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/third_party/json/include")
if(NOT EXISTS "${JSON_INCLUDE_DIR}/nlohmann/json.hpp")
  file(DOWNLOAD
    "https://github.com/nlohmann/json/releases/download/v3.11.3/json.hpp"
    "${JSON_INCLUDE_DIR}/nlohmann/json.hpp"
    STATUS DOWNLOAD_STATUS
  )
  list(GET DOWNLOAD_STATUS 0 STATUS_CODE)
  if(NOT STATUS_CODE EQUAL 0)
    message(FATAL_ERROR "Failed to download nlohmann/json.hpp")
  endif()
endif()

# libcurl
find_package(CURL REQUIRED)

# Source files
set(SOURCES
  src/sidecar_api.cpp
  src/logger.cpp
  src/model_gateway.cpp
  src/tools.cpp
  src/crash_handler.cpp
  src/search_provider.cpp
  src/openai_transport.cpp
  src/web_fetch.cpp
  src/zhipuai_search.cpp
  src/searxng_search.cpp
  src/kimi_search.cpp
)

# Shared library
add_library(sidecar SHARED ${SOURCES})
target_include_directories(sidecar PUBLIC include)
target_include_directories(sidecar PUBLIC "${JSON_INCLUDE_DIR}")
target_compile_definitions(sidecar PRIVATE SIDECAR_EXPORTS)
target_link_libraries(sidecar PUBLIC CURL::libcurl ${PLATFORM_LIB})

# Install
install(TARGETS sidecar LIBRARY DESTINATION lib)

# ============================================================================
# Tests
# ============================================================================
enable_testing()

include(FetchContent)
FetchContent_Declare(
  Catch2
  GIT_REPOSITORY https://github.com/catchorg/Catch2.git
  GIT_TAG v3.11.0
)
FetchContent_MakeAvailable(Catch2)

# Test executable — links production sources directly (NOT sidecar_api.cpp,
# to avoid SIDECAR_API / __declspec(dllimport) conflicts)
add_executable(sidecar_tests
  test/test_main.cpp
  src/logger.cpp
  src/model_gateway.cpp
  src/tools.cpp
  src/crash_handler.cpp
  src/search_provider.cpp
  src/openai_transport.cpp
  src/web_fetch.cpp
  src/zhipuai_search.cpp
  src/searxng_search.cpp
  src/kimi_search.cpp
  test/sse_parser_test.cpp
  test/tool_execution_test.cpp
  test/http_client_test.cpp
  test/ffi_tracing_test.cpp
  test/search_provider_test.cpp
)
target_include_directories(sidecar_tests PRIVATE include src test "${JSON_INCLUDE_DIR}")
target_compile_definitions(sidecar_tests PRIVATE _CRT_SECURE_NO_WARNINGS WIN32_LEAN_AND_MEAN NOMINMAX
    FIXTURE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/test/fixtures/sse")
target_link_libraries(sidecar_tests PRIVATE Catch2::Catch2 CURL::libcurl ${PLATFORM_LIB})

add_test(NAME sidecar_tests COMMAND sidecar_tests)

# Apply ASan to sidecar_tests target only (NOT sidecar DLL — Dart VM conflict)
if(ENABLE_ASAN)
  if(MSVC)
    target_compile_options(sidecar_tests PRIVATE /fsanitize=address)
    target_link_options(sidecar_tests PRIVATE /fsanitize=address)
  else()
    target_compile_options(sidecar_tests PRIVATE -fsanitize=address -fno-omit-frame-pointer)
    target_link_options(sidecar_tests PRIVATE -fsanitize=address)
  endif()
  message(STATUS "ASan enabled for sidecar_tests")
endif()