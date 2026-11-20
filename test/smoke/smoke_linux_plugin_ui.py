"""smoke_linux_plugin_ui.py — Linux 插件能力边界门禁（ADR-012 §4.3，2026-11-20 补件）。

**本门禁的原口径已被推翻，此处按现行边界重写。**

ADR-012 §4.3 原列：「Linux 上插件目录 UI 不展示（plugin_dirs_desktop.dart
的 Linux 分支被条件关闭）」，对应 D-7「首期只做插件消费者并隐藏 Linux
插件目录 UI」。

该口径在 **2026-11-02 被 owner 的后续立项推翻**：
《Linux插件宿主实施方案-2026-11-02》已立项（owner 裁定），范围为
「VST3 + CLAP 与 Windows 同进度」，其执行记录明写：
  「supportsPlugins 放开 Linux；plugins_page 的扫描目录区**解除 D-7 隐藏**
   （页面不可用占位仍由能力把关）」。
事实侧对应：
  - `core/desktop/linux/CMakeLists.txt` 的 `AURADSP_ENABLE_PLUGINS` 默认 ON；
  - `PlatformProfile.supportsPlugins` = `Platform.isWindows || Platform.isLinux`；
  - `plugins_page.dart` 无条件构造 `PluginScanDirsSection`（注释写明
    「一期 D-7 的隐藏条件随之解除」）。

故按原口径建门禁会**把已被推翻的行为固化**、且与当前代码相反（必红）。
此处改为钉住**现行边界的真实不变量**：
  A. Linux 插件宿主已转正：能力集 linuxInProcess（进程内）存在且
     supported/canScan/canMount 为真；编辑器能力按 X 显示（DISPLAY）
     如实区分；运行时枚举含 inProcess；Linux 构建默认启用插件子系统；
     PlatformProfile.supportsPlugins 含 Linux。
  B. 插件目录区的可见性**由能力把关，不按平台硬编码**：构造点附近
     不得出现 isLinux / Platform.isWindows 之类的硬编码平台守卫；
     Linux 目录发现已恢复（不返回空）且统一经 PluginScanDirs.discoverFrom
     过滤（只收真实存在的目录）。
  C. D-7 **仍然成立**的那一半：AuraDSP 自身不导出 LV2/CLAP 插件——
     能力集无导出能力字段；Linux 构建不产 LV2/CLAP 插件导出目标。

纯源码扫描，任意平台可跑（runner 标记 PLATFORM_ANY）。
反向自检：合成违规文本必须判红（非恒真门禁）。
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
APP = os.path.join(ROOT, "app", "auradsp_app")
LINUX_CMAKE = os.path.join(ROOT, "core", "desktop", "linux", "CMakeLists.txt")
PORT_HOST = os.path.join(APP, "lib", "platform", "port", "plugin_host.dart")
HOST_LINUX = os.path.join(APP, "lib", "platform", "plugins", "plugin_host_linux.dart")
DIRS_DESKTOP = os.path.join(APP, "lib", "platform", "plugins", "plugin_dirs_desktop.dart")
PLUGINS_PAGE = os.path.join(APP, "lib", "features", "plugins_page.dart")
PROFILE = os.path.join(APP, "lib", "platform", "platform_profile.dart")

FAIL = []


def check(name, cond, detail=""):
    print(("PASS  " if cond else "FAIL  ") + name + ("  " + detail if detail and not cond else ""))
    if not cond:
        FAIL.append(name)


def read(path):
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        return f.read()


def mask_comments(text):
    """仅屏蔽注释（保留字符串字面量），用于结构匹配。"""
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


def mask_code(text):
    """屏蔽字符串字面量与注释（等长），用于花括号配平。"""
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


def extract_paren(text, masked, marker):
    """取 marker 之后第一个平衡**圆括号**块的原文切片。

    Dart 的具名参数构造调用（PluginHostCapabilities(...)）用圆括号，
    不是花括号——能力集的字段要靠它取。
    """
    idx = text.find(marker)
    if idx < 0:
        return None
    pidx = masked.find("(", idx)
    if pidx < 0:
        return None
    depth = 0
    for j in range(pidx, len(masked)):
        if masked[j] == "(":
            depth += 1
        elif masked[j] == ")":
            depth -= 1
            if depth == 0:
                return text[pidx:j + 1]
    return None


def cap_field(block, name):
    """从能力集构造块里取字段布尔值。"""
    m = re.search(name + r"\s*:\s*(true|false)", block)
    return m.group(1) if m else None


def main():
    for p in (LINUX_CMAKE, PORT_HOST, HOST_LINUX, DIRS_DESKTOP, PLUGINS_PAGE, PROFILE):
        if not os.path.isfile(p):
            check("文件存在：%s" % os.path.relpath(p, ROOT).replace(os.sep, "/"), False)
    if FAIL:
        print("----")
        print("FAIL  smoke_linux_plugin_ui: %d 项未过（文件缺失）" % len(FAIL))
        return 1

    cmake = read(LINUX_CMAKE)
    port = read(PORT_HOST)
    port_code = mask_comments(port)
    port_masked = mask_code(port)
    host_linux = read(HOST_LINUX)
    dirs = read(DIRS_DESKTOP)
    dirs_code = mask_comments(dirs)
    page = read(PLUGINS_PAGE)
    page_code = mask_comments(page)
    profile = read(PROFILE)
    profile_code = mask_comments(profile)

    # ---------------- A. Linux 插件宿主已转正 ----------------
    check("PluginHostRuntime 含 inProcess（Linux 进程内宿主运行时）",
          bool(re.search(r"inProcess\b", port_code)))

    cap = extract_paren(port, port_masked, "linuxInProcess =") or ""
    check("能力集 linuxInProcess 存在", bool(cap))
    check("linuxInProcess.supported 为 true", cap_field(cap, "supported") == "true",
          str(cap_field(cap, "supported")))
    check("linuxInProcess.canScan 为 true", cap_field(cap, "canScan") == "true",
          str(cap_field(cap, "canScan")))
    check("linuxInProcess.canMount 为 true", cap_field(cap, "canMount") == "true",
          str(cap_field(cap, "canMount")))

    cap_editor = extract_paren(port, port_masked, "linuxInProcessWithEditor =") or ""
    check("能力集 linuxInProcessWithEditor 存在（X 显示下可开编辑器）",
          bool(cap_editor))
    check("linuxInProcessWithEditor.canEdit 为 true",
          cap_field(cap_editor, "canEdit") == "true",
          str(cap_field(cap_editor, "canEdit")))

    check("plugin_host_linux.dart 按 DISPLAY 如实区分编辑器能力",
          "DISPLAY" in host_linux
          and "linuxInProcessWithEditor" in host_linux
          and "linuxInProcess" in host_linux)

    opt = re.search(r"option\(AURADSP_ENABLE_PLUGINS\s+\"[^\"]*\"\s+(ON|OFF)\)", cmake)
    check("Linux 构建默认启用插件子系统（AURADSP_ENABLE_PLUGINS=ON）",
          bool(opt) and opt.group(1) == "ON",
          "实际=%s" % (opt.group(1) if opt else "未找到 option"))

    sup = re.search(r"static bool get supportsPlugins\s*=>\s*([^;]+);", profile_code)
    check("PlatformProfile.supportsPlugins 含 Linux",
          bool(sup) and "Platform.isLinux" in sup.group(1),
          sup.group(1) if sup else "未找到 supportsPlugins")

    # ---------------- B. 目录区可见性由能力把关 ----------------
    # 构造点前后窗口内不得有硬编码平台守卫。
    idx = page.find("PluginScanDirsSection(")
    check("plugins_page.dart 构造 PluginScanDirsSection", idx > 0)
    if idx > 0:
        lines = page.split("\n")
        lineno = page[:idx].count("\n")
        window = "\n".join(lines[max(0, lineno - 14):lineno + 5])
        hard = [g for g in ("isLinux", "isWindows", "isAndroid", "isMacOS")
                if re.search(r"\b" + g + r"\b", window)]
        check("目录区构造点无硬编码平台守卫（可见性由能力把关）",
              not hard, str(hard))

    # Linux 目录发现已恢复（不返回空），且统一经 discoverFrom 过滤。
    linux_branch = extract_block(dirs, mask_code(dirs), "if (os == 'macos')") or ""
    check("plugin_dirs_desktop.dart 的 Linux 目录发现已恢复（非空返回）",
          bool(linux_branch) and "const []" not in linux_branch)
    check("Linux 目录发现统一经 PluginScanDirs.discoverFrom 过滤（只收真实存在）",
          "PluginScanDirs.discoverFrom" in dirs)
    for d in ("/usr/lib/vst3", "/usr/local/lib/clap"):
        check("Linux 标准插件目录含 %s" % d, d in dirs)

    # ---------------- C. D-7 仍成立：不导出自身插件 ----------------
    cap_struct = extract_block(port, port_masked, "class PluginHostCapabilities") or ""
    check("能力集无「导出插件」能力字段（D-7：不导出 LV2/CLAP）",
          "export" not in cap_struct.lower(),
          cap_struct[:120])
    targets = re.findall(r"add_(?:library|executable)\s*\(\s*([A-Za-z0-9_]+)", cmake)
    bad_targets = [t for t in targets if "lv2" in t.lower() or "clap" in t.lower()]
    check("Linux 构建不产 LV2/CLAP 插件导出目标",
          not bad_targets, str(bad_targets))

    # ---------------- D. 反向自检 ----------------
    fake_cap = ("static const PluginHostCapabilities linuxInProcess = "
                "PluginHostCapabilities(supported: true, canScan: false, "
                "canMount: true, canEdit: false, runtime: PluginHostRuntime.inProcess);")
    check("反向自检：canScan=false 的能力集必判红",
          cap_field(fake_cap, "canScan") != "true")
    fake_export = ("class PluginHostCapabilities { final bool canExport; "
                   "const PluginHostCapabilities({required this.canExport}); }")
    check("反向自检：出现导出能力字段必判红", "export" in fake_export.lower())
    fake_page = ("if (PlatformProfile.isLinux)\n  PluginScanDirsSection(model: m);")
    check("反向自检：目录区被 isLinux 硬编码守卫必判红",
          bool(re.search(r"\bisLinux\b", fake_page)))
    check("反向自检：Linux 构建把插件子系统关掉必判红",
          bool(re.search(r"option\(AURADSP_ENABLE_PLUGINS\s+\"[^\"]*\"\s+OFF\)",
                         cmake)) is False)

    print("----")
    if FAIL:
        print("FAIL  smoke_linux_plugin_ui: %d 项未过" % len(FAIL))
        return 1
    print("PASS  smoke_linux_plugin_ui: 全部通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
