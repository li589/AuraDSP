cmake_minimum_required(VERSION 3.20)
project(auravm_drivers LANGUAGES C CXX)

# 独立于引擎构建（解耦铁律）；用户态只需要 Windows SDK。
set(VMCLIENT "${CMAKE_CURRENT_SOURCE_DIR}/02_voicemeeter_client")
set(APO "${CMAKE_CURRENT_SOURCE_DIR}/03_system_apo")

add_library(auravm STATIC
    "${VMCLIENT}/VmRemoteLoader.cpp"
    "${VMCLIENT}/VmAudioCallback.cpp"
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

add_executable(vm_pump_test
    "${VMCLIENT}/vm_pump_test.cpp"
)
target_link_libraries(vm_pump_test PRIVATE auravm version)
target_compile_options(vm_pump_test PRIVATE /utf-8 /W1 /EHsc)
set_property(TARGET vm_pump_test PROPERTY CXX_STANDARD 20)
set_property(TARGET vm_pump_test PROPERTY MSVC_RUNTIME_LIBRARY "MultiThreadedDLL")

add_library(auraapo STATIC
    "${APO}/ApoInspector.cpp"
)
target_include_directories(auraapo PUBLIC "${APO}")
target_compile_options(auraapo PRIVATE /utf-8 /W1 /EHsc)
set_property(TARGET auraapo PROPERTY CXX_STANDARD 20)
set_property(TARGET auraapo PROPERTY MSVC_RUNTIME_LIBRARY "MultiThreadedDLL")

add_executable(apo_inspect
    "${APO}/apo_inspect.cpp"
)
# MMDevice/PropertyStore/COM 在 ole32。
target_link_libraries(apo_inspect PRIVATE auraapo ole32 version)
target_compile_options(apo_inspect PRIVATE /utf-8 /W1 /EHsc)
set_property(TARGET apo_inspect PROPERTY CXX_STANDARD 20)
set_property(TARGET apo_inspect PROPERTY MSVC_RUNTIME_LIBRARY "MultiThreadedDLL")
