cmake_minimum_required(VERSION 3.20)
project(auradsp_bridge_ci_check LANGUAGES C CXX)

# CI 专用检查工程（第五轮 S4）：GitHub runner 没有 Steinberg ASIO
# SDK，上层 CMakeLists 的全量配置在 SDK 缺失时 FATAL，桥家族在
# CI 里长期零编译覆盖。本工程只收不依赖 SDK 的 VAIO 桥 TU 与其
# 等待原语测试，给桥侧改动以真实 MSVC 编译（及可跑测试）覆盖；
# 本机全量构建不走这里，产物也不出自这里（OBJECT 库仅编译）。
set(ROOT "${CMAKE_CURRENT_SOURCE_DIR}/..")

add_library(auravaio_bridge_check OBJECT "${ROOT}/bridge/vaio_bridge/VaioBridge.cpp")
target_include_directories(auravaio_bridge_check PRIVATE
    "${ROOT}/02_voicemeeter_client"
    "${ROOT}/01_vaio_driver/src"
    "${ROOT}/common"
    "${ROOT}/bridge/common"
    "${ROOT}/bridge/vaio_bridge")
target_compile_options(auravaio_bridge_check PRIVATE /utf-8 /W1 /EHsc)
set_property(TARGET auravaio_bridge_check PROPERTY CXX_STANDARD 20)

add_executable(vaio_pump_wait_test "${ROOT}/bridge/vaio_bridge/vaio_pump_wait_test.cpp")
target_include_directories(vaio_pump_wait_test PRIVATE "${ROOT}/bridge/vaio_bridge")
target_compile_options(vaio_pump_wait_test PRIVATE /utf-8 /W1 /EHsc)
set_property(TARGET vaio_pump_wait_test PROPERTY CXX_STANDARD 20)
