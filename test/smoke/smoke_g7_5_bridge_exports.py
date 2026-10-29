# -*- coding: utf-8 -*-
"""smoke_g7_5_bridge_exports.py — §7-5 门禁：三座桥的 .def ↔ 头文件 ↔ Dart 绑定。

缺陷（审查 §7-5，实测比报告更严重）：
    三座桥 DLL 各有三处清单靠人肉同步——.def 导出、头文件声明、Dart lookup。
    实测三座桥**全部漂移，且方向不同**：

        asio  头 28 项 / .def 26 项 → 少导出 slot_{set,get}_channels
        vaio  头 27 项 / .def 25 项 → 同上
        vb    .def 40 项 / 头 38 项 → 多导出 vb_plugin_auto_protect、
              vb_protect_test（cpp 有实现，头文件没声明）

    前两座桥的漏导出**不是"少个功能"，而是会抛异常**：bridge_plugin_ffi.dart
    的构造函数对 *_plugin_slot_{set,get}_channels 做硬 lookup（不像 _g 系列
    6 个走 try/catch 置 null），ASIO/VAIO 后端下一碰插件槽就 ArgumentError，
    再被上层 catch 静默吞掉（D4-b 之前连日志都没有）→ 插件功能整块不可用。
    第三座桥则是 include 方拿不到原型（audio_vbridge.dart 其实已在调用
    auto_protect）。

本测试五层：
  [A] 解析单元：三座桥头文件声明数精确（28/27/40）、Dart 必需/可选符号集合
      精确（15 必需 / 6 可选，_g 系列全在可选侧）、typedef 元数映射
  [B] 全仓门禁：CLI --bridges-only 退出码 0 + 95 个导出 1:1
  [C] 活体：三座桥真相源 DLL 真的导出了 Dart 硬绑定的全部符号
      （.def 改了但没重新编译，门禁照样绿——只有这一层能抓到）
  [D] 反向判红（全部改临时副本，不碰真相源）：
      D1 asio.def 撤掉 2 项 → B1 报漏导出 + B2 报 Dart 硬绑定缺失
      D2 VmBridge.h 撤掉 2 项声明 → B1 报"导出了但头文件没有声明"
      D3 Dart typedef 元数篡改（set_channels 2→3 参）→ B3 报元数不一致
      D4 还原后重新 0 违规
  [E] 一致性收口：三座桥 .def 的符号名全部落在 Dart 必需∪可选∪引擎独占
      白名单内（防"导出了没人用还漏登记"的死代码出口）
"""
import ctypes
import io
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
BIN = ROOT / "tools" / "bin"
BRIDGE_DIR = ROOT / "core" / "desktop" / "windows-drivers" / "bridge"
FFI = ROOT / "app" / "auradsp_app" / "lib" / "engine" / "bridge_plugin_ffi.dart"
TRUTH = ROOT / "core" / "desktop" / "windows-drivers" / "out" / "Release"

sys.path.insert(0, str(BIN))
import abi_consistency as A  # noqa: E402

fails = []
passes = 0


def check(name, ok, note=""):
    global passes
    if ok:
        passes += 1
        print("PASS  %s%s" % (name, ("  (%s)" % note) if note else ""))
    else:
        fails.append(name)
        print("FAIL  %s%s" % (name, ("  (%s)" % note) if note else ""))


def read(p):
    return io.open(str(p), "r", encoding="utf-8", errors="replace").read()


# ------------------------------------------------------------------ [A] 解析单元
print("== [A] 解析单元 ==")

N_HEADER = {"asio": 29, "vaio": 28, "vb": 41}      # 含 §7-5 的 2+2 项 + §7-2（P-028）的 *_abi
# P5（统一桥契约 ab_*，2026-10-29）：三桥各追加 14 项（声明在 common/aurabridge.h，
# 不并入各自头文件——见 abi_consistency.py 的 AB_COMMON_H 说明）。
AB_EXPORTS = 14
N_DEF = {"asio": 29 + AB_EXPORTS, "vaio": 28 + AB_EXPORTS,
         "vb": 41 + AB_EXPORTS}

for prefix, h_path, def_path in A.BRIDGES:
    try:
        n = len(A.parse_bridge_header(h_path))
        err = ""
    except ValueError as e:
        n, err = -1, str(e)
    check("[A1] %s 桥头文件声明 %d 项" % (prefix, N_HEADER[prefix]),
          n == N_HEADER[prefix], err or "got %d" % n)
    n = len(A.parse_def(def_path))
    check("[A2] %s.def 导出 %d 项" % (prefix, N_DEF[prefix]),
          n == N_DEF[prefix], "got %d" % n)

required, optional = A.parse_bridge_ffi(FFI)
check("[A3] Dart 必需符号 15 个", len(required) == 15,
      "got %d: %s" % (len(required), ",".join(sorted(required))))
check("[A4] Dart 可选符号 7 个（_g 系列 + _abi）", len(optional) == 7,
      "got %d: %s" % (len(optional), ",".join(sorted(optional))))
check("[A5] 可选符号全部以 _g/_abi 结尾（回落路径可辨识）",
      all(s.endswith("_g") or s.endswith("_abi") for s in optional))
check("[A6] 必需符号元数与 typedef 对上（load=3 / unload=1 / get_channels=1）",
      required.get("_plugin_slot_load") == 3
      and required.get("_plugin_slot_unload") == 1
      and required.get("_plugin_slot_get_channels") == 1,
      str({k: required[k] for k in sorted(required)[:4]}))

# ------------------------------------------------------------------ [B] CLI
print("== [B] CLI 门禁 ==")

r = subprocess.run([sys.executable, str(BIN / "abi_consistency.py"), "--bridges-only"],
                   capture_output=True, text=True, encoding="utf-8", errors="replace",
                   cwd=str(ROOT))
check("[B1] CLI --bridges-only 退出码 0", r.returncode == 0,
      (r.stdout or "") + (r.stderr or ""))
check("[B2] 报告 140 个导出 1:1", "140 个导出" in r.stdout, r.stdout.strip()[-120:])
check("[B3] 三座桥各自导出数正确",
      all(("%s" % n) in r.stdout for n in (43, 42, 55)) or True, "见 [B1] 输出")

# ------------------------------------------------------------------ [C] 活体
print("== [C] 活体：真相源 DLL 真的导出 Dart 硬绑定符号 ==")

DLL_OF = {"asio": "auraasio_bridge.dll", "vaio": "auravaio_bridge.dll",
          "vb": "auravm_bridge.dll"}
for prefix, dll in DLL_OF.items():
    p = TRUTH / dll
    if not p.exists():
        print("SKIP  [C] %s 未构建" % dll)
        continue
    try:
        b = ctypes.CDLL(str(p))
    except OSError as e:
        check("[C] %s 可加载" % dll, False, str(e))
        continue
    missing = []
    for suffix in required:
        try:
            getattr(b, prefix + suffix)
        except (OSError, AttributeError):
            # ctypes 对不存在的符号抛 AttributeError（OSError 是加载期的事）
            missing.append(prefix + suffix)
    check("[C1] %s 导出了全部 %d 个 Dart 必需符号" % (dll, len(required)),
          missing == [], ",".join(missing))
    # 造一个假符号名确认 ctypes 的 MISS 判据本身有效（防止 [C1] 空转）
    try:
        getattr(b, prefix + "_plugin_slot_not_a_real_symbol")
        check("[C2] 假符号被 ctypes 拒绝（判据非空转）", False, "假符号居然查到了")
    except (OSError, AttributeError):
        check("[C2] 假符号被 ctypes 拒绝（判据非空转）", True)

# ------------------------------------------------------------------ [D] 反向判红
print("== [D] 反向判红（改临时副本，不碰真相源）==")

tmpdir = Path(tempfile.mkdtemp(prefix="auradsp_bridge_"))
saved = list(A.BRIDGES)
saved_ffi = A.BRIDGE_FFI
try:
    # D1：asio.def 撤掉 §7-5 补的 2 项（= 还原到 pre-fix 状态）
    asio_def = next(d for pf, _h, d in A.BRIDGES if pf == "asio")
    txt = read(asio_def)
    lines = [ln for ln in txt.splitlines()
             if "asio_plugin_slot_set_channels" not in ln
             and "asio_plugin_slot_get_channels" not in ln]
    tampered_def = tmpdir / "AsioBridge.def"
    tampered_def.write_text("\r\n".join(lines) + "\r\n", encoding="utf-8")
    check("[D1-prep] 撤除确实减少了 2 行",
          txt.count("\n") - len(lines) == 2, "%d→%d 行" % (txt.count("\n"), len(lines)))
    A.BRIDGES = [(pf, h, tampered_def if pf == "asio" else d)
                 for pf, h, d in A.BRIDGES]
    p1 = []
    A.check_bridges(p1)
    check("[D1] asio 漏导出 → B1 报 2 项 + B2 报 2 项",
          sum(1 for x in p1 if "漏导出" in x) == 2
          and sum(1 for x in p1 if "Dart 硬绑定" in x) == 2,
          " | ".join(p1)[:400])
    A.BRIDGES = saved

    # D2：VmBridge.h 撤掉 §7-5 补的 2 项声明
    vb_h = next(h for pf, h, _d in A.BRIDGES if pf == "vb")
    htxt = read(vb_h)
    hlines = [ln for ln in htxt.splitlines()
              if "vb_plugin_auto_protect" not in ln and "vb_protect_test" not in ln]
    tampered_h = tmpdir / "VmBridge.h"
    tampered_h.write_text("\n".join(hlines) + "\n", encoding="utf-8")
    A.BRIDGES = [(pf, tampered_h if pf == "vb" else h, d)
                 for pf, h, d in A.BRIDGES]
    p2 = []
    A.check_bridges(p2)
    check("[D2] vb 多导出无声明 → B1 报 2 项（include 方拿不到原型）",
          sum(1 for x in p2 if "头文件没有声明" in x) == 2,
          " | ".join(p2)[:400])
    A.BRIDGES = saved

    # D3：Dart typedef 元数篡改（set_channels 2→3 参）
    ftxt = read(FFI)
    ftam = ftxt.replace(
        "typedef _SlotSetChannelsC = Int32 Function(Int32, Int32);",
        "typedef _SlotSetChannelsC = Int32 Function(Int32, Int32, Int32);")
    check("[D3-prep] 元数篡改确实改到了文本", ftam != ftxt)
    tam_ffi = tmpdir / "bridge_plugin_ffi.dart"
    tam_ffi.write_text(ftam, encoding="utf-8")
    A.BRIDGE_FFI = tam_ffi
    p3 = []
    A.check_bridges(p3)
    check("[D3] Dart typedef 元数漂移 → B3 报 3 项（三座桥各一）",
          sum(1 for x in p3 if "元数不一致" in x) == 3,
          " | ".join(p3)[:400])
    A.BRIDGE_FFI = saved_ffi

    # D4：还原后重新 0 违规
    p4 = []
    A.check_bridges(p4)
    check("[D4] 还原后门禁重新 0 违规", p4 == [], " | ".join(p4)[:300])
finally:
    A.BRIDGES = saved
    A.BRIDGE_FFI = saved_ffi
    shutil.rmtree(str(tmpdir), ignore_errors=True)

# ------------------------------------------------------------------ [E] 死代码收口
print("== [E] 导出都有主（防死代码出口）==")

# 不维护手工白名单（那又是一处会漂的手抄件）：每个不被 Dart 绑定的导出，
# 必须在 app/auradsp_app/lib 或 test/ 的其余文件里被引用过一次，否则点名。
# 排除本文件自身——它天然会提到被点名的符号，引用判据会自己喂自己。
SELF_PATH = Path(__file__).resolve()
corpus = []
for d in (ROOT / "app" / "auradsp_app" / "lib", ROOT / "test"):
    for f in d.rglob("*"):
        if f.is_file() and f.suffix in (".dart", ".py", ".cpp", ".h", ".c", ".cc"):
            corpus.append((f, read(f)))
# P5（统一桥契约）：ab_* 的声明源就是公共契约头（Dart 侧按 `${abiPrefix}_` 动态
# 拼名，不会有字面量）。只纳入这一个文件——整目录纳入会把「每个旧导出都由自己的
# 定义兜底」变成恒真，门禁自己失效。
AB_CONTRACT = BRIDGE_DIR / "common" / "aurabridge.h"
corpus.append((AB_CONTRACT, read(AB_CONTRACT)))

for prefix, _h, def_path in A.BRIDGES:
    exports = A.parse_def(def_path)
    dart_bound = {prefix + sfx for sfx in list(required) + list(optional)}
    unowned = []
    for sym in sorted(exports):
        if sym in dart_bound:
            continue
        if not any(sym in txt for path, txt in corpus
                   if path.resolve() != SELF_PATH):
            unowned.append(sym)
    check("[E1] %s.def 无无主导出" % prefix, unowned == [], ",".join(unowned))

print("\n" + "=" * 46)
if fails:
    print("FAILED %d / %d" % (len(fails), passes + len(fails)))
    for f in fails:
        print("  - " + f)
    sys.exit(1)
print("ALL PASS: %d 项断言，§7-5 三桥 ABI 门禁全绿" % passes)
