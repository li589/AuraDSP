"""smoke_comp_race.py — compander 控制线程/RT 线程竞争门禁（Z13 → B1-c）。

背景（2026-10-23 崩溃调查）：minidump auradsp_app.exe.16656.dmp 定位到
dynamic.c 生产侧 `mOutputBuffer[mOutputBufferCount - 1]` 索引 -1 空写
（movss [rsi],xmm0，rsi=0）。源码枚举全部 count 赋值点后确认唯一致负路径：
CompressorSetParam(forceRefresh=1) 在控制线程执行 FFTCompanderInit 把
mOutputBufferCount 置 0，与 RT 消耗循环 `while(count>0) → count--` 之间
无互斥——RT 通过 while 检查后、count-- 前被置 0，即减成 -1；下一帧生产侧
count++ 归 0 后取 mOutputBuffer[-1] 越界。日志坐实场景：用户连续拖
comp.gain 滑块（11:58:25-27 三条 setParam 后 0.8s 内崩溃），与用户报告
「效果器调节时闪退」吻合。

本测试以多线程复刻该时序（ctypes 外部调用释放 GIL，各线程真实并发）：
  - 「UI 线程 A」：高频 auradsp_set_param(comp.gain1..7) 模拟拖滑块；
  - 「UI 线程 B」：comp.timeconstant/granularity/tfresolution + enable
    开关（结构变更 → FFTCompanderInit 全量重算路径）；
  - 「RT 线程」：连续 auradsp_process 灌入固定缓冲，抽样扫描输出有限性。
两侧 C 段占比越高竞争窗口命中率越高（Python 侧已极致精简：缓冲预分配、
ctypes 参数对象预构建、扫描抽样）。

修复前（RT comp stage 无锁 + 控制侧只持 ctrl_mutex）该竞争为进程级访问
违例——本测试进程会直接死亡，runner 报非零退出。Z13 修复（kAuraStages
comp lock=1 + multiplexed RT 路径 honoring lock + apply_comp 同锁）用互斥
关闭了竞争，但持锁时长 = FFTCompanderInit 全量重算时长（默认 tfres=1
CWT 为重档），参数频调时 RT 反复阻塞在 EnterCriticalSection——只修了
竞争，没修等待时长（全量审查 B1/P0）。

B1-c 修复（2026-10-24）：控制侧改影子构建 + 原子换指针（CompSlot 双缓冲，
同 B1-a liveprog / B1-b ddc 范式），stage_comp lock 置 0。本测试在 Z13
断言基础上新增 RT 不阻塞度量：
  - rt blocks/window：UI  hammering 期间 RT 块吞吐（Z13 下 RT 每块都要
    等控制侧释放 jdsp_lock，吞吐塌陷；B1-c 下 RT 永不因 comp 取锁）；
  - rt max block：单块墙钟尖峰（Z13 下单块可被锁挡整个 Init 时长；
    B1-c 下单块只含正常 DSP + 调度噪声）。
阈值经反向验证标定（临时还原 Z13 持锁行为重建 DLL，两项须失败）。
通过标准：进程存活 + 输出全程有限 + 全部线程在超时前正常结束（无死锁）
+ RT 不阻塞两项。
"""
import ctypes
import math
import os
import sys
import threading
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DLL = os.path.join(ROOT, 'core', 'desktop', 'windows', 'out', 'Release',
                   'auradsp_engine.dll')

SR = 48000.0
BLOCK = 512
UI_SECONDS = 6.0          # UI 线程连续拖参数时长
JOIN_TIMEOUT = 20.0       # 死锁防御：超时即失败
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
dll.auradsp_destroy.argtypes = [ctypes.c_void_p]

h = dll.auradsp_create(SR, BLOCK)
assert h, 'create failed'


def i32(v):
    return ctypes.c_int32(v)


def f32(v):
    return ctypes.c_float(v)


def set_i(pid, v):
    return dll.auradsp_set_param(h, pid.encode(), ctypes.byref(i32(v)), 4)


def set_f(pid, v):
    return dll.auradsp_set_param(h, pid.encode(), ctypes.byref(f32(v)), 4)


# 预热：开压限 + 非零增益，让 compander 流水进入 count>0 的稳定产出态
set_i('comp.enable', 1)
for g in range(7):
    set_f('comp.gain%d' % (g + 1), -0.2 + 0.05 * g)
warm = (ctypes.c_float * (BLOCK * 2))()
wout = (ctypes.c_float * (BLOCK * 2))()
for i in range(BLOCK):
    warm[i * 2] = warm[i * 2 + 1] = 0.5 * math.sin(2 * math.pi * 1000.0 * i / SR)
for _ in range(64):
    dll.auradsp_process(h, warm, wout, BLOCK)

stop = threading.Event()
rt_nonfinite = []      # RT 线程记录的首个非有限输出块序号
rt_crash = []          # RT 线程内访问违例等硬故障（竞争致死的直接证据）
rt_blocks = [0]
rt_max_block_ms = [0.0]   # B1-c：单块墙钟尖峰（Z13 下可被锁挡整个 Init 时长）
rt_blocks_per_sec = [0.0] # B1-c：UI hammering 期间 RT 块吞吐
uiA_calls = [0]
uiB_calls = [0]
ui_errors = []


def ui_thread_a():
    """模拟 UI 线程拖 comp.gain 滑块（崩溃复现的直接触发参数）。
    ctypes 参数对象全部预构建，循环内只改 .value——把 Python 侧开销
    压到最低，使控制线程几乎全时停在 C 段的 FFTCompanderInit 内。"""
    cells = []
    for g in range(7):
        c = f32(-0.2)
        cells.append((('comp.gain%d' % (g + 1)).encode(), c, ctypes.byref(c)))
    n = 0
    t0 = time.perf_counter()
    while time.perf_counter() - t0 < UI_SECONDS:
        for name, c, ref in cells:
            c.value = -1.2 + 2.4 * ((n * 37 + int(name[-1:]) * 53) % 100) / 100.0
            rc = dll.auradsp_set_param(h, name, ref, 4)
            if rc != 0:
                ui_errors.append('A gain rc=%d' % rc)
        n += 1
    uiA_calls[0] = n


def ui_thread_b():
    """模拟 UI 线程调结构参数：timeconstant/granularity/tfresolution +
    enable 开关（CompressorEnable 的 compForceRefresh / Disable 路径）。"""
    cells = []
    for name in ('comp.timeconstant', 'comp.granularity', 'comp.tfresolution'):
        c = i32(0) if name != 'comp.timeconstant' else f32(0.1)
        cells.append((name.encode(), c, ctypes.byref(c)))
    en = i32(1)
    en_ref = ctypes.byref(en)
    n = 0
    t0 = time.perf_counter()
    while time.perf_counter() - t0 < UI_SECONDS:
        # timeconstant 0.02..0.5
        cells[0][1].value = 0.02 + 0.48 * ((n * 61) % 100) / 100.0
        cells[1][1].value = n % 5
        cells[2][1].value = (n // 5) % 4
        for name, c, ref in cells:
            rc = dll.auradsp_set_param(h, name, ref, 4)
            if rc != 0:
                ui_errors.append('B struct rc=%d' % rc)
        if n % 97 == 0:
            en.value = 0
            dll.auradsp_set_param(h, b'comp.enable', en_ref, 4)
            en.value = 1
            dll.auradsp_set_param(h, b'comp.enable', en_ref, 4)
        n += 1
    uiB_calls[0] = n


def rt_thread():
    """模拟 RT 音频回调：预分配缓冲连续 process，每 64 块抽样扫描有限性。
    B1-c：逐块记录墙钟（max block）+ 总块数/总时长（blocks per sec）——
    RT 若每块都要等控制侧释放 jdsp_lock（Z13），这两项会暴露等待时长。"""
    buf = (ctypes.c_float * (BLOCK * 2))()
    out = (ctypes.c_float * (BLOCK * 2))()
    for i in range(BLOCK):
        s = 0.4 * math.sin(2 * math.pi * 1000.0 * i / SR)
        s += 0.05 * (((i * 2654435761) % 1000) / 1000.0 - 0.5)
        buf[i * 2] = s
        buf[i * 2 + 1] = s
    k = 0
    t_first = None
    t_last = None
    while not stop.is_set():
        t0 = time.perf_counter()
        try:
            dll.auradsp_process(h, buf, out, BLOCK)
        except OSError as e:
            # 访问违例等硬故障：竞争致死的直接证据（修复前实测复现：
            # access violation reading 0x……，mOutputBuffer 指针表被
            # 控制线程 FFTCompanderInit 与 RT 移位循环争抢后读出野指针）。
            rt_crash.append('block %d: %s' % (k, e))
            break
        t1 = time.perf_counter()
        if t_first is None:
            t_first = t0
        t_last = t1
        block_ms = (t1 - t0) * 1000.0
        if block_ms > rt_max_block_ms[0]:
            rt_max_block_ms[0] = block_ms
        if (k & 63) == 0:
            for i in range(0, BLOCK * 2, 8):
                v = out[i]
                if v != v or v > 1e6 or v < -1e6:
                    rt_nonfinite.append(k)
                    break
        k += 1
    rt_blocks[0] = k
    if t_first is not None and t_last > t_first:
        rt_blocks_per_sec[0] = k / (t_last - t_first)


t_a = threading.Thread(target=ui_thread_a, daemon=True)
t_b = threading.Thread(target=ui_thread_b, daemon=True)
t_rt = threading.Thread(target=rt_thread, daemon=True)
t_rt.start()
t_a.start()
t_b.start()
t_a.join(JOIN_TIMEOUT)
a_alive = t_a.is_alive()
t_b.join(JOIN_TIMEOUT)
b_alive = t_b.is_alive()
stop.set()
t_rt.join(JOIN_TIMEOUT)
rt_alive = t_rt.is_alive()

check('ui thread A finished (no deadlock/hang)', not a_alive,
      'alive after %.0fs' % JOIN_TIMEOUT)
check('ui thread B finished (no deadlock/hang)', not b_alive,
      'alive after %.0fs' % JOIN_TIMEOUT)
check('rt thread finished (no deadlock/hang)', not rt_alive,
      'alive after %.0fs' % JOIN_TIMEOUT)
check('ui set_param all rc==0', not ui_errors, str(ui_errors[:3]))
check('rt no hard fault (access violation)', not rt_crash, str(rt_crash[:1]))
check('rt output always finite', not rt_nonfinite,
      'first bad block=%s' % (rt_nonfinite[0] if rt_nonfinite else None))
check('rt produced audio (blocks>1000)', rt_blocks[0] > 1000, 'blocks=%d' % rt_blocks[0])
check('ui A hammered gains (sweeps>50)', uiA_calls[0] > 50, 'sweeps=%d' % uiA_calls[0])
check('ui B hammered struct params (iters>50)', uiB_calls[0] > 50, 'iters=%d' % uiB_calls[0])
# B1-c：RT 不阻塞两项。Z13 下 RT 的 stage_comp 每块取 jdsp_lock，而持锁方
# 在做全量 FFTCompanderInit（默认 tfres=1 CWT 重档，实测 ~10ms 级）——
# 块吞吐塌陷 + 单块尖峰达到 Init 时长。反向验证（还原持锁行为）时两项失败。
check('rt throughput not collapsed (blocks/s>=800)', rt_blocks_per_sec[0] >= 800,
      'blocks/s=%.0f' % rt_blocks_per_sec[0])
check('rt max block no lock-wait spike (<10ms)', rt_max_block_ms[0] < 10.0,
      'max=%.2fms' % rt_max_block_ms[0])
print('  [info] uiA sweeps=%d, uiB iters=%d, rt blocks=%d, rt blocks/s=%.0f, rt max block=%.2fms'
      % (uiA_calls[0], uiB_calls[0], rt_blocks[0], rt_blocks_per_sec[0], rt_max_block_ms[0]))

# 收尾：竞争测试后引擎仍可用（无状态损坏残留）
set_i('comp.enable', 1)
ok_tail = True
for _ in range(32):
    dll.auradsp_process(h, warm, wout, BLOCK)
    for i in range(0, BLOCK * 2, 8):
        v = wout[i]
        if v != v or v > 1e6 or v < -1e6:
            ok_tail = False
check('engine still healthy after race', ok_tail)

dll.auradsp_destroy(h)

print()
if FAIL:
    print('COMP RACE FAILURES:', FAIL)
    sys.exit(1)
print('comp race: all checks passed')
