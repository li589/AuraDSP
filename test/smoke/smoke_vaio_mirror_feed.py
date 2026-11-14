# -*- coding: utf-8 -*-
"""smoke_vaio_mirror_feed.py — 监听镜像门禁：第二路渲染真接线 + 喂流规划守恒。

背景（全面复审 ASIO-2）：监听镜像开关自落地起只落盘、全仓无消费
端——桥里的 g_mirror 是参数镜像而非音频分路，面板只能置灰并标注
「尚未实现」。业主 2026-11-14 裁定补全：VAIO 桥内新增第二路
WASAPI 渲染（系统默认物理端点），把处理后帧分路给本地耳机监听。

本测试四层：
  [A] 源码不变式（config 键解析 / vaio_start 形参 / 泵内分路点 /
      DestroyWasapi 回收镜像对象 / status 镜像键恒输出）
  [B] vaio_mirror_feed_test.exe（驱动无关）：采样率归一总量守恒
      ±1 帧、缓冲钳制丢弃计数精确、饥饿与边界不产出
  [C] 喂流规划头本体不变式（钳制分支必须先记 drops 再截断，
      防止「静默吞帧」的假镜像实现回潮）
  [D] Dart 接线不变式（config_json mirror 键 / isolate 双命令读
      monitorMirror / setter 热重启 / 面板开关接真值 + 气泡 /
      「尚未实现」文案与 l10n 键已删）——防任一层断链回到装饰态
"""
import json
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DRIVERS = os.path.join(ROOT, "core", "desktop", "windows-drivers")
VAIO = os.path.join(DRIVERS, "bridge", "vaio_bridge")
SRC = os.path.join(VAIO, "VaioBridge.cpp")
FEED_H = os.path.join(VAIO, "VaioMirrorFeed.h")
TEST_EXE = os.path.join(DRIVERS, "out", "Release", "vaio_mirror_feed_test.exe")

fails = []
passes = 0


def check(name, ok, note=""):
    global passes
    if ok:
        passes += 1
        print(f"PASS  {name}" + (f"  ({note})" if note else ""))
    else:
        fails.append(name)
        print(f"FAIL  {name}" + (f"  ({note})" if note else ""))


def read(p):
    with open(p, "r", encoding="utf-8", errors="replace") as f:
        return f.read()


def strip_comments(src):
    out, i, n, quote = [], 0, len(src), ""
    while i < n:
        c = src[i]
        if quote:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(src[i + 1])
                i += 2
                continue
            if c == quote:
                quote = ""
            i += 1
            continue
        if c == '"' or c == "'":
            quote = c
            out.append(c)
            i += 1
            continue
        if c == "/" and i + 1 < n and src[i + 1] == "/":
            while i < n and src[i] != "\n":
                i += 1
            continue
        if c == "/" and i + 1 < n and src[i + 1] == "*":
            i += 2
            while i + 1 < n and not (src[i] == "*" and src[i + 1] == "/"):
                i += 1
            i += 2
            continue
        out.append(c)
        i += 1
    return "".join(out)


def func_body(src, name):
    """取 name(...) { ... } 的函数体（花括号配对）。"""
    pos = src.find(name + "(")
    if pos < 0:
        return ""
    i = src.find("{", pos)
    if i < 0:
        return ""
    start, depth = i, 0
    while i < len(src):
        if src[i] == "{":
            depth += 1
        elif src[i] == "}":
            depth -= 1
            if depth == 0:
                return src[start:i + 1]
        i += 1
    return ""


# ---------------------------------------------------------------- [A] 源码
print("\n=== [A] 源码不变式：镜像第二路渲染真接线 ===")

src = read(SRC)
code = strip_comments(src)

check("[A1] AbStartAdapt 解析 config 的 mirror 键",
      'abcfg::Long(config_json, "mirror", 0)' in code)
body_start = func_body(code, "vaio_start")
check("[A2] vaio_start 带 monitor_mirror 形参",
      "monitor_mirror" in code.split("vaio_start(")[1].split(")")[0]
      if "vaio_start(" in code else False)
check("[A3] 镜像目标排除主路同一设备（mirror-target-is-primary）",
      "mirror-target-is-primary" in body_start)
check("[A4] 镜像目标排除 AuraVAIO 自身（mirror-target-is-virtual）",
      "mirror-target-is-virtual" in body_start)
check("[A5] 镜像客户端在 start 内完成 Initialize",
      "pMirrorClient->Initialize" in body_start)

body_pump = func_body(code, "VaioPumpThreadProc")
check("[A6] 泵内存在镜像分路点 FeedMirror",
      "FeedMirror(framesToProcess, outRate)" in body_pump)
check("[A7] 分路点受 mirrorActive 门控（未激活零开销）",
      "mirrorActive" in body_pump and "FeedMirror" in body_pump)

body_feed = func_body(code, "FeedMirror")
check("[A8] FeedMirror 经规划器决定帧数（mirrorFeed.Plan）",
      "mirrorFeed.Plan" in body_feed)
check("[A9] FeedMirror 采样率不一致时走 ResampleLinear",
      "ResampleLinear" in body_feed)

body_destroy = func_body(code, "DestroyWasapi")
check("[A10] DestroyWasapi 回收镜像渲染客户端",
      "pMirrorRender->Release()" in body_destroy)
check("[A11] DestroyWasapi 回收镜像音频客户端并复位 mirrorActive",
      "pMirrorClient->Release()" in body_destroy and
      "mirrorActive, 0" in body_destroy)

body_status = func_body(code, "vaio_status")
check("[A12] status 恒输出 mirror/mirrorFrames/mirrorDrops 键",
      '\\"mirror\\":%ld' in body_status and
      "mirrorFrames" in body_status and "mirrorDrops" in body_status)
check("[A13] status 输出 mirrorNote（降级原因可见）",
      "mirrorNote" in body_status)

# ---------------------------------------------------------------- [C] 规划头
print("\n=== [C] VaioMirrorFeed.h 本体不变式 ===")

feed = strip_comments(read(FEED_H))
check("[C1] 钳制分支先记 drops 再截断（不静默吞帧）",
      "drops += (uint64_t)(out - availFrames);" in feed and
      "out = availFrames;" in feed)
check("[C2] 分数相位跨块携带（phase = want - out 口径）",
      "phase = want - (double)out;" in feed)
check("[C3] fed 只计实际规划写出帧",
      "fed += out;" in feed)

# ---------------------------------------------------------------- [D] Dart 接线
print("\n=== [D] Dart 接线不变式：config 键到面板开关全链 ===")

APP = os.path.join(ROOT, "app", "auradsp_app", "lib")
dart_bridge = read(os.path.join(APP, "engine", "audio_vaio_bridge.dart"))
check("[D1] Dart 桥 start 按 monitorMirror 写 config 的 mirror 键",
      "if (monitorMirror) 'mirror': 1," in dart_bridge)
dart_iso = read(os.path.join(APP, "engine", "audio_isolate.dart"))
check("[D2] isolate 在 vaiomode 与 vaiorestart 两处都读 monitorMirror",
      dart_iso.count("(m['monitorMirror'] as bool?) ?? false") >= 2,
      f"count={dart_iso.count(chr(39) + 'monitorMirror' + chr(39))}")
dart_modes = read(os.path.join(APP, "core", "state", "state_audio_modes.dart"))
body_setter = func_body(dart_modes, "setMonitorMirroring")
check("[D3] setMonitorMirroring 落盘后经 vaiorestart 热生效",
      "'cmd': 'vaiorestart'" in body_setter and
      "'monitorMirror': enabled" in body_setter)
check("[D4] vaiomode 载荷全点带 monitorMirror（模式/仍然启动/对账）",
      dart_modes.count("'monitorMirror': config.monitorMirroring") >= 3,
      f"count={dart_modes.count(chr(39) + 'monitorMirror' + chr(39))}")
panel = read(os.path.join(APP, "features", "settings", "panels",
                          "hardware_io_output.dart"))
check("[D5] 面板开关接真值（value: model.monitorMirroring）",
      "value: model.monitorMirroring" in panel and
      "onChanged: (v) => model.setMonitorMirroring(v)" in panel)
check("[D6] 虚拟端点说明收进 InfoBadge 气泡（非常显正文）",
      "InfoBadge(message: l.virtualSinkNotice)" in panel)
check("[D7] 面板不再引用 monitorMirroringHint（未实现整行已删）",
      "monitorMirroringHint" not in panel)
for arb in ("app_zh.arb", "app_en.arb", "app_ja.arb"):
    check(f"[D8] {arb} 已删 monitorMirroringHint 键",
          "monitorMirroringHint" not in
          read(os.path.join(APP, "l10n", arb)))

# ---------------------------------------------------------------- [B] C++ 单测
print("\n=== [B] vaio_mirror_feed_test.exe（喂流规划，驱动无关） ===")
if not os.path.exists(TEST_EXE):
    check("vaio_mirror_feed_test.exe exists", False, TEST_EXE)
else:
    check("vaio_mirror_feed_test.exe exists", True)
    r = subprocess.run([TEST_EXE], capture_output=True, text=True,
                       encoding="utf-8", errors="replace", timeout=120)
    lines = [ln for ln in r.stdout.splitlines() if ln.strip()]
    check("exit code 0", r.returncode == 0, f"rc={r.returncode}")
    data = None
    for ln in reversed(lines):
        s = ln.strip()
        if s.startswith("{"):
            try:
                data = json.loads(s)
                break
            except Exception:
                pass
    check("valid JSON result", isinstance(data, dict), str(data))
    if isinstance(data, dict):
        check("all C++ assertions ok", data.get("ok") is True and data.get("fail") == 0,
              json.dumps(data, ensure_ascii=False))
        check("at least 18 assertions ran", (data.get("pass") or 0) >= 18,
              f"pass={data.get('pass')}")

print()
if fails:
    print(f"MIRROR FEED FAILURES ({len(fails)}): {fails}")
    sys.exit(1)
print(f"MIRROR FEED ALL PASSED ({passes} checks)")
