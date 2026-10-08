#!/usr/bin/env python3
"""patch_xml.py — 拉取 /odm/etc/audio_effects_config.xml，注入 SpikeEQ 注册项，推送回设备。"""
import subprocess, sys, os

ADB = r"D:/myPrograms/AndroidDevelop/Android-SDK/platform-tools/adb.exe"
UUID = "8e73f7a1-3c92-4f6b-9d5e-7a1b2c3d4e5f"
REMOTE = "/data/local/tmp/spike/audio_effects_config.xml"
OUT = os.path.join(os.path.dirname(__file__), "..", "out", "audio_effects_config.xml")

def adb(*args, **kw):
    return subprocess.run([ADB, *args], capture_output=True, text=True, **kw)

xml = adb("shell", "cat", "/odm/etc/audio_effects_config.xml").stdout.replace("\r\n", "\n")
if "spike_eq" in xml:
    print("[patch] 已包含 spike_eq，跳过注入")
else:
    if "</libraries>" not in xml or "</effects>" not in xml or "</audio_effects_conf>" not in xml:
        print("[patch] ERROR: odm xml 结构不符合预期"); sys.exit(1)
    xml = xml.replace("</libraries>",
        f'        <library name="spike_eq" path="libspikeeq.so"/>\n    </libraries>', 1)
    xml = xml.replace("</effects>",
        f'        <effect name="spike_eq" library="spike_eq" uuid="{UUID}"'
        f' type="0bed4300-ddd6-11db-8f34-0002a5d5c51b"/>\n    </effects>', 1)
    xml = xml.replace("</audio_effects_conf>",
        '    <postprocess>\n'
        '        <stream type="music">\n'
        '            <apply effect="spike_eq"/>\n'
        '        </stream>\n'
        '        <stream type="system">\n'
        '            <apply effect="spike_eq"/>\n'
        '        </stream>\n'
        '        <stream type="dtmf">\n'
        '            <apply effect="spike_eq"/>\n'
        '        </stream>\n'
        '    </postprocess>\n</audio_effects_conf>', 1)
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8", newline="\n") as f:
        f.write(xml)
    print("[patch] 已注入 library/effect/postprocess 三项")

adb("shell", "mkdir", "-p", "/data/local/tmp/spike")
r = adb("push", os.path.abspath(OUT), REMOTE)
print(r.stdout.strip() or r.stderr.strip())
ok = ("pushed" in (r.stdout + r.stderr))
sys.exit(0 if ok else 1)
