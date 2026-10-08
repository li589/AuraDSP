#!/usr/bin/env python3
"""patch_xml_jdsp.py — 拉取 /odm/etc/audio_effects_config.xml，注入 AuraDSP(libjdsp) 注册项，推送回设备。

注意：若 spike 的 bind-mount 尚在，cat 到的就是已含 spike 项的补丁版——
本脚本在其上叠加 jdsp 项，二者共存；回滚时按挂载栈顺序逐层 umount。
"""
import subprocess, sys, os

ADB = r"D:/myPrograms/AndroidDevelop/Android-SDK/platform-tools/adb.exe"
UUID = "6d5d0f7a-3c1e-4a9b-8b2d-9f0a1c2d3e4f"          # AuraDSP libjdsp impl
TYPE = "0bed4300-ddd6-11db-8f34-0002a5d5c51b"           # 标准 EQ type
REMOTE = "/data/local/tmp/spike/audio_effects_config.xml"
OUT = os.path.join(os.path.dirname(__file__), "..", "out", "audio_effects_config.xml")

def adb(*args):
    return subprocess.run([ADB, *args], capture_output=True, text=True)

xml = adb("shell", "cat", "/odm/etc/audio_effects_config.xml").stdout.replace("\r\n", "\n")
if "libjdsp.so" in xml:
    print("[patch] 已包含 libjdsp，跳过注入")
else:
    if "</libraries>" not in xml or "</effects>" not in xml or "</audio_effects_conf>" not in xml:
        print("[patch] ERROR: odm xml 结构不符合预期"); sys.exit(1)
    xml = xml.replace("</libraries>",
        '        <library name="jamesdsp" path="libjdsp.so"/>\n    </libraries>', 1)
    xml = xml.replace("</effects>",
        f'        <effect name="jamesdsp" library="jamesdsp" uuid="{UUID}"'
        f' type="{TYPE}"/>\n    </effects>', 1)
    xml = xml.replace("</audio_effects_conf>",
        '    <postprocess>\n'
        '        <stream type="music">\n'
        '            <apply effect="jamesdsp"/>\n'
        '        </stream>\n'
        '        <stream type="system">\n'
        '            <apply effect="jamesdsp"/>\n'
        '        </stream>\n'
        '        <stream type="dtmf">\n'
        '            <apply effect="jamesdsp"/>\n'
        '        </stream>\n'
        '    </postprocess>\n</audio_effects_conf>', 1)
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8", newline="\n") as f:
        f.write(xml)
    print("[patch] 已注入 library/effect/postprocess 三项 (jamesdsp)")

adb("shell", "mkdir", "-p", "/data/local/tmp/spike")
r = adb("push", os.path.abspath(OUT), REMOTE)
print(r.stdout.strip() or r.stderr.strip())
ok = ("pushed" in (r.stdout + r.stderr))
sys.exit(0 if ok else 1)
