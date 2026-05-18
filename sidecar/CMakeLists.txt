cmake_minimum_required(VERSION 3.20)
project(sidecar LANGUAGES CXX C)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

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
)

# Shared library
add_library(sidecar SHARED ${SOURCES})
target_include_directories(sidecar PUBLIC include)
target_include_directories(sidecar PUBLIC "${JSON_INCLUDE_DIR}")
target_compile_definitions(sidecar PRIVATE SIDECAR_EXPORTS)
target_link_libraries(sidecar PUBLIC CURL::libcurl ${PLATFORM_LIB})

# Install
install(TARGETS sidecar LIBRARY DESTINATION lib)