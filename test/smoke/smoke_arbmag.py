"""smoke_arbmag.py — 任意响应 EQ（ArbMag / AutoEq）烟雾验收。

验收标准：
  1. 未加载曲线时直接开启被拒绝（AURADSP_E_STATE）。
  2. 写入有效 GraphicEQ 字符串后 ready=1，nodeCount 正确。
  3. 开启后可正常推流。
  4. 回读 enable/ready/nodeCount 全对称。
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

h = dll.auradsp_create(SR, BLOCK)
assert h, 'create failed'

def set_i(pid, v):
    val = ctypes.c_int32(v)
    return dll.auradsp_set_param(h, pid.encode(), ctypes.byref(val), 4)

def get_i(pid):
    val = ctypes.c_int32(0)
    rc = dll.auradsp_get_param(h, pid.encode(), ctypes.byref(val), 4)
    return rc, val.value

def set_str(pid, s):
    bs = s.encode('utf-8')
    return dll.auradsp_set_param(h, pid.encode(), bs, len(bs))

# 1. 初始未加载曲线：enable=1 应被拒绝
check('unloaded enable rejected', set_i('arbmag.enable', 1) != 0)
_, r = get_i('arbmag.ready')
check('initial ready=0', r == 0)

# 2. 写入 GraphicEQ 文本
eq_text = 'GraphicEQ: 20 0.0; 100 1.5; 1000 -2.0; 10000 3.0; 20000 0.0'
rc = set_str('arbmag.string', eq_text)
check('set GraphicEQ string', rc == 0)

_, r = get_i('arbmag.ready')
check('ready after load', r == 1)

_, nc = get_i('arbmag.nodeCount')
check('nodeCount=5', nc == 5, f'actual={nc}')

# 3. 加载后使能应成功
rc = set_i('arbmag.enable', 1)
check('enable succeeded', rc == 0)
_, en = get_i('arbmag.enable')
check('get enable==1', en == 1)

# 4. 推流测试（无爆音/崩溃）
in_buf = (ctypes.c_float * (BLOCK * 2))()
out_buf = (ctypes.c_float * (BLOCK * 2))()
for i in range(BLOCK * 2):
    in_buf[i] = 0.1
dll.auradsp_process(h, in_buf, out_buf, BLOCK)
check('process block completed', any(out_buf[i] != 0 for i in range(BLOCK * 2)))

# 5. 禁用
set_i('arbmag.enable', 0)
_, en = get_i('arbmag.enable')
check('disable==0', en == 0)

dll.auradsp_destroy(h)

if FAIL:
    print(f'\n{len(FAIL)} checks FAILED: {FAIL}')
    sys.exit(1)
print('\narbmag: all checks passed')
