#!/usr/bin/env python3
# smoke_audit_rulings_contract.py — 2026-11-22 全量审查裁定契约门
#
# 断言 user 对审查 N1/N4/N5 的裁定在源码层持续成立（防回归）：
#   N1 APO 共享块 SDDL 不含 Everyone(WD)、含交互用户(IU)——C 宏、
#      心跳字面量、Dart 发布者三处同口径；
#   N1 插件路径中转围栏：ApoEngineHost 加载插件前过
#      IsUnderTransitRoot，发布侧经 ApoTransit.transitPluginPathFor；
#   N4 ASIO 驱动引擎加载无环境变量覆盖、无裸名回落；
#   N5 私有 future() 选择子常量整套已删。
# 纯源码契约（不构建），与 smoke_asio_* 同风格。
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
failures = []


def check(cond, msg):
    if not cond:
        failures.append(msg)


def read(rel):
    return (ROOT / rel).read_text(encoding="utf-8", errors="replace")


# --- N1: SDDL 三处同口径（WD 出、IU 入） ---
apo_shared = read("core/desktop/windows-drivers/03_system_apo/ApoShared.h")
check("GA;;;WD" not in apo_shared, "ApoShared.h SDDL still grants Everyone")
check("GA;;;IU" in apo_shared, "ApoShared.h SDDL missing Interactive User")
aura_apo = read("core/desktop/windows-drivers/03_system_apo/AuraApo.cpp")
check("GA;;;WD" not in aura_apo, "AuraApo.cpp heartbeat SDDL still grants Everyone")
check("GA;;;IU" in aura_apo, "AuraApo.cpp heartbeat SDDL missing Interactive User")
dart_apo = read("app/auradsp_app/lib/engine/audio_isolate_apo.dart")
check("GA;;;WD" not in dart_apo, "Dart _apoSharedSddl still grants Everyone")
check("GA;;;IU" in dart_apo, "Dart _apoSharedSddl missing Interactive User")

# --- N1: 插件围栏（宿主校验 + 发布侧中转） ---
host = read("core/desktop/windows-drivers/03_system_apo/ApoEngineHost.cpp")
load_pos = host.find("fnSlotLoad_(engine_")
fence_pos = host.find("IsUnderTransitRoot(path)")
check(load_pos > 0 and 0 < fence_pos < load_pos,
      "ApplyPlugins does not fence plugin paths with IsUnderTransitRoot")
transit = read("app/auradsp_app/lib/engine/apo_transit.dart")
check("transitPluginPathFor" in transit,
      "ApoTransit.transitPluginPathFor missing")
check("transitPluginPathFor" in dart_apo,
      "ApoPluginPublisher does not transit plugin paths")

# --- N4: ASIO 驱动引擎加载纪律 ---
loader = read("core/desktop/windows-drivers/04_asio_driver/AuraAsioEngineLoader.h")
check("AURADSP_ENGINE_DLL" not in loader,
      "engine loader still honors the env-var override")
check('candidates.push_back(L"auradsp_engine.dll")' not in loader,
      "engine loader still has the bare-name fallback")
check("windows\\\\out\\\\Release" not in loader,
      "engine loader still has development-tree relative paths")

# --- N5: future() 私有选择子已删 ---
guid = read("core/desktop/windows-drivers/04_asio_driver/AuraAsioDriverGuid.h")
check("kAuraAsioFuture" not in guid,
      "AuraAsioDriverGuid.h still defines future() selectors")
driver = read("core/desktop/windows-drivers/04_asio_driver/AuraAsioDriver.cpp")
check("case kAuraAsioFuture" not in driver,
      "AuraAsioDriver.cpp still handles future() selectors")

if failures:
    print("FAIL smoke_audit_rulings_contract:")
    for f in failures:
        print(f"  - {f}")
    sys.exit(1)
print("PASS smoke_audit_rulings_contract")
