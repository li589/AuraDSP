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

add_executable(bootstrapper WIN32
  bootstrapper.cpp
  bootstrapper.rc
)

target_link_libraries(bootstrapper PRIVATE bcrypt shell32 shlwapi)

if(MSVC)
  target_compile_options(bootstrapper PRIVATE /utf-8 /W4)
endif()

set_target_properties(bootstrapper PROPERTIES
  OUTPUT_NAME "bootstrapper"
  RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/$<CONFIG>"
)
