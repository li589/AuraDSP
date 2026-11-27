# AuraDSP Setup bootstrapper — minimal Win32 shell (design §3).
# Standalone project: cmake -S . -B build -A x64 && cmake --build build
# --config Release produces Release/bootstrapper.exe.
cmake_minimum_required(VERSION 3.20)
project(auradsp_bootstrapper CXX)

if(NOT WIN32)
  message(FATAL_ERROR "The bootstrapper is a Windows-only target.")
endif()

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(AURADSP_PUBLISHER_THUMBPRINT "" CACHE STRING
    "Authenticode signer SHA-1 thumbprint pinned into elevated setup")
option(AURADSP_SETUP_UNSIGNED_TEST_ONLY
    "Allow unsigned elevated setup in a local test harness" OFF)
if(AURADSP_PUBLISHER_THUMBPRINT AND AURADSP_SETUP_UNSIGNED_TEST_ONLY)
  message(FATAL_ERROR
      "AURADSP_SETUP_UNSIGNED_TEST_ONLY cannot be combined with a publisher pin")
endif()
if(AURADSP_PUBLISHER_THUMBPRINT)
  string(LENGTH "${AURADSP_PUBLISHER_THUMBPRINT}" publisher_thumb_len)
  if(NOT publisher_thumb_len EQUAL 40 OR
     NOT AURADSP_PUBLISHER_THUMBPRINT MATCHES "^[0-9a-fA-F]+$")
    message(FATAL_ERROR "AURADSP_PUBLISHER_THUMBPRINT must be a 40-digit SHA-1 hex string")
  endif()
  file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/trusted_publisher.h"
    "#pragma once\n#define AURADSP_TRUSTED_PUBLISHER_THUMBPRINT L\"${AURADSP_PUBLISHER_THUMBPRINT}\"\n")
else()
  configure_file(trusted_publisher.h trusted_publisher.h COPYONLY)
endif()
add_executable(bootstrapper WIN32
  bootstrapper.cpp
  bootstrapper.rc
)
if(AURADSP_SETUP_UNSIGNED_TEST_ONLY)
  target_compile_definitions(bootstrapper PRIVATE AURADSP_SETUP_UNSIGNED_TEST_ONLY)
endif()
target_include_directories(bootstrapper PRIVATE "${CMAKE_CURRENT_BINARY_DIR}")
target_link_libraries(bootstrapper PRIVATE bcrypt shell32 shlwapi wintrust crypt32 advapi32)

if(MSVC)
  target_compile_options(bootstrapper PRIVATE /utf-8 /W4)
  # bootstrapper.rc already embeds our manifest (1 RT_MANIFEST);
  # without this the linker generates a second default manifest and
  # the link dies with CVT1100 duplicate resource + LNK1123.
  target_link_options(bootstrapper PRIVATE /MANIFEST:NO)
endif()

set_target_properties(bootstrapper PROPERTIES
  OUTPUT_NAME "bootstrapper"
  RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/$<CONFIG>"
)
