"""smoke_ddc_race.py — DDC 控制线程/RT 线程竞争门禁（Z14）。

背景（2026-10-23，Z13 同类竞争收尾）：Z13 修复 compander 时确认引擎
kAuraStages 的 ddc lock=1——RT 经 JamesDSPProcessMultiplexedStageSet
持 jdsp_lock 调 stage_ddc→DDCProcess（读 vdcFl.sosPointer/
usedSOSCount）；但控制侧 set_ddc_enable/set_ddc_load 的 DDCEnable/
DDCDisable 不持锁，构成同型缺口（RT 侧假设的互斥，控制侧未兑现）。

竞争面代码审计（本轮实测结论，决定红绿形态）：
  1. auradsp_set_param 全程持 h->ctrl_mutex（auradsp_engine.cpp:397）
     → 控制-控制竞争（如 enable 落入另一线程 ddc.load 的解析瞬窗）
     结构上不可能发生，无法经公共 ABI 构造动态红证；
  2. 危险路径 DDCEnable→DDCRefresh（ddcForceRefresh 置位时 free 旧
     sosPointer + 重解析换指针）当前不可达——唯一置位点
     JamesDSPSetSampleRate 的调用方传 forceRefresh=0，标志恒不被置位；
  3. 残余竞争 = 控制侧 DDCEnable/DDCDisable（无锁）vs RT stage_ddc
     （持锁）：写 ddcEnabled 明文 int、读 vdcFl——x86/ARM 上实践良性，
     但属 C 形式数据竞争，且任何未来置位 ddcForceRefresh 的调用方都会
     把它升级为 UAF。修法 = 控制侧与 RT 同锁（Z13 comp 同型），
     结构性关闭上述全部面。

本测试以多线程复刻最重锁竞争（ctypes 外部调用释放 GIL，真实并发）：
  - 「UI 线程 A」：高频 auradsp_set_param(ddc.enable, 1)（偶发关-开），
    计数 rc!=0 误拒；
  - 「UI 线程 B」：交替 ddc.load 两份不同内容的大 VDC（1500 SOS 段，
    持锁解析 + 慢速 stage_ddc 使 RT 长时间占用 jdsp_lock）；
  - 「RT 线程」：连续 auradsp_process 灌入位置编码信号（正弦+散列噪声），
    抽样扫描输出有限性。

通过标准：进程存活 + 输出全程有限 + 全部线程超时前结束（**加锁后无
死锁/饥饿**——本修法的主要风险面）+ enable 零误拒 + 收尾样本级验证
DDC 生效（out_on == 0.5×out_off，VDC_A 净增益 0.5）。

能证明：加锁后控制侧与 RT/并发加载的互斥语义不回归（无死锁、无饿死、
DDC 仍逐样本正确生效、引擎状态不残留损坏）；若未来出现绕过 ctrl_mutex
的控制入口或置位 ddcForceRefresh 的路径，本测试的持续锤击可抓住退化。
不能证明：ddcForceRefresh→DDCRefresh 路径本身（当前不可达）——该路径
由本锁结构性覆盖，一旦可达即自动安全；控制-控制瞬窗误拒（被
ctrl_mutex 排除，非本测试可观测项）。
"""
import ctypes
import math
import os
import shutil
import sys
import tempfile
import threading
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DLL = os.path.join(ROOT, 'core', 'desktop', 'windows', 'out', 'Release',
                   'auradsp_engine.dll')

SR = 48000.0
BLOCK = 512
SECTIONS = 1500          # VDC SOS 段数（identity 段摊薄每样本成本，同时保证解析时长）
UI_SECONDS = 5.0         # 竞争时长
JOIN_TIMEOUT = 30.0      # 死锁防御：锁竞争下控制线程可能排队，放宽
FAIL = []


def check(name, cond, detail=''):
    print(('PASS  ' if cond else 'FAIL  ') + name + ('  ' + detail if detail and not cond else ''))
    if not cond:
        FAIL.append(name)


def build_vdc(gain):
    """合成 VDC 文本：首段 b0=gain（净增益），其余 identity 段（b0=1, 余 0）。
    两份不同 gain → 内容不同（规避 DDCStringParser 同内容早退）。"""
    def sec(b0):
        return '%.17g,%.17g,%.17g,%.17g,%.17g' % (b0, 0.0, 0.0, 0.0, 0.0)
    body = ','.join([sec(gain)] + [sec(1.0)] * (SECTIONS - 1))
    return 'SR_44100:' + body + '\nSR_48000:' + body + '\n'


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
dll.auradsp_last_error.restype = ctypes.c_char_p
dll.auradsp_last_error.argtypes = [ctypes.c_void_p]
dll.auradsp_destroy.argtypes = [ctypes.c_void_p]

tmpdir = tempfile.mkdtemp(prefix='auradsp_ddc_race_')
path_a = os.path.join(tmpdir, 'race_a.vdc')
path_b = os.path.join(tmpdir, 'race_b.vdc')
with open(path_a, 'w') as f:
    f.write(build_vdc(0.5))
with open(path_b, 'w') as f:
    f.write(build_vdc(0.75))

h = dll.auradsp_create(SR, BLOCK)
assert h, 'create failed'


def i32(v):
    return ctypes.c_int32(v)


def set_i(pid, v):
    return dll.auradsp_set_param(h, pid.encode(), ctypes.byref(i32(v)), 4)


def get_i(pid):
    v = i32(0)
    rc = dll.auradsp_get_param(h, pid.encode(), ctypes.byref(v), 4)
    return rc, v.value


def set_path(pid, path):
    b = path.encode('utf-8')
    buf = (ctypes.c_char * len(b)).from_buffer_copy(b)
    return dll.auradsp_set_param(h, pid.encode(), buf, len(b))


# 预热：加载 VDC_A + 使能，让 DDC 进入稳定产出态
assert set_path('ddc.load', path_a) == 0, 'warmup load failed'
assert set_i('ddc.enable', 1) == 0, 'warmup enable failed'
rc, ready = get_i('ddc.ready')
check('warmup ddc.ready == 1', rc == 0 and ready == 1, 'rc=%d ready=%d' % (rc, ready))

stop = threading.Event()
rt_nonfinite = []
rt_crash = []
rt_blocks = [0]
load_iters = [0]
load_errors = []
enable_iters = [0]
enable_rejects = []       # 误拒计数（红绿核心）
reject_samples = []       # 误拒时的 last_error 采样（报告用）


def load_thread():
    """交替加载两份不同内容 VDC：每轮打开持锁的解析瞬窗（sosPointer 置空
    到重装完成）。"""
    paths = [path_a.encode(), path_b.encode()]
    bufs = []
    for p in paths:
        bufs.append((ctypes.c_char * len(p)).from_buffer_copy(p))
    n = 0
    t0 = time.perf_counter()
    while time.perf_counter() - t0 < UI_SECONDS:
        buf = bufs[n % 2]
        rc = dll.auradsp_set_param(h, b'ddc.load', buf, len(buf))
        if rc != 0:
            load_errors.append('rc=%d' % rc)
        n += 1
    load_iters[0] = n


def enable_thread():
    """高频 enable=1：落入加载瞬窗即误拒（修复前红证）。参数对象预构建，
    循环内只改 .value，把 Python 开销压最低。"""
    en = i32(1)
    en_ref = ctypes.byref(en)
    n = 0
    t0 = time.perf_counter()
    while time.perf_counter() - t0 < UI_SECONDS:
        if n % 97 == 0 and n > 0:
            en.value = 0
            dll.auradsp_set_param(h, b'ddc.enable', en_ref, 4)
            en.value = 1
        rc = dll.auradsp_set_param(h, b'ddc.enable', en_ref, 4)
        if rc != 0:
            enable_rejects.append(rc)
            if len(reject_samples) < 3:
                try:
                    reject_samples.append(dll.auradsp_last_error(h))
                except Exception:
                    pass
        n += 1
    enable_iters[0] = n


def rt_thread():
    """RT 音频回调：预分配缓冲连续 process，每 64 块抽样扫描有限性。"""
    buf = (ctypes.c_float * (BLOCK * 2))()
    out = (ctypes.c_float * (BLOCK * 2))()
    for i in range(BLOCK):
        s = 0.4 * math.sin(2 * math.pi * 1000.0 * i / SR)
        s += 0.05 * (((i * 2654435761) % 1000) / 1000.0 - 0.5)
        buf[i * 2] = s
        buf[i * 2 + 1] = s
    k = 0
    while not stop.is_set():
        try:
            dll.auradsp_process(h, buf, out, BLOCK)
        except OSError as e:
            rt_crash.append('block %d: %s' % (k, e))
            break
        if (k & 63) == 0:
            for i in range(0, BLOCK * 2, 8):
                v = out[i]
                if v != v or v > 1e6 or v < -1e6:
                    rt_nonfinite.append(k)
                    break
        k += 1
    rt_blocks[0] = k


t_rt = threading.Thread(target=rt_thread, daemon=True)
t_ld = threading.Thread(target=load_thread, daemon=True)
t_en = threading.Thread(target=enable_thread, daemon=True)
t_rt.start()
t_ld.start()
t_en.start()
t_ld.join(JOIN_TIMEOUT)
ld_alive = t_ld.is_alive()
t_en.join(JOIN_TIMEOUT)
en_alive = t_en.is_alive()
stop.set()
t_rt.join(JOIN_TIMEOUT)
rt_alive = t_rt.is_alive()

check('load thread finished (no deadlock/hang)', not ld_alive,
      'alive after %.0fs' % JOIN_TIMEOUT)
check('enable thread finished (no deadlock/hang)', not en_alive,
      'alive after %.0fs' % JOIN_TIMEOUT)
check('rt thread finished (no deadlock/hang)', not rt_alive,
      'alive after %.0fs' % JOIN_TIMEOUT)
check('ddc.load all rc==0 (loads never fail)', not load_errors, str(load_errors[:3]))
check('ddc.enable zero false-reject during concurrent load (race closed)',
      not enable_rejects,
      'rejects=%d first=%s samples=%s' % (len(enable_rejects),
                                          enable_rejects[0] if enable_rejects else None,
                                          reject_samples))
check('rt no hard fault (access violation)', not rt_crash, str(rt_crash[:1]))
check('rt output always finite', not rt_nonfinite,
      'first bad block=%s' % (rt_nonfinite[0] if rt_nonfinite else None))
check('rt produced audio (blocks>200)', rt_blocks[0] > 200, 'blocks=%d' % rt_blocks[0])
check('load thread hammered (iters>50)', load_iters[0] > 50, 'iters=%d' % load_iters[0])
check('enable thread hammered (iters>50)', enable_iters[0] > 50, 'iters=%d' % enable_iters[0])
print('  [info] loads=%d, enables=%d, rt blocks=%d, rejects=%d'
      % (load_iters[0], enable_iters[0], rt_blocks[0], len(enable_rejects)))

# 收尾 1（样本级生效验证）：显式装载 VDC_A（净增益 0.5）后，
# out_on 必须逐样本 == 0.5*out_off（链内 limiter 在该路径被置 0、
# postGain=1，其余效果默认关 → 输出即 DDC 输出）。
assert set_path('ddc.load', path_a) == 0, 'final load A failed'
assert set_i('ddc.enable', 1) == 0, 'final enable failed'
sig = (ctypes.c_float * (BLOCK * 2))()
out_on = (ctypes.c_float * (BLOCK * 2))()
out_off = (ctypes.c_float * (BLOCK * 2))()
for i in range(BLOCK):
    s = 0.4 * math.sin(2 * math.pi * 1000.0 * i / SR)
    s += 0.05 * (((i * 2654435761) % 1000) / 1000.0 - 0.5)
    sig[i * 2] = s
    sig[i * 2 + 1] = s
for _ in range(8):
    dll.auradsp_process(h, sig, out_on, BLOCK)
assert set_i('ddc.enable', 0) == 0, 'final disable failed'
for _ in range(8):
    dll.auradsp_process(h, sig, out_off, BLOCK)
max_dev = 0.0
mean_on = 0.0
mean_off = 0.0
for i in range(BLOCK * 2):
    dev = abs(out_on[i] - 0.5 * out_off[i])
    if dev > max_dev:
        max_dev = dev
    mean_on += abs(out_on[i])
    mean_off += abs(out_off[i])
mean_on /= BLOCK * 2
mean_off /= BLOCK * 2
check('ddc engaged: out_on == 0.5*out_off (sample-wise)', max_dev < 1e-4,
      'max_dev=%g' % max_dev)
check('ddc engagement measurable (mean ratio ~0.5)',
      0.45 < (mean_on / mean_off if mean_off else 0.0) < 0.55,
      'mean_on=%g mean_off=%g' % (mean_on, mean_off))

# 收尾 2：竞争后引擎仍可用（无状态损坏残留）
ok_tail = True
for _ in range(32):
    dll.auradsp_process(h, sig, out_on, BLOCK)
    for i in range(0, BLOCK * 2, 8):
        v = out_on[i]
        if v != v or v > 1e6 or v < -1e6:
            ok_tail = False
check('engine still healthy after race', ok_tail)

dll.auradsp_destroy(h)
shutil.rmtree(tmpdir, ignore_errors=True)

print()
if FAIL:
    print('DDC RACE FAILURES:', FAIL)
    sys.exit(1)
print('ddc race: all checks passed')
