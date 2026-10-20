cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME} WIN32
  "flutter_window.cpp"
  "main.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# MSVC 默认按系统代码页（本机 936/GBK）解析源文件；本项目源码含 UTF-8 中文注释，
# 不显式声明会触发 C4819，而 runner 开了 /WX（警告即错误）直接构建失败。
# 显式告知 MSVC 源文件与执行字符集均为 UTF-8。
target_compile_options(${BINARY_NAME} PRIVATE "/utf-8")

# Add preprocessor definitions for the build version.
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")

# Disable Windows macros that collide with C++ standard library functions.
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")

# Add dependency libraries and include directories. Add any application-specific
# dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib")
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)

# 确保编译后 auradsp_engine.dll 实时同步到可执行文件所在目录
set(AURADSP_ENGINE_DLL
    "${CMAKE_SOURCE_DIR}/../../../core/desktop/windows/out/Release/auradsp_engine.dll")
if(EXISTS "${AURADSP_ENGINE_DLL}")
  add_custom_command(TARGET ${BINARY_NAME} POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
      "${AURADSP_ENGINE_DLL}"
      "$<TARGET_FILE_DIR:${BINARY_NAME}>")
endif()

# Phase 4：进程外插件宿主必须与 auradsp_engine.dll 同目录，客户端按 DLL 路径解析。
set(AURADSP_PLUGIN_HOST_EXE
    "${CMAKE_SOURCE_DIR}/../../../core/desktop/windows/out/Release/auradsp_plugin_host.exe")
if(EXISTS "${AURADSP_PLUGIN_HOST_EXE}")
  add_custom_command(TARGET ${BINARY_NAME} POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
      "${AURADSP_PLUGIN_HOST_EXE}"
      "$<TARGET_FILE_DIR:${BINARY_NAME}>")
endif()

# 同样在 POST_BUILD 中将已编译的常驻桥 DLL 实时同步至 runner 目录，确保本地调试与 FFI 畅通
foreach(BRIDGE_NAME auravm_bridge auravaio_bridge auraasio_bridge)
  set(BRIDGE_DLL "${CMAKE_SOURCE_DIR}/../../../core/desktop/windows-drivers/out/Release/${BRIDGE_NAME}.dll")
  if(EXISTS "${BRIDGE_DLL}")
    add_custom_command(TARGET ${BINARY_NAME} POST_BUILD
      COMMAND ${CMAKE_COMMAND} -E copy_if_different
        "${BRIDGE_DLL}"
        "$<TARGET_FILE_DIR:${BINARY_NAME}>")
  endif()
endforeach()


