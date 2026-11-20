"""smoke_audio_modes_linux.py — Linux 音频模式语义门禁（ADR-012 §4.3，2026-11-20 补件）。

ADR-012 §4.3 原列此门禁但从未实现。2026-11-20 复核时的实际状态：
  - 断言 (a)「三模式 id 均能由 composeMode() 产出且语义不落到 Windows id」
    已由 Dart 单测 `app/auradsp_app/test/audio_modes_test.dart` 覆盖
    （ADR-012 D-5 用例，Linux 三模式 options/normalize/compose）；
  - 断言 (b)「设置页不出现 Windows 专有选项」**实现已有、零测试**——
    `settings_audio_tab.dart` 以 `PlatformProfile.isLinux` 分支渲染
    `_linuxModeCard`，但该分支在 Windows 开发机上无法 widget 测试
    （`PlatformProfile.isLinux` 读 `Platform.isLinux`，不可注入），
    故只能源码级守护。

本脚本把 (a)(b) 两条断言都钉在源码层，并钉住「Dart 侧覆盖仍在位」，
使任一侧被回退都会红：
  A. 核心（lib/core/audio_modes.dart）
     - linux 模式集恰为 system/virtual/driver；defaults['linux']='system'；
     - optionsFor 有 linux 分支；normalize 以 optionsFor 为准；
     - composeMode 有 os 形参且有 linux/macos 直通分支；
     - 该分支只产出候选 id 或平台默认，**不含** Windows 四 id 字面量。
  B. 设置页（lib/features/settings/settings_audio_tab.dart）
     - 范式卡由 PlatformProfile.isLinux 分支；Linux 走 _linuxModeCard，
       非 Linux 走 ADR-009 两范式 SectionCard；
     - _linuxModeCard 内含 system/virtual/driver 三 id，
       **不含** Windows/Android 专有 id 字面量。
  C. Dart 侧覆盖在位（audio_modes_test.dart 的 Linux 三模式用例）。

纯源码扫描，任意平台可跑（runner 标记 PLATFORM_ANY）。
反向自检：合成违规文本必须判红（非恒真门禁）。
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
APP = os.path.join(ROOT, "app", "auradsp_app")
MODES = os.path.join(APP, "lib", "core", "audio_modes.dart")
SETTINGS = os.path.join(APP, "lib", "features", "settings", "settings_audio_tab.dart")
MODES_TEST = os.path.join(APP, "test", "audio_modes_test.dart")

FAIL = []


def check(name, cond, detail=""):
    print(("PASS  " if cond else "FAIL  ") + name + ("  " + detail if detail and not cond else ""))
    if not cond:
        FAIL.append(name)


def read(path):
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        return f.read()


def mask_code(text):
    """把字符串字面量与注释替换为等长空格（保留换行），用于花括号配平。

    Dart 源码里 '{' 既可能是块起始也可能出现在字符串插值/注释中，
    直接配平会错位。本函数给出与原串等长的「纯代码」视图。
    """
    out = list(text)
    i = 0
    n = len(text)
    while i < n:
        c = text[i]
        if c == "/" and i + 1 < n and text[i + 1] == "/":
            j = text.find("\n", i)
            j = n if j < 0 else j
            for k in range(i, j):
                out[k] = " "
            i = j
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "*":
            j = text.find("*/", i + 2)
            j = n if j < 0 else j + 2
            for k in range(i, j):
                if out[k] != "\n":
                    out[k] = " "
            i = j
            continue
        if c in "'\"":
            # Dart 字符串：支持 r'' / ''' / """ 前缀由前一字符体现
            quote = c
            j = i + 1
            while j < n:
                if text[j] == "\\":
                    j += 2
                    continue
                if text[j] == quote:
                    j += 1
                    break
                j += 1
            for k in range(i, min(j, n)):
                if out[k] != "\n":
                    out[k] = " "
            i = j
            continue
        i += 1
    return "".join(out)


def mask_comments(text):
    """仅把注释替换为等长空格（保留字符串字面量）。

    用于结构匹配：像 `case 'linux':` / `os == 'linux'` 这类判据本身
    就是字符串字面量，必须保留；只屏蔽注释以免注释里的同形文本
    造成假命中。
    """
    out = list(text)
    i = 0
    n = len(text)
    while i < n:
        c = text[i]
        if c == "/" and i + 1 < n and text[i + 1] == "/":
            j = text.find("\n", i)
            j = n if j < 0 else j
            for k in range(i, j):
                out[k] = " "
            i = j
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "*":
            j = text.find("*/", i + 2)
            j = n if j < 0 else j + 2
            for k in range(i, j):
                if out[k] != "\n":
                    out[k] = " "
            i = j
            continue
        i += 1
    return "".join(out)


def extract_block(text, masked, marker):
    """取 marker 之后第一个平衡花括号块的原文切片。"""
    idx = text.find(marker)
    if idx < 0:
        return None
    bidx = masked.find("{", idx)
    if bidx < 0:
        return None
    depth = 0
    for j in range(bidx, len(masked)):
        if masked[j] == "{":
            depth += 1
        elif masked[j] == "}":
            depth -= 1
            if depth == 0:
                return text[bidx:j + 1]
    return None


def quoted_literals(text):
    """文本中出现的单/双引号字面量集合（不含插值内部）。"""
    return set(re.findall(r"'([^'\\\n]*)'", text)) | set(re.findall(r'"([^"\\\n]*)"', text))


WINDOWS_ONLY_IDS = {"vaio", "asio", "sysapo", "vbcallback", "voicemeeter_api"}
ANDROID_ONLY_IDS = {"root", "rootless"}
LINUX_IDS = {"system", "virtual", "driver"}


def main():
    modes = read(MODES)
    modes_masked = mask_code(modes)
    modes_code = mask_comments(modes)
    settings = read(SETTINGS)
    settings_masked = mask_code(settings)
    settings_code = mask_comments(settings)

    # ---------------- A. 核心 ----------------
    m = re.search(r"static const List<String> linux = \[([^\]]*)\];", modes)
    linux_set = set(quoted_literals(m.group(1))) if m else set()
    check("audio_modes.dart 的 linux 模式集恰为 system/virtual/driver",
          linux_set == LINUX_IDS, str(sorted(linux_set)))

    check("defaults['linux'] == 'system'",
          bool(re.search(r"'linux'\s*:\s*'system'", modes)))

    check("optionsFor 含 linux 分支（返回 linux 集）",
          bool(re.search(r"case\s+'linux'\s*:\s*return\s+linux\s*;", modes_code)))

    check("normalize 以 optionsFor 为准（平台外 id 必回落默认）",
          bool(re.search(r"final\s+opts\s*=\s*optionsFor\s*\(", modes_masked))
          and bool(re.search(r"if\s*\(id\s*!=\s*null\s*&&\s*opts\.contains\(id\)\)", modes_masked)))

    compose_sig = re.search(r"static String composeMode\s*\(\s*\{(.*?)\}\s*\)", modes_masked, re.S)
    check("composeMode 签名含 os 形参",
          bool(compose_sig) and bool(re.search(r"\bos\b", compose_sig.group(1))))

    linux_branch = extract_block(
        modes, modes_masked,
        "if (os == 'linux' || os == 'macos')") or ""
    check("composeMode 含 linux/macos 直通分支",
          "os == 'linux'" in modes_code and bool(linux_branch))
    branch_lits = quoted_literals(linux_branch)
    check("composeMode 的 linux 分支不产 Windows 四 id",
          not (branch_lits & WINDOWS_ONLY_IDS),
          str(sorted(branch_lits & WINDOWS_ONLY_IDS)))
    check("composeMode 的 linux 分支以 optionsFor(os) 判定候选合法性",
          "optionsFor(os!)" in linux_branch.replace(" ", "")
          or "optionsFor(os!)" in linux_branch)

    # ---------------- B. 设置页 OS 门控 ----------------
    gate_re = re.compile(
        r"if\s*\(\s*PlatformProfile\.isLinux\s*\)\s*"
        r"_linuxModeCard\(context,\s*model\)\s*else\s*SectionCard\(",
        re.S)
    check("设置页范式卡由 PlatformProfile.isLinux 分支（Linux 走 _linuxModeCard）",
          bool(gate_re.search(settings_code)))
    check("非 Linux 分支为 ADR-009 两范式 SectionCard",
          "audioParadigm" in settings)

    card = extract_block(settings, settings_masked, "Widget _linuxModeCard(") or ""
    check("_linuxModeCard 函数体可解析", bool(card))
    card_lits = quoted_literals(card)
    check("_linuxModeCard 含 system/virtual/driver 三 id",
          LINUX_IDS <= card_lits, str(sorted(LINUX_IDS - card_lits)))
    check("_linuxModeCard 不含 Windows 专有 id",
          not (card_lits & WINDOWS_ONLY_IDS),
          str(sorted(card_lits & WINDOWS_ONLY_IDS)))
    check("_linuxModeCard 不含 Android 专有 id",
          not (card_lits & ANDROID_ONLY_IDS),
          str(sorted(card_lits & ANDROID_ONLY_IDS)))

    # ---------------- C. Dart 侧覆盖在位 ----------------
    if os.path.isfile(MODES_TEST):
        mt = read(MODES_TEST)
        check("audio_modes_test.dart 覆盖 linux 三模式 optionsFor",
              "optionsFor('linux')" in mt)
        check("audio_modes_test.dart 覆盖 composeMode(os=linux) 产出三 id",
              bool(re.search(r"os:\s*'linux'", mt)))
        check("audio_modes_test.dart 覆盖 Windows id 在 linux 下回落",
              bool(re.search(r"normalize\('vaio',\s*'linux'\)", mt)))
    else:
        check("audio_modes_test.dart 存在", False, MODES_TEST)

    # ---------------- D. 反向自检 ----------------
    # D1：Linux 卡里混入 'vaio' 必须判红。
    fake_card = "AuraSegment('system', x), AuraSegment('vaio', y)"
    check("反向自检：Linux 卡混入 Windows id 必判红",
          bool(quoted_literals(fake_card) & WINDOWS_ONLY_IDS))
    # D2：composeMode 去掉 linux 分支必须判红。
    no_linux = "static String composeMode({required String category}) { return 'vaio'; }"
    check("反向自检：composeMode 失去 linux 分支必判红",
          "os == 'linux'" not in mask_code(no_linux))
    # D3：设置页门控被抹掉必须判红。
    no_gate = "if (false) _linuxModeCard(context, model) else SectionCard("
    check("反向自检：设置页 isLinux 门控消失必判红",
          not bool(gate_re.search(mask_comments(no_gate))))

    print("----")
    if FAIL:
        print("FAIL  smoke_audio_modes_linux: %d 项未过" % len(FAIL))
        return 1
    print("PASS  smoke_audio_modes_linux: 全部通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
