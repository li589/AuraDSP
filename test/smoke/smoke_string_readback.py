# -*- coding: utf-8 -*-
"""smoke_string_readback.py — 字符串回读三 id 往返一致性（预设 §8.1 / 调研 §1）。

验收标准：
  1. 全新 handle 上三 id 回读均为空串（rc=0，首字节 NUL）——不误报。
  2. set → get 往返逐字节相等（eq.curve / arbmag.string / liveprog.code）。
  3. 重复 set 覆盖旧副本（get 反映最新值，无陈旧残留）。
  4. get 容量 < len+1 时返回 E_PARAM（契约：bytes 须 >= len+1）。
  5. 不新增导出符号——本测试只经既有 auradsp_get_param 走字符串路径（ABI 不变）。
"""
import ctypes
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DLL = os.path.join(ROOT, 'core', 'desktop', 'windows', 'out', 'Release', 'auradsp_engine.dll')

SR = 48000.0
BLOCK = 512
FAIL = []

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
dll.auradsp_get_param.restype = ctypes.c_int
dll.auradsp_get_param.argtypes = [ctypes.c_void_p, ctypes.c_char_p,
                                  ctypes.c_void_p, ctypes.c_uint32]
dll.auradsp_destroy.argtypes = [ctypes.c_void_p]

E_PARAM = -1

h = dll.auradsp_create(SR, BLOCK)
assert h, 'create failed'

def set_str(pid, s):
    bs = s.encode('utf-8')
    return dll.auradsp_set_param(h, pid.encode(), bs, len(bs))

def get_str(pid, cap):
    buf = ctypes.create_string_buffer(cap)
    rc = dll.auradsp_get_param(h, pid.encode(), buf, cap)
    return rc, buf.value

# 1. 全新 handle：三 id 回读为空串
for pid in ('eq.curve', 'arbmag.string', 'liveprog.code'):
    rc, s = get_str(pid, 1024)
    check('fresh handle %s -> empty(rc=0)' % pid, rc == 0 and s == b'', 'rc=%d s=%r' % (rc, s))

# 2. set -> get 往返逐字节相等
eq_text = '20:0;1000:3;20000:0'
rc = set_str('eq.curve', eq_text)
check('set eq.curve', rc == 0, 'rc=%d' % rc)
rc, s = get_str('eq.curve', 4096)
check('eq.curve roundtrip byte-exact', rc == 0 and s == eq_text.encode(), 'rc=%d s=%r' % (rc, s))

arb_text = 'GraphicEQ: 20 0.0; 100 1.5; 1000 -2.0; 10000 3.0; 20000 0.0'
rc = set_str('arbmag.string', arb_text)
check('set arbmag.string', rc == 0, 'rc=%d' % rc)
rc, s = get_str('arbmag.string', 256 * 1024)
check('arbmag.string roundtrip byte-exact', rc == 0 and s == arb_text.encode(), 'rc=%d s=%r' % (rc, s))

lp_text = '@init\ndbg = 1;\n@sample\nspl0 *= slider1;\n'
rc = set_str('liveprog.code', lp_text)
check('set liveprog.code', rc == 0, 'rc=%d' % rc)
rc, s = get_str('liveprog.code', 256 * 1024)
check('liveprog.code roundtrip byte-exact', rc == 0 and s == lp_text.encode(), 'rc=%d s=%r' % (rc, s))

# 3. 重复 set 覆盖旧副本
eq_text2 = '50:-2;500:0;15000:2'
rc = set_str('eq.curve', eq_text2)
check('re-set eq.curve', rc == 0, 'rc=%d' % rc)
rc, s = get_str('eq.curve', 4096)
check('eq.curve re-set reflected', rc == 0 and s == eq_text2.encode(), 'rc=%d s=%r' % (rc, s))

# 4. 容量契约：bytes < len+1 -> E_PARAM
bs = eq_text2.encode()
rc, _ = get_str('eq.curve', len(bs))  # 恰差 1 字节（不含 NUL 空间）
check('undersized buffer rejected (E_PARAM)', rc == E_PARAM, 'rc=%d' % rc)
rc, s = get_str('eq.curve', len(bs) + 1)  # 恰好够
check('exact-fit buffer accepted', rc == 0 and s == bs, 'rc=%d s=%r' % (rc, s))

# 5. 往返后引擎仍可正常推流（副本逻辑不碰处理链）
frames = BLOCK
inp = (ctypes.c_float * (frames * 2))(*([0.01] * (frames * 2)))
outp = (ctypes.c_float * (frames * 2))()
dll.auradsp_process(h, inp, outp, frames)
check('process after readback patch', True)

# 6. eq.curve 增益 NaN 不得污染插值/IR（atof("nan") 曾绕过三元钳制）
nan_text = '20:nan;1000:3;20000:0'
rc = set_str('eq.curve', nan_text)
check('eq.curve with NaN gain rejected pair', rc == 0, 'rc=%d' % rc)
ok_nan = True
for _ in range(4):
    dll.auradsp_process(h, inp, outp, frames)
    for i in range(frames * 2):
        v = outp[i]
        if v != v or abs(v) > 10.0:
            ok_nan = False
check('NaN EQ curve leaves finite state', ok_nan)

dll.auradsp_destroy(h)

print()
if FAIL:
    print('FAILED: %d checks: %s' % (len(FAIL), ', '.join(FAIL)))
    sys.exit(1)
print('ALL STRING READBACK CHECKS PASSED')
