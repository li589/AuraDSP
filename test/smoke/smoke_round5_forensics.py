#!/usr/bin/env python3
# 第五轮 S4 取证契约（源码级）：VAIO 桥首块取证对象 + isolate 落盘
# 行 + ASIO 失败取证口径。桥 DLL 的真实编译覆盖在 CI J5b 的
# ci_check 工程（VAIO 桥）；ASIO 侧依赖 Steinberg SDK 无法进 CI，
# 本门只钉住取证面不被误删/改口径，真机日志为最终证据。
# r57 P0 修订：ASIO 失败口径由「注册表预查分步推断」改为失败后直取
# asioOpenDriver 真实 rc（旧口径把 STA 套间问题误报为 COM/注册表
# 步，2026-11-19 定罪）——本门同步改钉新口径并断言旧口径已删除。
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
    # r57 P0 新口径：open 失败后以 ProbeOpenRc 直取 asioOpenDriver
    # 的真实 rc 写进 why（HRESULT/DRVERR 原码），不再靠注册表反推。
    check("ProbeOpenRc" in asio, "ASIO 失败真实 rc 探针在场")
    check("asioOpenDriver" in asio, "ASIO 探针直调 asioOpenDriver")
    check("asioOpenDriver rc=" in asio, "ASIO why 带真实 rc")
    check("device already open" in asio, "ASIO why 带 -5002 语义标记")
    check("driver not in ASIO enumeration" in asio,
          "ASIO why 带未枚举标记")
    # 旧误导口径必须已删除（防复辟）：注册表预查启发式 + 分步文案。
    check("LookupAsioRegistry" not in asio, "ASIO 注册表预查已删除")
    check("failed at COM step" not in asio, "ASIO COM 步旧文案已删除")
    check("failed at registry step" not in asio,
          "ASIO 注册步旧文案已删除")

    if FAILS:
        print(f"FAIL  smoke_round5_forensics ({len(FAILS)} 项)")
        return 1
    print("PASS  smoke_round5_forensics")
    return 0


if __name__ == "__main__":
    sys.exit(main())
