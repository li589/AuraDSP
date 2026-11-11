# -*- coding: utf-8 -*-
"""smoke_eel_manual.py — EEL2 手册与 VM 函数表防漂移门禁。

缺陷（2026-11-08 全量比对实锤，91 条手册 ↔ nseel-compiler.c fnTable1）：
    App 内置 EEL 手册（eel_manual_registry.dart）是用户写 LiveProg 脚本的
    唯一文档，但它与引擎 VM 的真实函数表多处漂移：

    - freembuf 条目对应的函数根本不存在（引擎实测编译报 Syntax error）；
    - 多个条目把复合名写成简写（fractionalDelayLineInit / Process），
      用户照抄函数名无法编译；
    - 一批扩展函数签名参数个数错误（mldivide 写 6 实为 8、quadprog
      写 9 实为 12、det 写 2 实为 3、FIRProcess 写成块处理实为逐样本
      3 参……），照手册写的脚本轻则编译失败、重则参数错位静默算错；
    - 宿主环境变量 num_ch / nch / dev_srate（P-038）手册完全缺失；
    - spl 条目未说明脚本只处理前 2 声道、第 3 声道起直通。

本门禁把比对结果冻结为期望表，防再次漂移：
  [A] 手册中出现的每个函数名必须存在于 VM fnTable1（或非函数白名单）；
  [B] 定长函数的签名参数个数必须与期望表一致（期望 = fnTable1 注册数
      或实现体 parms[] 下标核实数，逐个注明来源类别）；
  [C] 宿主环境条目必须齐备（num_ch / nch、dev_srate、srate、spl0/spl1），
      且不存在的 freembuf 不得回潮；
  [D] 反向验证：内存中篡改一处签名个数，判定逻辑必须判红（防空转）。
"""
import io
import os
import re
import sys

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")
sys.stderr = io.TextIOWrapper(sys.stderr.buffer, encoding="utf-8", errors="replace")

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
COMPILER_C = os.path.join(REPO, "engine", "legacy", "jdsp", "Effects", "eel2", "nseel-compiler.c")
MANUAL_DART = os.path.join(
    REPO, "app", "auradsp_app", "lib", "core", "liveprog", "eel_manual_registry.dart")

# 非函数条目（段标记 / 语言构造 / 寄存器 / 常量），不查函数表。
NON_FUNCTION = {
    "@init", "@sample", "@slider", "@block", "function", "while", "loop",
    "spl0", "spl1", "srate", "num_ch", "nch", "dev_srate",
    "slider1..slider8", "$PI", "$E",
}

# 期望参数个数。来源：未标记者 = fnTable1 注册定长数；impl = 实现体
# parms[] 下标核实（VARPARM 注册但实现定长）；var = 真变长/可选参，
# 只查存在性不查个数（Conv1DInit 3/4/6 三形态、IIRBandSplitterInit
# 3..9、wav 族 4+每声道一指针、sprintf/match 格式化变长、time 系列
# 编译器容忍 0/1 参两形态——2026-11-08 引擎实测）。
EXPECTED = {
    "sin": 1, "cos": 1, "tan": 1, "asin": 1, "acos": 1, "atan": 1,
    "atan2": 2, "sinh": 1, "cosh": 1, "tanh": 1, "asinh": 1, "acosh": 1,
    "atanh": 1, "sqrt": 1, "invsqrt": 1, "invsqrtFast": 1, "sqr": 1,
    "pow": 2, "exp": 1, "log": 1, "log10": 1, "abs": 1, "sign": 1,
    "min": 2, "max": 2, "floor": 1, "ceil": 1, "round": 1, "hypot": 2,
    "rand": 1, "freembuf": None,  # 不存在于 VM，见 [C]
    "memcpy": 3, "memset": 3, "circshift": 3,
    "maxVec": 2, "minVec": 2, "meanVec": 2, "medianVec": 2,
    "fft": 2, "ifft": 2, "fft_real": 2, "ifft_real": 2,
    "fft_permute": 2, "fft_ipermute": 2,
    "stftInit": "impl:2", "stftForward": "impl:3", "stftBackward": "impl:3",
    "getCosineWindows": 3,
    "InitPinkNoise": "impl:2", "GeneratePinkNoise": "impl:2",
    "FIRInit": 2, "FIRProcess": 3,
    "fractionalDelayLineInit": 2, "fractionalDelayLineProcess": 2,
    "fractionalDelayLineClear": 1, "fractionalDelayLineSetDelay": 2,
    "IIRBandSplitterInit": "var", "IIRBandSplitterProcess": "var",
    "IIRBandSplitterClearState": 1,
    "InitPolyphaseFilterbank": "var",
    "PolyphaseFilterbankAnalysisStereo": "impl:7",
    "PolyphaseFilterbankSynthesisStereo": "impl:6",
    "Conv1DInit": "var", "Conv1DProcess": "impl:3",
    "firls": 7,
    "mldivide": "impl:8", "mrdivide": "impl:8",
    "inv": "impl:4", "cholesky": "impl:4",
    "pinv_svd": "impl:5", "pinv_fast": "impl:5",
    "linspace": 4, "tf2sos": "impl:6", "zp2sos": "impl:8",
    "det": 3, "rank": 3, "transpose": 4,
    "quadprog": "impl:12", "lsqlin": "impl:13",
    "roots": "impl:5", "cplxpair": "impl:5",
    "unwrap": "impl:3", "peakFinder": "impl:5",
    "decodeWavFromFile": "var", "decodeFLACFromFile": "var",
    "decodeWavFromMemory": "var", "writeWavToFile": "var",
    "writeWavToBase64String": "var",
    "strlen": 1, "strcmp": 2, "stricmp": 2,
    "sprintf": "var", "printf": "var",
    "time": "var", "time_precise": "var",
    "base64_encode": 3, "base64_decode": 3,
    "eval": "var", "evalFile": "var", "breakpoint": 1,
    "expint": 1, "expintFast": 1,
    "vectorizeAssignScalar": 3, "vectorizeAdd": 4, "vectorizeMinus": 4,
    "vectorizeMultiply": 4, "vectorizeDivide": 4,
    "lerpAt": 4, "convolve_c": 3, "resetSysMemRegion": "var",
    "getAsymmetricCosine": "impl:5", "stftGetWindowPower": "impl:2",
    "iirHilbertInit": "impl:3", "iirHilbertProcess": 3,
    "movingMinMaxInit": 2, "movingMinMaxProcess": 3,
    "movingMedianInit": 2, "movingMedianProcess": 2,
    "match": "var", "matchi": "var",
    "ThreadCreate": 1, "ThreadJoin": 1,
    "ThreadMutexLock": 1, "ThreadMutexUnlock": 1, "sleep": 1,
}


def vm_function_names():
    src = open(COMPILER_C, encoding="utf-8", errors="replace").read()
    m = re.search(r"fnTable1\[\] = \{(.*?)\n\};", src, re.S)
    assert m, "fnTable1 not found in nseel-compiler.c"
    return set(re.findall(r'\{\s*"([A-Za-z0-9_]+)"\s*,', m.group(1)))


def manual_entries():
    dart = open(MANUAL_DART, encoding="utf-8").read()
    return re.findall(
        r"name: '([^']*)',\s*\n\s*category: EelManualCategory\.(\w+),\s*\n\s*signature: '([^']*)'",
        dart)


def signature_counts(sig):
    """签名中每个函数的参数个数（含 '...' / '[, ...]' 的标 None=变长）。"""
    out = {}
    for part in sig.split(";"):
        fm = re.match(r"\s*([A-Za-z0-9_]+)\(([^)]*)\)", part.strip())
        if not fm:
            continue
        args = fm.group(2).strip()
        if "..." in args or "[," in args:
            out[fm.group(1)] = None
        else:
            out[fm.group(1)] = 0 if not args else args.count(",") + 1
    return out


def check(vm_names, entries):
    problems = []
    seen = set()
    for name, _cat, sig in entries:
        counts = signature_counts(sig)
        for fn in [x.strip() for x in name.split("/")]:
            fn = fn.strip().replace("\\", "")  # Dart 字面量里的 \$PI 等
            if fn in NON_FUNCTION:
                continue
            seen.add(fn)
            if fn not in vm_names:
                problems.append(f"手册函数 {fn} 不存在于 VM fnTable1")
            exp = EXPECTED.get(fn)
            if isinstance(exp, int) or (isinstance(exp, str) and exp.startswith("impl:")):
                want = exp if isinstance(exp, int) else int(exp.split(":")[1])
                got = counts.get(fn)
                if got is not None and got != want:
                    problems.append(f"{fn} 签名参数 {got} 个，期望 {want} 个")
    # [C] 宿主环境条目齐备 + freembuf 不得回潮
    names_blob = " ".join(n for n, _, _ in entries)
    for req in ("num_ch", "dev_srate", "srate", "spl0"):
        if req not in names_blob:
            problems.append(f"手册缺少宿主环境条目：{req}")
    if "freembuf" in names_blob:
        problems.append("freembuf 不存在于 VM，手册不得收录")
    if len(entries) < 85:
        problems.append(f"手册条目数异常偏低：{len(entries)}")
    return problems, seen


def main():
    vm_names = vm_function_names()
    entries = manual_entries()
    print(f"VM fnTable1 函数 {len(vm_names)} 个；手册条目 {len(entries)} 条")
    problems, seen = check(vm_names, entries)
    print(f"手册函数名核查 {len(seen)} 个")
    # [D] 反向验证：篡改一处签名个数必须判红
    tampered = [(n, c, s.replace("sin(x)", "sin(x, y)") if n == "sin" else s)
                for n, c, s in entries]
    t_problems, _ = check(vm_names, tampered)
    if not any("sin" in p for p in t_problems):
        problems.append("反向验证失败：篡改 sin 签名未被判红（门禁空转）")
    if problems:
        for p in problems:
            print("FAIL:", p)
        return 1
    print("PASS: EEL 手册与 VM 函数表一致（存在性 + 定长签名 + 宿主条目）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
