cmake_minimum_required(VERSION 3.20)
project(auravm_drivers LANGUAGES C CXX)

# 独立于引擎构建（解耦铁律）；用户态只需要 Windows SDK。
set(VMCLIENT "${CMAKE_CURRENT_SOURCE_DIR}/02_voicemeeter_client")

add_library(auravm STATIC
    "${VMCLIENT}/VmRemoteLoader.cpp"
)

target_include_directories(auravm PUBLIC "${VMCLIENT}")
target_compile_options(auravm PRIVATE /utf-8 /W1 /EHsc)
set_property(TARGET auravm PROPERTY CXX_STANDARD 20)
set_property(TARGET auravm PROPERTY MSVC_RUNTIME_LIBRARY "MultiThreadedDLL")

add_executable(vm_detect
    "${VMCLIENT}/vm_detect.cpp"
)
target_link_libraries(vm_detect PRIVATE auravm version)
target_compile_options(vm_detect PRIVATE /utf-8 /W1 /EHsc)
set_property(TARGET vm_detect PROPERTY CXX_STANDARD 20)
set_property(TARGET vm_detect PROPERTY MSVC_RUNTIME_LIBRARY "MultiThreadedDLL")
