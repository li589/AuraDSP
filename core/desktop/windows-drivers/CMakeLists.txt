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

add_library(auraapo_inspect STATIC
    "${APO}/ApoInspector.cpp"
)
target_include_directories(auraapo_inspect PUBLIC "${APO}")
target_compile_options(auraapo_inspect PRIVATE /utf-8 /W1 /EHsc)
set_property(TARGET auraapo_inspect PROPERTY CXX_STANDARD 20)
set_property(TARGET auraapo_inspect PROPERTY MSVC_RUNTIME_LIBRARY "MultiThreadedDLL")

add_executable(apo_inspect
    "${APO}/apo_inspect.cpp"
)
# MMDevice/PropertyStore/COM 在 ole32。
target_link_libraries(apo_inspect PRIVATE auraapo_inspect ole32 version)
target_compile_options(apo_inspect PRIVATE /utf-8 /W1 /EHsc)
set_property(TARGET apo_inspect PROPERTY CXX_STANDARD 20)
set_property(TARGET apo_inspect PROPERTY MSVC_RUNTIME_LIBRARY "MultiThreadedDLL")

add_executable(apo_selftest
    "${APO}/apo_selftest.cpp"
)
target_link_libraries(apo_selftest PRIVATE ole32 audiomediatypecrt)
target_compile_options(apo_selftest PRIVATE /utf-8 /W1 /EHsc)
set_property(TARGET apo_selftest PROPERTY CXX_STANDARD 20)
set_property(TARGET apo_selftest PROPERTY MSVC_RUNTIME_LIBRARY "MultiThreadedDLL")

add_executable(tone_play
    "${APO}/tone_play.cpp"
)
target_link_libraries(tone_play PRIVATE ole32)
target_compile_options(tone_play PRIVATE /utf-8 /W1 /EHsc)
set_property(TARGET tone_play PROPERTY CXX_STANDARD 20)
set_property(TARGET tone_play PROPERTY MSVC_RUNTIME_LIBRARY "MultiThreadedDLL")

add_executable(set_default_endpoint
    "${APO}/set_default_endpoint.cpp"
)
target_link_libraries(set_default_endpoint PRIVATE ole32)
target_compile_options(set_default_endpoint PRIVATE /utf-8 /W1 /EHsc)
set_property(TARGET set_default_endpoint PROPERTY CXX_STANDARD 20)
set_property(TARGET set_default_endpoint PROPERTY MSVC_RUNTIME_LIBRARY "MultiThreadedDLL")

# 自研 APO（CBaseAudioProcessingObject 基类在 audiobaseprocessingobject.lib；
# RegisterAPO 在 audioeng.lib；ConvertStringSecurityDescriptor 在 advapi32）。
add_library(AuraApo SHARED
    "${APO}/AuraApo.cpp"
    "${APO}/ApoClassFactory.cpp"
    "${APO}/AuraApoMain.cpp"
    "${APO}/AuraApo.def"
)
target_include_directories(AuraApo PRIVATE "${APO}")
# /guard:cf 必需：audiodg 全 CFG instrumented，无 CFG 位图的 APO 会在首个
# 被保护的虚调用点 fail-fast（0xC0000409/0xA，2026-10-14 dump 定罪）。
target_compile_options(AuraApo PRIVATE /utf-8 /W1 /EHsc /guard:cf)
target_link_options(AuraApo PRIVATE /guard:cf)
# advapi32 延迟加载：APO 住 audiodg，加载期绝不解析非预载依赖，
# 避免 loader-order 牵连 apphelp 初始化链（2026-10-14 验证方向）。
target_link_options(AuraApo PRIVATE "/DELAYLOAD:advapi32.dll")
set_property(TARGET AuraApo PROPERTY CXX_STANDARD 20)
# 静态 CRT（/MT）：APO 住在 audiodg 里，绝不可首次拉入 System32 版
# VCRUNTIME/MSVCP140（曾致 loader-log 路径崩，2026-10-14 定罪方向）。
# 其它工具目标保持 /MD 不动。
set_property(TARGET AuraApo PROPERTY MSVC_RUNTIME_LIBRARY "MultiThreaded")
target_link_libraries(AuraApo PRIVATE
    audiobaseprocessingobject ole32 advapi32 uuid version audioeng
    audiomediatypecrt legacy_stdio_definitions delayimp)


add_executable(classfact_probe
    "${APO}/classfact_probe.cpp"
)
target_link_libraries(classfact_probe PRIVATE ole32)
target_compile_options(classfact_probe PRIVATE /utf-8 /W1 /EHsc)
set_property(TARGET classfact_probe PROPERTY CXX_STANDARD 20)
set_property(TARGET classfact_probe PROPERTY MSVC_RUNTIME_LIBRARY "MultiThreadedDLL")


add_executable(auditses_probe
    "${APO}/auditses_probe.cpp"
)
target_link_libraries(auditses_probe PRIVATE ole32)
target_compile_options(auditses_probe PRIVATE /utf-8 /W1 /EHsc)
set_property(TARGET auditses_probe PROPERTY CXX_STANDARD 20)
set_property(TARGET auditses_probe PROPERTY MSVC_RUNTIME_LIBRARY "MultiThreadedDLL")


add_executable(audioclient_probe
    "${APO}/audioclient_probe.cpp"
)
target_link_libraries(audioclient_probe PRIVATE ole32)
target_compile_options(audioclient_probe PRIVATE /utf-8 /W1 /EHsc)
set_property(TARGET audioclient_probe PROPERTY CXX_STANDARD 20)
set_property(TARGET audioclient_probe PROPERTY MSVC_RUNTIME_LIBRARY "MultiThreadedDLL")


add_executable(ases_probe
    "${APO}/ases_probe.cpp"
)
target_link_libraries(ases_probe PRIVATE ole32)
target_compile_options(ases_probe PRIVATE /utf-8 /W1 /EHsc)
set_property(TARGET ases_probe PROPERTY CXX_STANDARD 20)
set_property(TARGET ases_probe PROPERTY MSVC_RUNTIME_LIBRARY "MultiThreadedDLL")
