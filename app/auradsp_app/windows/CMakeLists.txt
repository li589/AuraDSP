# Project-level configuration.
cmake_minimum_required(VERSION 3.14)
project(auradsp_app LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "auradsp_app")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)

# Define build configuration option.
get_property(IS_MULTICONFIG GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
if(IS_MULTICONFIG)
  set(CMAKE_CONFIGURATION_TYPES "Debug;Profile;Release"
    CACHE STRING "" FORCE)
else()
  if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE "Debug" CACHE
      STRING "Flutter build mode" FORCE)
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
      "Debug" "Profile" "Release")
  endif()
endif()
# Define settings for the Profile build mode.
set(CMAKE_EXE_LINKER_FLAGS_PROFILE "${CMAKE_EXE_LINKER_FLAGS_RELEASE}")
set(CMAKE_SHARED_LINKER_FLAGS_PROFILE "${CMAKE_SHARED_LINKER_FLAGS_RELEASE}")
set(CMAKE_C_FLAGS_PROFILE "${CMAKE_C_FLAGS_RELEASE}")
set(CMAKE_CXX_FLAGS_PROFILE "${CMAKE_CXX_FLAGS_RELEASE}")

# Use Unicode for all projects.
add_definitions(-DUNICODE -D_UNICODE)

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_17)
  target_compile_options(${TARGET} PRIVATE /W4 /WX /wd"4100")
  target_compile_options(${TARGET} PRIVATE /EHsc)
  target_compile_definitions(${TARGET} PRIVATE "_HAS_EXCEPTIONS=0")
  target_compile_definitions(${TARGET} PRIVATE "$<$<CONFIG:Debug>:_DEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")


# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)


# === Installation ===
# Support files are copied into place next to the executable, so that it can
# run in place. This is done instead of making a separate bundle (as on Linux)
# so that building and running from within Visual Studio will work.
set(BUILD_BUNDLE_DIR "$<TARGET_FILE_DIR:${BINARY_NAME}>")
# Make the "install" step default, as it's required to run.
set(CMAKE_VS_INCLUDE_INSTALL_TO_DEFAULT_BUILD 1)
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

# AuraDSP Engines：随包分发桌面引擎 DLL（源码整合产物，不依赖预编译 API）
set(AURADSP_ENGINE_DLL
    "${CMAKE_CURRENT_SOURCE_DIR}/../../../core/desktop/windows/out/Release/auradsp_engine.dll")
if(EXISTS "${AURADSP_ENGINE_DLL}")
  install(FILES "${AURADSP_ENGINE_DLL}" DESTINATION "${CMAKE_INSTALL_PREFIX}"
    COMPONENT Runtime)
endif()

# Phase 4：进程外插件宿主与引擎 DLL 同目录分发。
set(AURADSP_PLUGIN_HOST_EXE
    "${CMAKE_CURRENT_SOURCE_DIR}/../../../core/desktop/windows/out/Release/auradsp_plugin_host.exe")
if(EXISTS "${AURADSP_PLUGIN_HOST_EXE}")
  install(FILES "${AURADSP_PLUGIN_HOST_EXE}" DESTINATION "${CMAKE_INSTALL_PREFIX}"
    COMPONENT Runtime)
endif()

# VB-Callback 常驻桥（bridge/vm_bridge）：有则随包，无则跳过（对应模式不可用，
# UI 设备卡会直接显示原因；缺失不拦构建）。
set(AURAVM_BRIDGE_DLL
    "${CMAKE_CURRENT_SOURCE_DIR}/../../../core/desktop/windows-drivers/out/Release/auravm_bridge.dll")
if(EXISTS "${AURAVM_BRIDGE_DLL}")
  install(FILES "${AURAVM_BRIDGE_DLL}" DESTINATION "${CMAKE_INSTALL_PREFIX}"
    COMPONENT Runtime)
endif()

# ASIO 常驻桥（04_asio_client，Phase 3）：分发规则同上（有则随包无则跳过）。
set(AURAASIO_BRIDGE_DLL
    "${CMAKE_CURRENT_SOURCE_DIR}/../../../core/desktop/windows-drivers/out/Release/auraasio_bridge.dll")
if(EXISTS "${AURAASIO_BRIDGE_DLL}")
  install(FILES "${AURAASIO_BRIDGE_DLL}" DESTINATION "${CMAKE_INSTALL_PREFIX}"
    COMPONENT Runtime)
endif()

# AuraVAIO 常驻桥（01_vaio_driver / vaio_bridge）：随包分发
set(AURAVAIO_BRIDGE_DLL
    "${CMAKE_CURRENT_SOURCE_DIR}/../../../core/desktop/windows-drivers/out/Release/auravaio_bridge.dll")
if(EXISTS "${AURAVAIO_BRIDGE_DLL}")
  install(FILES "${AURAVAIO_BRIDGE_DLL}" DESTINATION "${CMAKE_INSTALL_PREFIX}"
    COMPONENT Runtime)
endif()

# 声学资源包（VDC耳机校准库、Liveprog 脚本、核心脉冲与清单）：安装到 resources/
set(AURADSP_ASSETS_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../../assets")
if(EXISTS "${AURADSP_ASSETS_DIR}/manifest.json")
  install(DIRECTORY "${AURADSP_ASSETS_DIR}/ddc"
    DESTINATION "${CMAKE_INSTALL_PREFIX}/resources"
    COMPONENT Runtime)
  install(DIRECTORY "${AURADSP_ASSETS_DIR}/liveprog"
    DESTINATION "${CMAKE_INSTALL_PREFIX}/resources"
    COMPONENT Runtime)
  install(FILES "${AURADSP_ASSETS_DIR}/manifest.json"
    DESTINATION "${CMAKE_INSTALL_PREFIX}/resources"
    COMPONENT Runtime)
  # 核心常用卷积脉冲分类安装（耳机校准、空间3D、扬声器仿真）
  if(EXISTS "${AURADSP_ASSETS_DIR}/convolver/01_headphone_correction")
    install(DIRECTORY "${AURADSP_ASSETS_DIR}/convolver/01_headphone_correction"
      DESTINATION "${CMAKE_INSTALL_PREFIX}/resources/convolver"
      COMPONENT Runtime)
  endif()
  if(EXISTS "${AURADSP_ASSETS_DIR}/convolver/02_spatial_3d")
    install(DIRECTORY "${AURADSP_ASSETS_DIR}/convolver/02_spatial_3d"
      DESTINATION "${CMAKE_INSTALL_PREFIX}/resources/convolver"
      COMPONENT Runtime)
  endif()
  if(EXISTS "${AURADSP_ASSETS_DIR}/convolver/07_speaker_devices")
    install(DIRECTORY "${AURADSP_ASSETS_DIR}/convolver/07_speaker_devices"
      DESTINATION "${CMAKE_INSTALL_PREFIX}/resources/convolver"
      COMPONENT Runtime)
  endif()
endif()

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

if(PLUGIN_BUNDLED_LIBRARIES)
  install(FILES "${PLUGIN_BUNDLED_LIBRARIES}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/windows/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
   DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
   COMPONENT Runtime)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Install the AOT library on non-Debug builds only.
install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  CONFIGURATIONS Profile;Release
  COMPONENT Runtime)
