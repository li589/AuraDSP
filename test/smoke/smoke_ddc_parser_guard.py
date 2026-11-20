"""smoke_ddc_parser_guard.py — DDC 解析与文件门回归（2026-11-20 审查修复）。

覆盖三项已定罪问题（见 engine/legacy/PATCHES.md P-050/P-051 与
docs/30-审查/新旧问题复核报告-2026-11-20.md 的 V-02/V-03/V-04）：

  V-03 解析器加固（P-051）：nan/inf 标记、44.1 节混入非数字组、两节
       个数不等、个数非 5 倍数——四类畸形 DDC 必须被拒绝（ddc.load
       返回非零、ddc.ready=0）；合法文件对照组正常加载且实际改变输出。
       修复前：nan/inf 与越节扫描被接受、非 5 倍数尾组堆溢出。
  V-04 文件上限统一（engine_param_table.h）：DDC 加载须服从
       gate.maxFileMb——设 1MiB 后 ~1.1MiB 的合法宽格式 DDC 应被拒，
       恢复默认 64MiB 后应可加载。修复前写死 4MiB、与 gate 无关。
  V-02 重采样跳节错位（P-050）：经引擎 API 不可达（ASRC 映射使
       jdsp->fs 只落 {44100,48000} 或其间开区间，后者无节可跳），
       改由 C 层直测 vdc_resampler_test.c 锁定函数契约；无 C 编译器
       （cc/gcc/clang）时该节 SKIP。
"""
import ctypes
import math
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, 'test'))
from engine_artifact import find_engine_lib  # noqa: E402

SR = 48000.0
BLOCK = 512
FAIL = []


def check(name, cond, detail=''):
    print(('PASS  ' if cond else 'FAIL  ') + name +
          ('  ' + detail if detail and not cond else ''))
    if not cond:
        FAIL.append(name)


DLL = find_engine_lib()
if not os.path.isfile(DLL):
    print('SKIP engine lib not found:', DLL)
    sys.exit(0)

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


def peaking(fs, freq, gain_db, q=1.0):
    """RBJ peaking 系数，按 DDC 文件约定输出 (b0,b1,b2,-a1,-a2)。"""
    A = 10 ** (gain_db / 40.0)
    w = 2 * math.pi * freq / fs
    alpha = math.sin(w) / (2 * q)
    c = math.cos(w)
    b0, b1, b2 = 1 + alpha * A, -2 * c, 1 - alpha * A
    a0, a1, a2 = 1 + alpha / A, -2 * c, 1 - alpha / A
    return (b0 / a0, b1 / a0, b2 / a0, -a1 / a0, -a2 / a0)


def section_text(coeffs_list):
    return ','.join(','.join('%.10g' % v for v in sec) for sec in coeffs_list)


def ddc_text(body44, body48):
    return 'SR_44100:' + body44 + '\nSR_48000:' + body48 + '\n'


class Eng:
    def __init__(self):
        self.h = dll.auradsp_create(SR, BLOCK)
        assert self.h, 'create failed'

    def close(self):
        dll.auradsp_destroy(self.h)

    def set_i(self, pid, v):
        return dll.auradsp_set_param(self.h, pid.encode(),
                                     ctypes.byref(ctypes.c_int32(v)), 4)

    def set_f(self, pid, v):
        return dll.auradsp_set_param(self.h, pid.encode(),
                                     ctypes.byref(ctypes.c_float(v)), 4)

    def set_str(self, pid, s):
        b = s.encode('utf-8')
        buf = (ctypes.c_char * len(b)).from_buffer_copy(b)
        return dll.auradsp_set_param(self.h, pid.encode(), buf, len(b))

    def get_i(self, pid):
        v = ctypes.c_int32(0)
        rc = dll.auradsp_get_param(self.h, pid.encode(), ctypes.byref(v), 4)
        return rc, v.value

    def load(self, path):
        return self.set_str('ddc.load', path)

    def run_sine(self, freq, amp=0.2, blocks=32):
        n0 = 0
        outs = []
        for b in range(blocks):
            buf = (ctypes.c_float * (BLOCK * 2))()
            for i in range(BLOCK):
                s = amp * math.sin(2 * math.pi * freq * (n0 + i) / SR)
                buf[i * 2] = s
                buf[i * 2 + 1] = s
            out = (ctypes.c_float * (BLOCK * 2))()
            dll.auradsp_process(self.h, buf, out, BLOCK)
            n0 += BLOCK
            if b >= blocks - 2:
                outs.extend(out[i * 2] for i in range(BLOCK))
        return outs


tmp = tempfile.mkdtemp(prefix='ddc_guard_')


def write_case(name, text):
    p = os.path.join(tmp, name)
    with open(p, 'w', encoding='utf-8') as f:
        f.write(text)
    return p


# ---- V-03：畸形输入必须被拒绝（每例独立句柄，ready 初值 0） ----
good48 = section_text([peaking(SR, 1000.0, 6.0), peaking(SR, 3000.0, 6.0)])
good44 = section_text([peaking(44100.0, 1000.0, 6.0),
                       peaking(44100.0, 3000.0, 6.0)])

nan48 = 'nan,' + good48.split(',', 1)[1]
inf48 = 'inf,' + good48.split(',', 1)[1]
junk44 = section_text([peaking(44100.0, 1000.0, 6.0)]) + ',x,x,x,x,x'
extra = good48 + ',7'

cases = [
    ('reject nan token', ddc_text(good44, nan48)),
    ('reject inf token', ddc_text(good44, inf48)),
    ('reject unequal section counts',
     ddc_text(section_text([peaking(44100.0, 1000.0, 6.0)]), good48)),
    ('reject junk group in 44.1 section', ddc_text(junk44, good48)),
    ('reject count not multiple of 5', ddc_text(extra, extra)),
]
for idx, (name, text) in enumerate(cases):
    e = Eng()
    rc = e.load(write_case('bad%d.ddc' % idx, text))
    check(name, rc != 0 and e.get_i('ddc.ready') == (0, 0),
          'rc=%d ready=%s' % (rc, e.get_i('ddc.ready')))
    e.close()

# ---- 合法对照：加载成功、ready=1、使能后输出确实改变 ----
e = Eng()
rc = e.load(write_case('good.ddc', ddc_text(good44, good48)))
check('valid ddc loads', rc == 0 and e.get_i('ddc.ready') == (0, 1),
      'rc=%d ready=%s' % (rc, e.get_i('ddc.ready')))
e.set_i('ddc.enable', 1)
outs_on = e.run_sine(1000.0)
e.set_i('ddc.enable', 0)
outs_off = e.run_sine(1000.0)
diff = math.sqrt(sum((a - b) ** 2 for a, b in zip(outs_on, outs_off)) / len(outs_on))
base = math.sqrt(sum(b * b for b in outs_off) / len(outs_off))
check('valid ddc changes output (>5%)', diff > base * 0.05,
      'diff=%.5f base=%.4f' % (diff, base))
e.close()

# ---- V-04：DDC 上限服从 gate.maxFileMb ----
def wide_ddc(gain, sections):
    def sec(b0):
        return ','.join('%.20e' % v for v in (b0, 0.0, 0.0, 0.0, 0.0))
    body = ','.join([sec(gain)] + [sec(1.0)] * (sections - 1))
    return ddc_text(body, body)


e = Eng()
big1 = write_case('big1.ddc', wide_ddc(1.5, 5000))   # ~1.1MiB
size = os.path.getsize(big1)
check('wide fixture size in (1MiB, 4MiB)', 1024 * 1024 < size < 4 * 1024 * 1024,
      'size=%d' % size)
check('wide ddc loads under default gate', e.load(big1) == 0)
check('set gate.maxFileMb=1', e.set_f('gate.maxFileMb', 1.0) == 0)
big2 = write_case('big2.ddc', wide_ddc(1.6, 5000))   # 内容不同，避开去重
rc = e.load(big2)
check('wide ddc rejected when gate=1MiB', rc != 0, 'rc=%d' % rc)
check('restore gate.maxFileMb=64', e.set_f('gate.maxFileMb', 64.0) == 0)
check('wide ddc loads again after restore', e.load(big2) == 0)
e.close()

# ---- V-02：C 层直测 PeakingFilterResampler（需 C 编译器） ----
cc = shutil.which('cc') or shutil.which('gcc') or shutil.which('clang')
if not cc:
    print('SKIP  resampler C test (no C compiler)')
else:
    exe = os.path.join(tmp, 'vdc_resampler_test')
    src_c = os.path.join(ROOT, 'test', 'smoke', 'vdc_resampler_test.c')
    vdc_c = os.path.join(ROOT, 'engine', 'legacy', 'jdsp', 'Effects', 'vdc.c')
    inc = os.path.join(ROOT, 'engine', 'legacy', 'jdsp')
    r = subprocess.run([cc, '-O1', '-I', inc, '-o', exe, src_c, vdc_c, '-lm'],
                       capture_output=True, text=True)
    if r.returncode != 0:
        check('resampler C test compiles', False, r.stderr[-400:])
    else:
        r2 = subprocess.run([exe], capture_output=True, text=True)
        print(r2.stdout.strip())
        check('resampler keeps kept sections (V-02)',
              r2.returncode == 0 and 'PASS' in r2.stdout,
              'rc=%d' % r2.returncode)

shutil.rmtree(tmp, ignore_errors=True)
print()
if FAIL:
    print('DDC GUARD FAILURES:', FAIL)
    sys.exit(1)
print('ddc_parser_guard: all checks passed')
