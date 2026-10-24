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

B1-b 追加段（2026-10-24 影子视图化后）：
  - 大文件防崩回归：countChars 原为按字符递归（深度=剩余串长），
    ~107KB 以上 VDC 即栈溢出崩溃（用户选个大 .vdc 就崩）；已改迭代。
    本段以 ~300KB / ~1.3MB 两份大 VDC 守门；
  - 解析期间 RT 不阻塞：1.3MB 文件解析 ~30ms，pre-B1-b 持锁期间 RT
    每窗口被挡 ~30ms；影子视图化后 max block 应 ≪ 15ms；
  - 解析期间旧视图持续生效：加载增益 0.25 大文件的解析窗口内，输出
    必须保持旧视图（VDC_A 增益 0.5）的水平，切换只在换指针后发生；
  - 停流连发加载全部成功（ddcInFlight==0 守卫，同 B1-a liveprog）。

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


def build_vdc_wide(gain, sections):
    """长数字格式 VDC（每数 ~20 字符）：用文本体积而非段数撑大文件——
    解析耗时随文本增长，RT 每样本成本只随段数增长，两者解耦。
    用于 countChars 递归崩溃回归（>107KB）与大文件解析压测。"""
    def sec(b0):
        return ','.join('%.20e' % v for v in (b0, 0.0, 0.0, 0.0, 0.0))
    body = ','.join([sec(gain)] + [sec(1.0)] * (sections - 1))
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

# ===================== B1-b 影子视图附加验证 =====================
# 1) 大文件防崩回归（countChars 迭代化）：>107KB 即原崩溃阈值
path_big1 = os.path.join(tmpdir, 'big1.vdc')
with open(path_big1, 'w') as f:
    f.write(build_vdc_wide(0.5, 1200))       # ~260KB
rc_big1 = set_path('ddc.load', path_big1)
size_big1 = os.path.getsize(path_big1)
check('big VDC (~%.0fKB, above old stack-overflow threshold) loads rc==0'
      % (size_big1 / 1024.0), rc_big1 == 0, 'rc=%d size=%d' % (rc_big1, size_big1))
rc, ready = get_i('ddc.ready')
check('big VDC ready == 1', rc == 0 and ready == 1, 'rc=%d ready=%d' % (rc, ready))

# 2) 大文件解析期间 RT 不被阻塞（影子视图）：~1.3MB 解析 ~30ms。
#    注意 DDCStringParser 对同内容去重——必须交替两份不同大文件，
#    否则第二次起直接早退、解析窗口空转。
path_big2 = os.path.join(tmpdir, 'big2.vdc')
with open(path_big2, 'w') as f:
    f.write(build_vdc_wide(0.5, 6000))       # ~1.3MB
path_big3 = os.path.join(tmpdir, 'big3.vdc')
with open(path_big3, 'w') as f:
    f.write(build_vdc_wide(0.25, 6000))      # 同规模，增益 0.25（内容不同）
b2 = path_big2.encode()
big2_buf = (ctypes.c_char * len(b2)).from_buffer_copy(b2)
b3 = path_big3.encode()
big3_buf = (ctypes.c_char * len(b3)).from_buffer_copy(b3)

# 回到 VDC_A（小文件）作为活动视图，停用 DDC——锁等待与 enabled 无关
# （pre-B1-b stage_ddc 每块都取锁，控制侧持锁解析即挡 RT）
assert set_path('ddc.load', path_a) == 0
set_i('ddc.enable', 0)

stop_b = threading.Event()
parsing = threading.Event()
blocks_during_parse = [0]
parse_windows = [0]
rt_max_ms_b = [0.0]
rt_crash_b = []
rt_blocks_b = [0]
big_load_errors = []


def big_load_thread():
    n = 0
    t0 = time.perf_counter()
    while time.perf_counter() - t0 < 4.0:
        buf = big2_buf if (n % 2 == 0) else big3_buf
        ln = len(b2) if (n % 2 == 0) else len(b3)
        parsing.set()
        rc = dll.auradsp_set_param(h, b'ddc.load', buf, ln)
        parsing.clear()
        parse_windows[0] += 1
        if rc != 0:
            big_load_errors.append('rc=%d' % rc)
        n += 1


def rt_thread_b():
    buf = (ctypes.c_float * (BLOCK * 2))()
    out = (ctypes.c_float * (BLOCK * 2))()
    for i in range(BLOCK):
        s = 0.4 * math.sin(2 * math.pi * 1000.0 * i / SR)
        buf[i * 2] = s
        buf[i * 2 + 1] = s
    k = 0
    while not stop_b.is_set():
        try:
            t0 = time.perf_counter()
            dll.auradsp_process(h, buf, out, BLOCK)
            dt = (time.perf_counter() - t0) * 1000.0
        except OSError as e:
            rt_crash_b.append('block %d: %s' % (k, e))
            break
        if dt > rt_max_ms_b[0]:
            rt_max_ms_b[0] = dt
        if parsing.is_set():
            blocks_during_parse[0] += 1
        k += 1
    rt_blocks_b[0] = k


t_rt_b = threading.Thread(target=rt_thread_b, daemon=True)
t_ld_b = threading.Thread(target=big_load_thread, daemon=True)
t_rt_b.start()
t_ld_b.start()
t_ld_b.join(JOIN_TIMEOUT)
ld_b_alive = t_ld_b.is_alive()
stop_b.set()
t_rt_b.join(JOIN_TIMEOUT)
rt_b_alive = t_rt_b.is_alive()

check('big load thread finished (no deadlock/hang)', not ld_b_alive)
check('rt thread B finished (no deadlock/hang)', not rt_b_alive)
check('rt B no hard fault', not rt_crash_b, str(rt_crash_b[:1]))
check('big loads all rc==0', not big_load_errors, str(big_load_errors[:3]))
per_window_b = (blocks_during_parse[0] / parse_windows[0]) if parse_windows[0] else 0.0
# 阈值标定（2026-10-24 反向验证实测）：B1-b 修复后 ~97 块/窗、最大块
# 0.43ms；pre-B1-b 持锁模拟 12 块/窗、最大块 8.74ms（=解析持锁时长）。
# ≥30/窗：修复后 3.2× 余量（RT 迭代 ~82µs 为解释器主导，跨机稳定），
# pre-B1-b 差 2.5× 必挂。<6ms：修复后 14× 余量，且 > CPython GIL 切换
# 间隔 5ms——单次解释器交接最多污染 ~5ms，不会误报；pre-B1-b 的锁等待
# 8.74ms 清晰越界。
check('rt kept producing DURING big parses (>=30 blocks/window, shadow view)',
      per_window_b >= 30,
      'blocks=%d windows=%d (%.1f/window)'
      % (blocks_during_parse[0], parse_windows[0], per_window_b))
check('rt B max block %.2fms < 6ms (no parse-induced stall)'
      % rt_max_ms_b[0], rt_max_ms_b[0] < 6.0)
print('  [info] big-file: loads=%d, rt blocks=%d, max block=%.2fms, '
      'blocks/window=%.1f, size=%.1fMB'
      % (parse_windows[0], rt_blocks_b[0], rt_max_ms_b[0], per_window_b,
         size_big1 / 1048576.0))

# 3) 解析期间旧视图持续生效（VDC_A 增益 0.5 → big3 增益 0.25，
#    切换只允许发生在换指针后）
assert set_path('ddc.load', path_a) == 0   # VDC_A 增益 0.5
assert set_i('ddc.enable', 1) == 0
stop_c = threading.Event()
mid_c = []


def rt_thread_c():
    buf = (ctypes.c_float * (BLOCK * 2))()
    out = (ctypes.c_float * (BLOCK * 2))()
    for i in range(BLOCK):
        s = 0.4 * math.sin(2 * math.pi * 1000.0 * i / SR)
        buf[i * 2] = s
        buf[i * 2 + 1] = s
    while not stop_c.is_set():
        ts = time.perf_counter()  # 块首时间戳=视图指针读取时刻（非返回后）
        dll.auradsp_process(h, buf, out, BLOCK)
        mid_c.append((ts, max(abs(out[i]) for i in range(BLOCK * 2))))


t_rt_c = threading.Thread(target=rt_thread_c, daemon=True)
t_rt_c.start()
time.sleep(0.3)
pre_c = mid_c[-1][1] if mid_c else 0.0
t0 = time.perf_counter()
rc_big3 = dll.auradsp_set_param(h, b'ddc.load', big3_buf, len(b3))
t1 = time.perf_counter()
time.sleep(0.3)
stop_c.set()
t_rt_c.join(JOIN_TIMEOUT)
# swap 发生在 [t0, t1) 内且贴近 t1（解析→装填→换指针→返回，尾部仅 µs 级）。
# 块首时间戳 t < t1-1ms 的块必读于换指针前（旧视图）；t >= t1 的块必读于
# 换指针后（新视图）——两侧窗口均与 swap 时刻解耦，断言确定性 100%。
# （历史教训：时间戳若取在 process 返回后，swap 前开始、t1 后返回的跨界块
# 会被误记入 after 窗口带旧增益，造成假失败——B1-b 首跑即踩。）
during_c = [p for (t, p) in mid_c if t0 <= t < t1 - 0.001]
after_c = [p for (t, p) in mid_c if t >= t1]
ok_during_c = bool(during_c) and all(abs(p - pre_c) < 0.02 for p in during_c)
ok_after_c = bool(after_c) and all(abs(p - 0.5 * pre_c) < 0.02 for p in after_c)
check('old view alive DURING big parse (output stays at old gain)',
      ok_during_c and rc_big3 == 0,
      'rc=%d parse=%.1fms pre=%.4f during=[%.4f..%.4f] n=%d'
      % (rc_big3, (t1 - t0) * 1000.0, pre_c,
         min(during_c) if during_c else -1, max(during_c) if during_c else -1,
         len(during_c)))
check('new view engaged AFTER swap (gain 0.5 -> 0.25)',
      ok_after_c,
      'after=[%.4f..%.4f] expect ~%.4f n=%d'
      % (min(after_c) if after_c else -1, max(after_c) if after_c else -1,
         0.5 * pre_c, len(after_c)))
print('  [info] big3 parse wall=%.1fms, %d blocks during, %d after '
      '(during@old=%d, after@new=%d)'
      % ((t1 - t0) * 1000.0, len(during_c), len(after_c),
         sum(1 for p in during_c if abs(p - pre_c) < 0.02),
         sum(1 for p in after_c if abs(p - 0.5 * pre_c) < 0.02)))

# 4) 停流连发加载全部成功（ddcInFlight==0 守卫；pre-B1 设计下第 3 次起
#    全因 ddcProcCount 冻结而「引擎忙」且重试无用）。交替两份防去重。
rapid_rcs = []
rapid_max_ms = 0.0
for i in range(5):
    buf = big2_buf if (i % 2 == 0) else big3_buf
    ln = len(b2) if (i % 2 == 0) else len(b3)
    t0 = time.perf_counter()
    rc = dll.auradsp_set_param(h, b'ddc.load', buf, ln)
    rapid_max_ms = max(rapid_max_ms, (time.perf_counter() - t0) * 1000.0)
    rapid_rcs.append(rc)
check('stalled-audio rapid loads all succeed (ddcInFlight==0 guard)',
      all(rc == 0 for rc in rapid_rcs), 'rcs=%s' % rapid_rcs)
check('stalled-audio rapid loads bounded (<1500ms each)', rapid_max_ms < 1500.0,
      'max=%.0fms' % rapid_max_ms)
print('  [info] rapid ddc loads rcs=%s max_wall=%.0fms' % (rapid_rcs, rapid_max_ms))

# 恢复小文件 + 使能，收尾健康
assert set_path('ddc.load', path_a) == 0
set_i('ddc.enable', 1)
ok_tail2 = True
for _ in range(32):
    dll.auradsp_process(h, sig, out_on, BLOCK)
    for i in range(0, BLOCK * 2, 8):
        v = out_on[i]
        if v != v or v > 1e6 or v < -1e6:
            ok_tail2 = False
check('engine still healthy after B1-b section', ok_tail2)

dll.auradsp_destroy(h)
shutil.rmtree(tmpdir, ignore_errors=True)

print()
if FAIL:
    print('DDC RACE FAILURES:', FAIL)
    sys.exit(1)
print('ddc race: all checks passed')
