"""smoke_dart_platform_quarantine.py — M4 Dart 平台隔离门禁（2026-10-29）。

验收标准（方案《跨平台基础框架与平台依赖剥离方案-2026-10-29》F2 + M4）：
  1. `Platform.is*` / `defaultTargetPlatform` 只允许出现在
     app/auradsp_app/lib/platform/platform_profile.dart；其余 lib/ 业务文件
     （排除 lib/l10n/gen 生成物）去注释后为零。
  2. 正向断言：PlatformProfile 的平台查询成员齐全（M4 前散落在 9 个文件的
     平台判断都有唯一归宿）。
  3. M4 结构断言：AudioOut 端口在 lib/engine/audio_out/audio_out.dart；
     WASAPI 实现在 audio_out_wasapi.dart 且由 createAudioOut 工厂分派；
     audio_isolate.dart 不再定义 WasapiOut（类型面已解耦）；
     旧的 audio_device.dart / audio_guid.dart 已删除。

反向自检：脚本用一段合成违规文本证明扫描器真的会判红（非恒真门禁）。
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
APP_LIB = os.path.join(ROOT, "app", "auradsp_app", "lib")
ENGINE_DIR = os.path.join(APP_LIB, "engine")
PROFILE_FILE = os.path.join(APP_LIB, "platform", "platform_profile.dart")

# 生成物目录（l10n/gen）不做平台判断，扫描时排除。
SKIP_DIRS = ("platform", os.path.join("l10n", "gen"))

FAIL = []


def check(name, cond, detail=""):
    print(("PASS  " if cond else "FAIL  ") + name + ("  " + detail if detail and not cond else ""))
    if not cond:
        FAIL.append(name)


PLATFORM_API = re.compile(r"\bPlatform\.is[A-Za-z]+\b|\bdefaultTargetPlatform\b")
CLASS_WASAPI_OUT = re.compile(r"\bclass\s+WasapiOut\b")

PROFILE_MEMBERS = (
    "static String get os",
    "static bool get supportsBridges",
    "static bool get supportsPlugins",
    "static bool get supportsLocalDevice",
    "static String get configDir",
    "static String pathKey(",
    "static String pathPlaceholder(",
    "static List<String> get engineLibraryCandidates",
    "static String bridgeLibraryName(",
    "static String bridgeEnvVar(",
    "static List<String> bridgeLibraryCandidates(",
)


def strip_comments(src):
    # 去掉 /* */ 与 // 注释，避免注释里的示例/背景文本误判
    src = re.sub(r"/\*.*?\*/", "", src, flags=re.DOTALL)
    return "\n".join(line.split("//")[0] for line in src.splitlines())


def read(fp):
    try:
        return open(fp, encoding="utf-8", errors="replace").read()
    except OSError:
        return ""


def is_skipped(rel_dir):
    for skip in SKIP_DIRS:
        if rel_dir == skip or rel_dir.startswith(skip + "/"):
            return True
    return False


def iter_lib_files():
    for dirpath, _dirnames, filenames in os.walk(APP_LIB):
        rel_dir = os.path.relpath(dirpath, APP_LIB).replace(os.sep, "/")
        if is_skipped(rel_dir):
            continue
        for fn in sorted(filenames):
            if fn.endswith(".dart"):
                yield os.path.join(dirpath, fn)


def quarantine_scan():
    hits = []
    for fp in iter_lib_files():
        rel = os.path.relpath(fp, APP_LIB).replace(os.sep, "/")
        for n, code in enumerate(strip_comments(read(fp)).splitlines(), 1):
            if PLATFORM_API.search(code):
                hits.append(f"{rel}:{n}")
    check("lib/ 业务文件零 Platform.is / defaultTargetPlatform（排除 platform/ 与 l10n/gen）",
          not hits, "; ".join(hits[:8]))
    check("唯一落点存在: platform/platform_profile.dart", os.path.isfile(PROFILE_FILE),
          PROFILE_FILE)


def profile_contract():
    src = read(PROFILE_FILE)
    code = strip_comments(src)
    missing = [m for m in PROFILE_MEMBERS if m not in code]
    check("PlatformProfile 成员齐全（os/能力位/configDir/pathKey/占位/库候选）",
          not missing, ", ".join(missing))


def m4_structure():
    port_fp = os.path.join(ENGINE_DIR, "audio_out", "audio_out.dart")
    wasapi_fp = os.path.join(ENGINE_DIR, "audio_out", "audio_out_wasapi.dart")
    isolate_fp = os.path.join(ENGINE_DIR, "audio_isolate.dart")

    check("AudioOut 端口存在: audio_out/audio_out.dart", os.path.isfile(port_fp), port_fp)
    if os.path.isfile(port_fp):
        code = strip_comments(read(port_fp))
        check("AudioOut 端口声明 write(frames)/currentPadding",
              "abstract class AudioOut" in code
              and "void write(" in code
              and "int currentPadding()" in code, "audio_out.dart")
    check("WASAPI 实现存在: audio_out/audio_out_wasapi.dart", os.path.isfile(wasapi_fp), wasapi_fp)
    if os.path.isfile(wasapi_fp):
        code = strip_comments(read(wasapi_fp))
        check("WasapiOut 实现 AudioOut 接口", "class WasapiOut implements AudioOut" in code,
              "audio_out_wasapi.dart")
        check("createAudioOut 工厂按能力位分派", "AudioOut? createAudioOut()" in code
              and "PlatformProfile.supportsLocalDevice" in code, "audio_out_wasapi.dart")

    check("audio_isolate 不再定义 WasapiOut", not CLASS_WASAPI_OUT.search(strip_comments(read(isolate_fp))),
          "engine/audio_isolate.dart")
    check("旧 part 文件已删除: audio_device.dart",
          not os.path.isfile(os.path.join(ENGINE_DIR, "audio_device.dart")),
          "engine/audio_device.dart")
    check("旧 part 文件已删除: audio_guid.dart",
          not os.path.isfile(os.path.join(ENGINE_DIR, "audio_guid.dart")),
          "engine/audio_guid.dart")


def negative_self_test():
    bad = "if (Platform.isWindows) {}\nfinal p = defaultTargetPlatform;\n"
    check("自检：扫描器能判红 Platform.is", bool(PLATFORM_API.search(bad)))
    check("自检：扫描器能判红 WasapiOut 定义",
          bool(CLASS_WASAPI_OUT.search("final class WasapiOut implements AudioOut {}")))


if __name__ == "__main__":
    quarantine_scan()
    profile_contract()
    m4_structure()
    negative_self_test()
    if FAIL:
        print(f"\n{len(FAIL)} FAIL: {FAIL}")
        sys.exit(1)
    print("\nALL PASS")
