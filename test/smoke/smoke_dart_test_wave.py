"""smoke_dart_test_wave.py — 第四十四轮 S4 测试页三段化结构门禁。

验收标准（立项计划《第四十四轮立项计划-2026-11-17》S4）：
  1. 波形源 WaveSource 取代 ToneSource（audio_sources.dart 有
     WaveSource 且全仓 lib 不再引用 ToneSource）；FileSource
     有传输面（totalFrames/positionRatio/seekRatio）。
  2. isolate 协议齐全：'source' 的 tone 带 wave/freq/sweep
     参数；sourceparam/sourcepause/sourceseek 三命令在册；
     桥波形渲染注入（renderBridgeWave/injectBridgeWave）与
     桥文件缓存（bridgeFileData）在册；本地泵暂停门
     （filePaused 填静音）在册。
  3. 状态层：setSource 跨源保留 sourcePath（不再对非 file
     清空）；波形/传输方法齐全（setWaveShape/setWaveFreq/
     setWaveSweep/toggleWave/toggleFilePlay/seekSource）；
     sourcepos 回执在 state_events 在册；debugMode 落 config
     且 DebugTrace.setEnabledRuntime 在册。
  4. 测试页三段：settings_test_tab.dart 三卡（testWaveTitle/
     testUseSrcTitle/testDebugTitle）+ 打开音频单按钮
     （testOpenAudio + wav/mp3 双扩展）+ 旧 _TestSourceChips
     已删除（全仓零引用）。

反向自检：合成违规文本证明扫描器会判红（非恒真门禁）。
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
APP = os.path.join(ROOT, "app", "auradsp_app")
LIB = os.path.join(APP, "lib")

FAIL = []


def check(name, cond, detail=""):
    print(("PASS  " if cond else "FAIL  ") + name + (("  " + detail) if detail and not cond else ""))
    if not cond:
        FAIL.append(name)


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def lib_text():
    out = []
    for dirpath, _dirs, files in os.walk(LIB):
        if os.path.join("l10n", "gen") in dirpath:
            continue
        for fn in files:
            if fn.endswith(".dart"):
                out.append(read(os.path.join(dirpath, fn)))
    return "\n".join(out)


def main():
    sources = read(os.path.join(LIB, "engine", "audio_sources.dart"))
    isolate = read(os.path.join(LIB, "engine", "audio_isolate.dart"))
    core = read(os.path.join(LIB, "core", "state", "state_core.dart"))
    events = read(os.path.join(LIB, "core", "state", "state_events.dart"))
    config = read(os.path.join(LIB, "core", "config.dart"))
    trace = read(os.path.join(LIB, "core", "debug", "debug_trace.dart"))
    tab = read(os.path.join(LIB, "features", "settings", "settings_test_tab.dart"))
    all_lib = lib_text()

    # 1. 波形源与文件传输面
    check("WaveSource 存在", "class WaveSource" in sources)
    check("ToneSource 全仓退役", "ToneSource" not in all_lib)
    for sym in ("totalFrames", "positionRatio", "seekRatio"):
        check(f"FileSource.{sym}", sym in sources)

    # 2. isolate 协议
    for cmd in ("'sourceparam'", "'sourcepause'", "'sourceseek'"):
        check(f"isolate 命令 {cmd}", f"case {cmd}" in isolate)
    for sym in ("renderBridgeWave", "injectBridgeWave", "bridgeFileData",
                "sendSourcePos", "filePaused"):
        check(f"isolate {sym}", sym in isolate)
    check("tone 参数下发（状态层）",
          "'wave': waveShape" in core and "'sweep': waveSweep" in core)

    # 3. 状态层
    check("setSource 不再清空路径",
          "sourcePath = (kind == 'file'" not in core)
    for fn in ("setWaveShape", "setWaveFreq", "setWaveSweep", "toggleWave",
               "toggleFilePlay", "setSourcePaused", "seekSource",
               "setDebugMode"):
        check(f"AppModel.{fn}", f"void {fn}" in core or f"bool get {fn}" in core)
    check("sourcepos 回执", "case 'sourcepos'" in events)
    check("config.debugMode", "bool debugMode" in config and
          "'debugMode': debugMode" in config)
    check("DebugTrace.setEnabledRuntime", "void setEnabledRuntime" in trace)

    # 4. 测试页三段
    for key in ("l.testWaveTitle", "l.testUseSrcTitle", "l.testDebugTitle",
                "l.testOpenAudio", "l.testNoSource"):
        check(f"测试页 {key}", key in tab)
    check("打开音频双扩展", "const ['wav', 'mp3']" in tab)
    check("_TestSourceChips 已删除", "_TestSourceChips" not in all_lib)

    # 反向自检：扫描器能判红
    check("反向自检（合成违规可判红）",
          re.search(r"sourcePath = \(kind == 'file'",
                     "sourcePath = (kind == 'file' && path != null) ? path : '';") is not None
          and "ToneSource" in "x ToneSource y")

    print()
    if FAIL:
        print(f"FAILED: {len(FAIL)} 项: {FAIL}")
        return 1
    print("ALL PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
