# -*- coding: utf-8 -*-
"""smoke_graph_order.py — vendor 链重排序验收。

验收标准：
  1. 非法表被拒（缺 id / 重复 id / 未知 id / 空串），且保持原表（引擎照常跑）。
  2. 合法重排被接受；非交换级（bass 增益 vs tube 饱和）换位后输出可测不同
     ——证明重排真实生效，不只是 rc==0。
  3. 切回默认序，恢复基准。
"""
import ctypes
import math
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DLL = os.path.join(ROOT, 'core', 'desktop', 'windows', 'out', 'Release',
                   'auradsp_engine.dll')

SR = 48000.0
BLOCK = 512
FAIL = []
DEFAULT_ORDER = ('tube,comp,bass,eq,arbmag,convolver,ddc,liveprog,'
                 'crossfeed,stereo,reverb,output')


def check(name, cond, detail=''):
    print(('PASS  ' if cond else 'FAIL  ') + name + ('  ' + detail if detail and not cond else ''))
    if not cond:
        FAIL.append(name)


dll = ctypes.CDLL(DLL)
dll.auradsp_create.restype = ctypes.c_void_p
dll.auradsp_create.argtypes = [ctypes.c_float, ctypes.c_int]
dll.auradsp_process.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_float),
                                ctypes.POINTER(ctypes.c_float), ctypes.c_int]
dll.auradsp_set_param.restype = ctypes.c_int
dll.auradsp_set_param.argtypes = [ctypes.c_void_p, ctypes.c_char_p,
                                  ctypes.c_void_p, ctypes.c_uint32]
dll.auradsp_destroy.argtypes = [ctypes.c_void_p]
dll.auradsp_viz_read.argtypes = [ctypes.c_void_p, ctypes.c_void_p,
                                 ctypes.c_uint32]
dll.auradsp_viz_read.restype = ctypes.c_uint32


def i32(v):
    return ctypes.c_int32(v)


def f32(v):
    return ctypes.c_float(v)


h = dll.auradsp_create(SR, BLOCK)
assert h, 'create failed'


def set_i(pid, v):
    return dll.auradsp_set_param(h, pid.encode(), ctypes.byref(i32(v)), 4)


def set_f(pid, v):
    return dll.auradsp_set_param(h, pid.encode(), ctypes.byref(f32(v)), 4)


def set_str(pid, s):
    b = s.encode('utf-8')
    buf = (ctypes.c_char * len(b)).from_buffer_copy(b)
    return dll.auradsp_set_param(h, pid.encode(), buf, len(b))


# 0. 非法表拒绝（缺 id / 重复 / 未知 / 空串）
ids = DEFAULT_ORDER.split(',')
missing = ','.join([x for x in ids if x != 'bass'])
check('reject missing id', set_str('graph.order', missing) != 0)
check('reject duplicate id', set_str('graph.order', ids[0] + ',' + ','.join(ids)) != 0)
check('reject unknown id', set_str('graph.order', 'nope,' + ','.join(ids[1:])) != 0)
check('reject empty', set_str('graph.order', '') != 0)

# 1. 默认序基准（eq 在 liveprog 之前）：先关 limiter（默认开会把两条路都削平）。
#    判据：eq +9dB@1000Hz 先抬到 ~2.53 再进 liveprog 的 tanh 饱和 → ~1.0；
#    换位（liveprog 先饱和 0.8→~1.0 再被 eq 抬 ×3.16）→ ~3.15。差异巨大且确定。
#    用 liveprog 而非 comp：comp 默认目标平坦，实测开/关输出逐位相同（no-op）。
#    另注：stage 电平槽按效果 id 固定（stageIdx），不跟 order 走。
set_i('limiter.enable', 0)
set_i('eq.enable', 1)
set_i('liveprog.enable', 1)


def set_str_eq(s):
    b = s.encode('utf-8')
    buf = (ctypes.c_char * len(b)).from_buffer_copy(b)
    return dll.auradsp_set_param(h, 'eq.curve'.encode(), buf, len(b))


set_str_eq('60:0;300:0;1000:9;8000:0;16000:0')
SAT = '@init\ndbg = 1;\n@sample\nspl0 = tanh(spl0*4);\nspl1 = tanh(spl1*4);\n'
check('liveprog saturator loaded',
      set_str('liveprog.code', SAT) == 0)
check('default order accepted', set_str('graph.order', DEFAULT_ORDER) == 0)


def read_peak(blocks=48):
    """跑 1000Hz 正弦，返回稳态峰值（最后 4 块最大）。"""
    n0 = 0
    peak = 0.0
    for _ in range(blocks):
        buf = (ctypes.c_float * (BLOCK * 2))()
        for i in range(BLOCK):
            s = 0.8 * math.sin(2 * math.pi * 1000.0 * (n0 + i) / SR)
            buf[i * 2] = s
            buf[i * 2 + 1] = s
        out = (ctypes.c_float * (BLOCK * 2))()
        dll.auradsp_process(h, buf, out, BLOCK)
        n0 += BLOCK
        if _ >= blocks - 4:
            peak = max(peak, max(abs(out[i]) for i in range(BLOCK * 2)))
    return peak


pk_default = read_peak()
print('default peak=%.5f' % pk_default)
check('default: eq->tanh saturates to ~1.0', pk_default < 1.4,
      'peak=%.5f' % pk_default)


# 2. liveprog/eq 换位：先饱和后 Boost（0.8→tanh→×3.16 ≈ 3.15）vs 默认
#    （先 Boost 2.53→tanh ≈ 1.0）。位置不动 = 重排纸面接受实际没执行。
swapped = ('tube,comp,bass,arbmag,convolver,ddc,liveprog,'
           'crossfeed,stereo,reverb,eq,output')
check('swapped order accepted', set_str('graph.order', swapped) == 0)
pk_swapped = read_peak()
print('default peak=%.5f swapped peak=%.5f' % (pk_default, pk_swapped))
check('swapped: tanh first then boosted (~3.1)',
      pk_swapped > 2.2, 'peak=%.5f' % pk_swapped)
check('reorder changes peak (>2x)',
      pk_swapped / max(pk_default, 1e-9) > 2.0,
      'default=%.5f swapped=%.5f' % (pk_default, pk_swapped))

# 3. 切回默认序 + 有限性
check('restore default order', set_str('graph.order', DEFAULT_ORDER) == 0)
pk_back = read_peak()
check('restored: eq->tanh saturates again', pk_back < 1.4, 'peak=%.5f' % pk_back)
set_i('liveprog.enable', 0)
set_i('eq.enable', 0)
set_i('limiter.enable', 1)

dll.auradsp_destroy(h)

print()
if FAIL:
    print('GRAPH_ORDER FAILURES:', FAIL)
    sys.exit(1)
print('graph_order: all checks passed')
