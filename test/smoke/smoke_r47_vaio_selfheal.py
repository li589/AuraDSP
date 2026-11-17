#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""smoke_r47_vaio_selfheal — 第四十七轮 S4 门禁。

定罪背景（r46 宾机实证）：VAIO 输出端点被其它程序占用时
桥 start 返回 0x8889000A（AUDCLNT_E_DEVICE_IN_USE)，启动
失败是终局——桥从未进入 active 记账，状态轮询与死亡回收
网都够不着，等多久都不自愈；且提示只有一行十六进制。

本门禁钉住修复口径：
  1. isolate：start 失败登记重试（同参数、5s 间隔），泵循
     环在桥段之外驱动重试，成功/停桥清登记；
  2. 文案：0x8889000A 在面板与通知两处都只呈现一句
     「该设备正在被另一个人使用」（user 裁定，Windows 口
     吻，不提进程/十六进制），l10n 双语在位。
"""
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
FAILS = []


def read(rel):
    with open(os.path.join(ROOT, rel), encoding="utf-8") as f:
        return f.read()


def check(name, cond):
    print(("PASS " if cond else "FAIL ") + name)
    if not cond:
        FAILS.append(name)


def main():
    app = os.path.join(ROOT, "app/auradsp_app/lib")
    iso = read("app/auradsp_app/lib/engine/audio_isolate.dart")
    events = read("app/auradsp_app/lib/core/state/state_events.dart")
    panel = read("app/auradsp_app/lib/features/settings/panels/hardware_io_output.dart")
    zh = read("app/auradsp_app/lib/l10n/app_zh.arb")
    en = read("app/auradsp_app/lib/l10n/app_en.arb")

    check("retry state fields exist",
          "bool vaioRetryPending = false;" in iso and
          "String vaioRetryEndpoint = '';" in iso)
    check("start failure arms the retry with same params",
          "vaioRetryPending = true;" in iso and
          "vaioRetryEndpoint = outputEndpointSubstr;" in iso)
    check("stop clears retry before active early-return",
          iso.index("vaioRetryPending = false;\n    if (!bridgeManager.isActive('vaio'))") > 0)
    check("pump loop drives retry outside bridge section",
          "vaiomode: retrying start (self-heal after failure)" in iso)
    check("panel maps DEVICE_IN_USE to plain sentence",
          "contains('0X8889000A')" in panel and "l.vaioDeviceInUse" in panel)
    check("notice maps DEVICE_IN_USE to plain sentence",
          "该设备正在被另一个人使用" in events)
    check("l10n pair present",
          '"vaioDeviceInUse": "该设备正在被另一个人使用"' in zh and
          '"vaioDeviceInUse": "This device is being used by another person"' in en)

    if FAILS:
        print("VAIO_SELFHEAL FAILURES:", FAILS)
        return 1
    print("vaio_selfheal: all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
