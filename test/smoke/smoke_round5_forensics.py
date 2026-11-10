#!/usr/bin/env python3
# 第五轮 S4 取证契约（源码级）：VAIO 桥首块取证对象 + isolate 落盘
# 行 + ASIO 失败分步口径。桥 DLL 的真实编译覆盖在 CI J5b 的
# ci_check 工程（VAIO 桥）；ASIO 侧依赖 Steinberg SDK 无法进 CI，
# 本门只钉住取证面不被误删/改口径，真机日志为最终证据。
import os
import sys

sys.stdout.reconfigure(errors="replace")
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
FAILS = []


def check(cond, label):
    print(("  PASS " if cond else "  FAIL ") + label)
    if not cond:
        FAILS.append(label)


def read(p):
    with open(os.path.join(ROOT, p), encoding="utf-8") as f:
        return f.read()


def main():
    vaio = read("core/desktop/windows-drivers/bridge/vaio_bridge/"
                "VaioBridge.cpp")
    # 取证对象全键（status JSON 的 forensics 对象；C 串内为 \" 转义形）
    for key in ['tw0', 'cur0', 'dataSize', 'align', 'raw',
                'peak', 'meanAbs', 'peakShift', 'meanAbsShift',
                'forensics']:
        check(f'\\"{key}\\"' in vaio, f"VaioBridge forensics 键 {key} 在场")
    check("fxDone" in vaio and "InterlockedExchange(&g_vaio.fxDone, 1)" in vaio,
          "取证一次性置位（fxDone）在场")
    check("vaio_start" in vaio and "InterlockedExchange(&g_vaio.fxDone, 0)" in vaio,
          "vaio_start 复位 fxDone 在场")

    iso = read("app/auradsp_app/lib/engine/audio_isolate.dart")
    check("vaio-forensics:" in iso, "isolate 落盘行 vaio-forensics 在场")
    check("st['forensics']" in iso, "isolate 消费 forensics 对象在场")

    asio = read("core/desktop/windows-drivers/04_asio_client/AsioHost.cpp")
    check("failed at COM step" in asio, "ASIO why 带 COM 步标记")
    check("failed at registry step" in asio, "ASIO why 带注册步标记")
    check("LookupAsioRegistry" in asio, "ASIO 纯注册表预查在场")
    check("AsioDriverList" not in asio.split("LookupAsioRegistry")[1]
          .split("bool AsioHost::open")[0],
          "预查实现内不构造 AsioDriverList（零 COM 副作用）")

    if FAILS:
        print(f"FAIL  smoke_round5_forensics ({len(FAILS)} 项)")
        return 1
    print("PASS  smoke_round5_forensics")
    return 0


if __name__ == "__main__":
    sys.exit(main())
