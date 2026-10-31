# -*- coding: utf-8 -*-
"""smoke_comp_band_order.py — E-01 频带交叉/等值门禁。

背景：`comp.freq1..7` 各自独立钳制 [20,20000]，不校验单调。用户把滑块拖
交叉后，legacy pchip 逐点 printf 刷日志（实测一次拖动 5008 行 / 389KB），
upper_bound 还会在无序数组上取错段。修复：apply_comp 组包前按频率成对
排序并以 1Hz 最小间隔拉开（engine_chain.cpp sort_comp_bands）。

本门禁三层：
  1. 交叉序（7 个频点整体反向）→ 输出全程有限，参数回读保持用户设定。
  2. 等值序（全部 1000Hz / 全部 20000Hz）→ 不崩、无 NaN。
  3. 子进程日志层：同一交叉序列在子进程执行，捕获其 stdout/stderr，
     不得出现 pchip 的 "Abscissas..." / "Must be at least..." 报警
     （修复前此断言必红，直接量化 printf 风暴）。
"""
import ctypes
import math
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DLL = os.path.join(ROOT, 'core', 'desktop', 'windows', 'out', 'Release',
                   'auradsp_engine.dll')
SR = 48000.0
BLOCK = 512
FAIL = []

if not os.path.exists(DLL):
    print(f"[SKIP] 引擎 DLL 不存在: {DLL}")
    sys.exit(0)


def check(name, cond, detail=''):
    print(('PASS  ' if cond else 'FAIL  ') + name +
          ('  ' + detail if detail and not cond else ''))
    if not cond:
        FAIL.append(name)


def load_lib():
    dll = ctypes.CDLL(DLL)
    dll.auradsp_create.restype = ctypes.c_void_p
    dll.auradsp_create.argtypes = [ctypes.c_float, ctypes.c_int]
    dll.auradsp_process.argtypes = [ctypes.c_void_p,
                                    ctypes.POINTER(ctypes.c_float),
                                    ctypes.POINTER(ctypes.c_float), ctypes.c_int]
    dll.auradsp_set_param.restype = ctypes.c_int
    dll.auradsp_set_param.argtypes = [ctypes.c_void_p, ctypes.c_char_p,
                                      ctypes.c_void_p, ctypes.c_uint32]
    dll.auradsp_get_param.restype = ctypes.c_int
    dll.auradsp_get_param.argtypes = [ctypes.c_void_p, ctypes.c_char_p,
                                      ctypes.c_void_p, ctypes.c_uint32]
    dll.auradsp_destroy.argtypes = [ctypes.c_void_p]
    return dll


def set_i(dll, h, pid, v):
    val = ctypes.c_int32(v)
    return dll.auradsp_set_param(h, pid.encode(), ctypes.byref(val), 4)


def set_f(dll, h, pid, v):
    val = ctypes.c_float(v)
    return dll.auradsp_set_param(h, pid.encode(), ctypes.byref(val), 4)


def get_f(dll, h, pid):
    val = ctypes.c_float(0)
    rc = dll.auradsp_get_param(h, pid.encode(), ctypes.byref(val), 4)
    return rc, val.value


def set_bands(dll, h, freqs):
    """freqs: 7 个频率；增益按序号正负交替，便于发现配对错位。"""
    ok = True
    for i, f in enumerate(freqs):
        ok = set_f(dll, h, f'comp.freq{i + 1}', float(f)) == 0 and ok
        g = 0.6 if i % 2 == 0 else -0.6
        ok = set_f(dll, h, f'comp.gain{i + 1}', g) == 0 and ok
    return ok


def run_sine(dll, h, freq=1000.0, amp=0.5, blocks=60):
    """返回最后 8 块的最大绝对值；非有限则返回 inf。"""
    peak = 0.0
    n0 = 0
    for b in range(blocks):
        buf = (ctypes.c_float * (BLOCK * 2))()
        for i in range(BLOCK):
            s = amp * math.sin(2 * math.pi * freq * (n0 + i) / SR)
            buf[i * 2] = s
            buf[i * 2 + 1] = s
        out = (ctypes.c_float * (BLOCK * 2))()
        dll.auradsp_process(h, buf, out, BLOCK)
        n0 += BLOCK
        if b >= blocks - 8:
            for i in range(BLOCK * 2):
                v = out[i]
                if not math.isfinite(v):
                    return float('inf')
                peak = max(peak, abs(v))
    return peak


CASES = [
    ('交叉序', [7500.0, 3400.0, 1600.0, 800.0, 400.0, 200.0, 95.0]),
    ('等值 1000Hz', [1000.0] * 7),
    ('全 20000Hz', [20000.0] * 7),
]


def exercise(dll, h, label_prefix=''):
    for name, freqs in CASES:
        check(f'{label_prefix}{name} 写参成功', set_bands(dll, h, freqs))
        peak = run_sine(dll, h)
        check(f'{label_prefix}{name} 输出有限且不爆', peak < 10.0,
              f'peak={peak}')
        # 排序只作用于提交给 pchip 的副本，参数回读必须保持用户设定
        rc, got = get_f(dll, h, 'comp.freq1')
        check(f'{label_prefix}{name} 回读保持', rc == 0 and got == freqs[0],
              f'rc={rc} got={got}')


# ---------------- 子进程模式：只跑交叉序列，供父进程抓日志 ----------------
if '--child' in sys.argv:
    dll = load_lib()
    h = dll.auradsp_create(SR, BLOCK)
    assert h, 'child create failed'
    set_i(dll, h, 'comp.enable', 1)
    exercise(dll, h)
    dll.auradsp_destroy(h)
    print('CHILD_OK')
    sys.exit(0 if not FAIL else 1)


# ---------------- 主进程：功能层 + 日志层 ----------------
dll = load_lib()
h = dll.auradsp_create(SR, BLOCK)
assert h, 'create failed'

check('comp.enable 开启', set_i(dll, h, 'comp.enable', 1) == 0)
exercise(dll, h)
dll.auradsp_destroy(h)

# runner.py 给子进程固定 PYTHONIOENCODING=utf-8；这里必须显式按 UTF-8 解码，
# 否则 text=True 会走本机 locale（GBK）→ UnicodeDecodeError，CHILD_OK 丢失。
proc = subprocess.run([sys.executable, os.path.abspath(__file__), '--child'],
                      capture_output=True, text=True, timeout=120,
                      encoding='utf-8', errors='replace')
log = (proc.stdout or '') + (proc.stderr or '')
check('子进程交叉序列执行成功', proc.returncode == 0,
      f'rc={proc.returncode}')
check('子进程完成标记', 'CHILD_OK' in log)
check('pchip 无 Abscissas 报警', 'Abscissas' not in log)
check('pchip 无数据点数量报警', 'Must be at least' not in log)

print()
if FAIL:
    print('COMP_BAND_ORDER FAILURES:', FAIL)
    sys.exit(1)
print('comp_band_order: all checks passed')
