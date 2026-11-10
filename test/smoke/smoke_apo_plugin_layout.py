# -*- coding: utf-8 -*-
"""smoke_apo_plugin_layout — Part I Q2 插件块布局漂移门（2026-11-10）。

插件块是手工契约（非引擎表派生，不用生成器）：C 侧落
ApoShared.h、Dart 侧落 apo_plugin_block.dart，两份常量与
telemetry v3 追加段的偏移逐项交叉断言，防单侧漂移。
"""
import os
import re
import sys

sys.stdout.reconfigure(errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__))))
SHARED_H = os.path.join(
    ROOT, "core", "desktop", "windows-drivers", "03_system_apo",
    "ApoShared.h")
DART = os.path.join(ROOT, "app", "auradsp_app", "lib", "engine",
                    "apo_plugin_block.dart")

FAILS = []


def check(cond, msg):
    print(("  PASS " if cond else "  FAIL ") + msg)
    if not cond:
        FAILS.append(msg)


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def c_define(text, name):
    m = re.search(rf"#define {name} (\S+)", text)
    return m.group(1) if m else None


def dart_const(text, name):
    m = re.search(rf"const int {name} = (\S+);", text)
    return m.group(1) if m else None


def main():
    h = read(SHARED_H)
    d = read(DART)

    pairs = [
        ("APO_PLUGINS_MAGIC", "kApoPluginsMagic", 0x47505541),
        ("APO_PLUGINS_VERSION", "kApoPluginsVersion", 1),
        ("APO_PLUGIN_SLOTS", "kApoPluginSlots", 4),
        ("APO_PLUGIN_PATH_BYTES", "kApoPluginPathBytes", 1024),
        ("APO_PLUGIN_ID_BYTES", "kApoPluginIdBytes", 256),
        ("APO_PLUGIN_STATE_BYTES", "kApoPluginStateBytes", 524288),
        ("APO_PLUGIN_BLOCK_HEADER_BYTES", "kApoPluginBlockHeaderBytes", 64),
        ("APO_PLUGIN_SLOT_HEADER_BYTES", "kApoPluginSlotHeaderBytes", 64),
        ("APO_PLUGIN_BLOCK_BYTES", "kApoPluginBlockBytes", 2105344),
    ]
    for cname, dname, expect in pairs:
        cv = c_define(h, cname)
        dv = dart_const(d, dname)
        cval = None
        if cv is not None:
            cv = cv.rstrip("uU")
            cval = int(cv, 0)
        dval = int(dv, 0) if dv is not None else None
        check(cval == expect and dval == expect,
              f"{cname} == {dname} == {expect}（C={cval} Dart={dval}）")

    stride = 64 + 1024 + 256 + 524288
    check(dart_const(d, "kApoPluginSlotStride") == str(stride),
          f"槽步长 Dart == {stride}")
    check("APO_PLUGIN_SLOT_STRIDE" in h and "APO_PLUGIN_ID_BYTES" in h,
          "C 侧步长为组合宏（64+1024+256+524288）")
    used = 64 + 4 * stride
    check(dart_const(d, "kApoPluginBlockUsedBytes") == str(used),
          f"块已用字节 Dart == {used}")
    check(used <= 2105344, "used <= mapping")

    # telemetry v3：版本与插件段偏移/槽尺寸在 C 侧以 static_assert 钉死
    check((c_define(h, "APO_TELEMETRY_VERSION") or "").rstrip("uU") == "3",
          "APO_TELEMETRY_VERSION == 3")
    check("offsetof(ApoTelemetryBlock, plugins) == 608" in h,
          "C 侧钉死 plugins offset 608")
    check("sizeof(ApoTelemetryBlock) == 736" in h,
          "C 侧钉死 telemetry 总长 736")
    check("sizeof(ApoTelemetryBlock::PluginSlot) == 32" in h,
          "C 侧钉死插件槽 32B")
    check(dart_const(d, "kApoTelemetryPluginsOffset") == "608",
          "Dart 插件段 offset == 608")
    check(dart_const(d, "kApoTelemetryPluginSlotU32") == "8",
          "Dart 插件槽 == 8 个 u32（32B）")

    # 共享对象名两侧一致
    check("AuraDSP_ApoPlugins" in h, "C 侧插件块名 AuraDSP_ApoPlugins")
    apo_dart = read(os.path.join(ROOT, "app", "auradsp_app", "lib",
                                 "engine", "audio_isolate_apo.dart"))
    check("AuraDSP_ApoPlugins" in apo_dart,
          "Dart 发布者使用同一共享对象名")

    if FAILS:
        print(f"FAIL  smoke_apo_plugin_layout ({len(FAILS)} 项)")
        return 1
    print("PASS  smoke_apo_plugin_layout")
    return 0


if __name__ == "__main__":
    sys.exit(main())
