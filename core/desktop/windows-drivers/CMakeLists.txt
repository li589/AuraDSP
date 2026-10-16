cmake_minimum_required(VERSION 3.20)
project(auravm_drivers LANGUAGES C CXX)

# 独立于引擎构建（解耦铁律）；用户态只需要 Windows SDK。
set(VMCLIENT "${CMAKE_CURRENT_SOURCE_DIR}/02_voicemeeter_client")
set(APO "${CMAKE_CURRENT_SOURCE_DIR}/03_system_apo")
# 常驻桥统一收敛到 bridge/（不编号）：vm_bridge / asio_bridge ……
# 02/03/04 是传输/宿主实现，桥只是薄 FFI 适配层，单列编号会造成"有的单出、有的集成"的混乱。
set(BRIDGEDIR "${CMAKE_CURRENT_SOURCE_DIR}/bridge")
set(VMBRIDGE "${BRIDGEDIR}/vm_bridge")
set(ASIOBRIDGE "${BRIDGEDIR}/asio_bridge")
set(VAIOBRIDGE "${BRIDGEDIR}/vaio_bridge")

# ---- 04 ASIO 宿主（Steinberg ASIO SDK 2.3.4，GPLv3 路线）----
# SDK 为外部工具链（同 NDK/Flutter SDK 铁律）：不 vendor、按路径引用。
# 本机默认路径见 04_asio_client/README.md；换机/升级改这个 cache 变量即可。
set(ASIO_SDK_ROOT "C:/FreeRulesPrograms/BasicToolkits/SteinbergDev/ASIOSDK"
    CACHE PATH "Steinberg ASIO SDK 2.3.4 root (see 04_asio_client/README.md)")
if(NOT EXISTS "${ASIO_SDK_ROOT}/common/asio.h")
    message(FATAL_ERROR
        "ASIO SDK not found at ${ASIO_SDK_ROOT}\n"
        "下载 Steinberg ASIO SDK 2.3.x 解压后设置 -DASIO_SDK_ROOT=<路径>；"
        "许可与登记规则见 core/desktop/windows-drivers/04_asio_client/README.md")
endif()
set(ASIODIR "${CMAKE_CURRENT_SOURCE_DIR}/04_asio_client")
# Windows 宿主最小源集（asiodrvr.cpp 在 WINDOWS 下 #error do not use this；
# combase/register/dllentry 为驱动侧或 DLL 侧，宿主不需要——2026-10-14 实测）。
add_library(auraasio_host STATIC
    "${ASIODIR}/AsioHost.cpp"
    "${ASIO_SDK_ROOT}/common/asio.cpp"
    "${ASIO_SDK_ROOT}/host/asiodrivers.cpp"
    "${ASIO_SDK_ROOT}/host/pc/asiolist.cpp")
target_include_directories(auraasio_host PUBLIC
    "${ASIODIR}" "${ASIO_SDK_ROOT}/common" "${ASIO_SDK_ROOT}/host" "${ASIO_SDK_ROOT}/host/pc")
target_compile_options(auraasio_host PRIVATE /utf-8 /W1 /EHsc)
set_property(TARGET auraasio_host PROPERTY CXX_STANDARD 20)
set_property(TARGET auraasio_host PROPERTY MSVC_RUNTIME_LIBRARY "MultiThreadedDLL")

add_executable(asio_probe "${ASIODIR}/asio_probe.cpp")
target_link_libraries(asio_probe PRIVATE auraasio_host ole32 version)

add_executable(asio_tone "${ASIODIR}/asio_tone.cpp")
target_link_libraries(asio_tone PRIVATE auraasio_host ole32 version)

foreach(tgt asio_probe asio_tone)
    target_compile_options(${tgt} PRIVATE /utf-8 /W1 /EHsc)
    set_property(TARGET ${tgt} PROPERTY CXX_STANDARD 20)
    set_property(TARGET ${tgt} PROPERTY MSVC_RUNTIME_LIBRARY "MultiThreadedDLL")
endforeach()

# ASIO-Client 常驻桥（Phase 2；app isolate 经 FFI 调用，镜像 VmBridge 契约）。
# 注意：这是 Client 线（打开第三方驱动）。Driver 线（自身作为驱动被 DAW 打开）
# 另行立项、单开目录，不进 bridge/（见 docs/20-执行双线规划）。
# 引擎 DLL 动态加载逻辑与测试注入复用 02 的 VmPumpCore.h（与 vm_bridge 同源，
# 不出现第二套搜索路径/第二套测试信号数学）；ASIO 传输面走 auraasio_host
#（宿主仍在 04_asio_client，桥只含 FFI 适配层）。
add_library(auraasio_bridge SHARED
    "${ASIOBRIDGE}/AsioBridge.cpp"
    "${ASIOBRIDGE}/AsioBridge.def"
)
target_include_directories(auraasio_bridge PRIVATE "${VMCLIENT}" "${ASIODIR}" "${ASIOBRIDGE}")
target_link_libraries(auraasio_bridge PRIVATE auraasio_host ole32 version)
target_compile_options(auraasio_bridge PRIVATE /utf-8 /W1 /EHsc)
set_property(TARGET auraasio_bridge PROPERTY CXX_STANDARD 20)
set_property(TARGET auraasio_bridge PROPERTY MSVC_RUNTIME_LIBRARY "MultiThreadedDLL")

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


# 常驻 VB 桥（app isolate 经 FFI 调用；VmRemoteLoader 编进本 DLL，
# 复用 02 自省逻辑；泵回调核心走 VmPumpCore.h，与 vm_pump_test 同源）。
add_library(auravm_bridge SHARED
    "${VMBRIDGE}/VmBridge.cpp"
    "${VMCLIENT}/VmRemoteLoader.cpp"
    "${VMBRIDGE}/VmBridge.def"
)
target_include_directories(auravm_bridge PRIVATE "${VMCLIENT}" "${VMBRIDGE}")
target_compile_options(auravm_bridge PRIVATE /utf-8 /W1 /EHsc)
set_property(TARGET auravm_bridge PROPERTY CXX_STANDARD 20)
set_property(TARGET auravm_bridge PROPERTY MSVC_RUNTIME_LIBRARY "MultiThreadedDLL")
target_link_libraries(auravm_bridge PRIVATE version)

# 常驻 AuraVAIO 桥（Mode 1 虚拟声卡模式；app isolate 经 FFI 调用）。
# 通过共享内存零拷贝连接 AuraVaioDriver 内核驱动，实时拉取音频进入 auradsp_engine，并输出到 WASAPI 物理设备。
add_library(auravaio_bridge SHARED
    "${VAIOBRIDGE}/VaioBridge.cpp"
    "${VAIOBRIDGE}/VaioBridge.def"
)
target_include_directories(auravaio_bridge PRIVATE
    "${VMCLIENT}"
    "${CMAKE_CURRENT_SOURCE_DIR}/01_vaio_driver/src"
    "${CMAKE_CURRENT_SOURCE_DIR}/common"
    "${VAIOBRIDGE}"
)
target_compile_options(auravaio_bridge PRIVATE /utf-8 /W1 /EHsc)
set_property(TARGET auravaio_bridge PROPERTY CXX_STANDARD 20)
set_property(TARGET auravaio_bridge PROPERTY MSVC_RUNTIME_LIBRARY "MultiThreadedDLL")
target_link_libraries(auravaio_bridge PRIVATE ole32 avrt version)

# ---- 04 ASIO 自研虚拟驱动（Driver 线）----
# 属性：COM In-Proc Server DLL (auraasio_driver.dll)
# 职责：实现 IASIO 接口，承载外部宿主（DAW）协商与双缓冲时钟泵，解耦零音效处理。
set(ASIODRVDIR "${CMAKE_CURRENT_SOURCE_DIR}/04_asio_driver")
add_library(auraasio_driver SHARED
    "${ASIODRVDIR}/AuraAsioDriver.cpp"
    "${ASIODRVDIR}/AuraAsioClassFactory.cpp"
    "${ASIODRVDIR}/AuraAsioWasapiSink.cpp"
    "${ASIODRVDIR}/AuraAsioDriverMain.cpp"
    "${ASIODRVDIR}/AuraAsioDriver.def"
)
target_include_directories(auraasio_driver PRIVATE
    "${ASIODRVDIR}"
    "${ASIO_SDK_ROOT}/common"
)
target_compile_options(auraasio_driver PRIVATE /utf-8 /W1 /EHsc)
set_property(TARGET auraasio_driver PROPERTY CXX_STANDARD 20)
set_property(TARGET auraasio_driver PROPERTY MSVC_RUNTIME_LIBRARY "MultiThreadedDLL")
target_link_libraries(auraasio_driver PRIVATE ole32 advapi32 winmm avrt version)


