"""smoke_liveprog_race.py — liveprog 影子 VM 编译门禁（B1）。

背景（全量审查 B1/P0）：原 LiveProgStringParser 持 jdsp_lock 做 NSEEL
编译（大脚本实测 ~38ms，用户自述可达 ≥2s），而 kAuraStages liveprog
lock=1 令 RT 的 stage_liveprog 每块取同一把锁——编译期间 RT 在
EnterCriticalSection 上无限期等待 ⇒ 整段音频卡死（「加载脚本时卡顿」）。

B1 修法：控制侧编译到影子 VM（3 槽预分配）+ 块边界原子换 jdsp->eel
指针（P-006 范式）；RT 块首只读一次快照，stage lock 标志置 0。

本测试以多线程复刻该时序（ctypes 外部调用释放 GIL，真实并发）：
  - 「RT 线程」：连续 auradsp_process，逐块记录墙钟（检测锁等待尖峰），
    全程扫描输出有限性；
  - 「UI 线程」：交替加载重脚本（~38ms 编译）/坏脚本/变增益脚本 +
    enable 开关，复刻用户操作序列；
  - 关键断言：① 编译窗口内 RT 仍在产出块（pre-B1 实测为 0——全被锁挡住）；
    ② 单块墙钟无编译级尖峰；③ 编译期间输出保持旧脚本增益（旧快照存活），
    编译完成后才切新增益；④ 坏脚本不杀活动脚本；⑤ 音频停流后连发加载走
    有界等待，返回 0 或 -4（引擎忙）而不崩不挂；⑥ 收尾引擎健康。

通过标准：进程存活 + 全部线程超时前结束 + 上述断言全过。
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
BLOCK = 480
UI_SECONDS = 6.0
JOIN_TIMEOUT = 20.0
BLOCK_STALL_FLOOR_MS = 5.0   # 墙钟地板：吸收批量连跑时的系统调度噪声
BLOCK_STALL_RATIO = 4.0      # 相对基线放大倍数（pre-B1 尖峰 ~51ms 仍必红）
BLOCKS_MIN = 5000            # RT 总产出下界（pre-B1 实测 ~400；post-B1 ~74k）
BLOCKS_PER_COMPILE_MIN = 5   # 编译窗口内 RT 产出/窗口下界（pre-B1 ~1.5；post-B1 ~300）
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
dll.auradsp_last_error.restype = ctypes.c_char_p
dll.auradsp_last_error.argtypes = [ctypes.c_void_p]
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


def set_str(pid, s):
    b = s.encode('utf-8')
    buf = (ctypes.c_char * len(b)).from_buffer_copy(b)
    return dll.auradsp_set_param(h, pid.encode(), buf, len(b))


def get_i(pid):
    v = ctypes.c_int32()
    dll.auradsp_get_param(h, pid.encode(), ctypes.byref(v), 4)
    return v.value


def make_script(gain, nstmt=0):
    """gain 增益脚本；nstmt>0 时生成大 @init（拉长编译时间）。"""
    lines = ['@init', 'g = 1;']
    if nstmt:
        expr = ('sin(cos(tan(asin(acos(atan({i}+0.5))))))*2 + sin(cos(tan({i})))*3'
                ' + log(exp({i}+1))*0.5 + sqrt(abs({i})+1)')
        for i in range(nstmt):
            lines.append('g = %s;' % expr.format(i=i))
    lines.append('@sample')
    lines.append('spl0 *= %r;' % gain)
    lines.append('spl1 *= %r;' % gain)
    return '\n'.join(lines)


SCRIPT_A = make_script(0.5)
SCRIPT_B = make_script(0.25)
SCRIPT_HEAVY = make_script(0.5, nstmt=2000)   # ~227KB，实测编译 ~38ms
SCRIPT_BAD = '@init\nthis is not eel (((\n@sample\nspl0 *= 2;\n'

N = BLOCK
buf = (ctypes.c_float * (N * 2))()
out = (ctypes.c_float * (N * 2))()
for i in range(N):
    s = 0.4 * math.sin(2 * math.pi * 1000.0 * i / SR)
    buf[i * 2] = s
    buf[i * 2 + 1] = s

# 预构建 ctypes 参数对象（循环内零分配）
heavy_b = SCRIPT_HEAVY.encode()
heavy_buf = (ctypes.c_char * len(heavy_b)).from_buffer_copy(heavy_b)
a_b = SCRIPT_A.encode()
a_buf = (ctypes.c_char * len(a_b)).from_buffer_copy(a_b)
b_b = SCRIPT_B.encode()
b_buf = (ctypes.c_char * len(b_b)).from_buffer_copy(b_b)
bad_b = SCRIPT_BAD.encode()
bad_buf = (ctypes.c_char * len(bad_b)).from_buffer_copy(bad_b)

# ---- Phase 0：基线（RT 独占） ----
base_max_ms = 0.0
for _ in range(200):
    t0 = time.perf_counter()
    dll.auradsp_process(h, buf, out, N)
    dt = (time.perf_counter() - t0) * 1000.0
    if dt > base_max_ms:
        base_max_ms = dt
print('  [info] baseline max block = %.3f ms' % base_max_ms)

# ---- Phase 1：加载 A（增益 0.5）并使能 ----
assert set_str('liveprog.code', SCRIPT_A) == 0
assert set_f('liveprog.param1', 1.0) == 0
assert set_i('liveprog.enable', 1) == 0
for _ in range(64):
    dll.auradsp_process(h, buf, out, N)
peak_a = max(abs(out[i]) for i in range(N * 2))
print('  [info] script A peak = %.4f (expect ~0.2)' % peak_a)
check('script A active (peak ~0.2)', abs(peak_a - 0.2) < 0.01, 'peak=%.4f' % peak_a)

# ---- Phase 2：RT 线程 × UI 线程并发 ----
stop = threading.Event()
compiling = threading.Event()          # UI 线程编译窗口标志
blocks_during_compile = [0]
compile_windows = [0]
rt_max_ms = [0.0]
rt_nonfinite = []
rt_crash = []
rt_blocks = [0]
ui_errors = []
ui_rcs = []


def ui_thread():
    """复刻用户操作：重脚本×8（编译窗口）→ 坏脚本×2 → B（变增益）→ 重脚本×4。"""
    t0 = time.perf_counter()
    n = 0
    while time.perf_counter() - t0 < UI_SECONDS:
        for _ in range(8):
            compiling.set()
            rc = dll.auradsp_set_param(h, b'liveprog.code', heavy_buf, len(heavy_b))
            compiling.clear()
            ui_rcs.append(('heavy', rc))
            compile_windows[0] += 1
            if rc != 0:
                ui_errors.append('heavy rc=%d' % rc)
        for _ in range(2):
            rc = dll.auradsp_set_param(h, b'liveprog.code', bad_buf, len(bad_b))
            ui_rcs.append(('bad', rc))
            if rc == 0:
                ui_errors.append('bad script accepted!')
        rc = dll.auradsp_set_param(h, b'liveprog.code', b_buf, len(b_b))
        ui_rcs.append(('B', rc))
        if rc != 0:
            ui_errors.append('B rc=%d' % rc)
        if n % 3 == 0:
            en = i32(0)
            dll.auradsp_set_param(h, b'liveprog.enable', ctypes.byref(en), 4)
            en = i32(1)
            dll.auradsp_set_param(h, b'liveprog.enable', ctypes.byref(en), 4)
        n += 1


def rt_thread():
    k = 0
    while not stop.is_set():
        try:
            t0 = time.perf_counter()
            dll.auradsp_process(h, buf, out, N)
            dt = (time.perf_counter() - t0) * 1000.0
        except OSError as e:
            rt_crash.append('block %d: %s' % (k, e))
            break
        if dt > rt_max_ms[0]:
            rt_max_ms[0] = dt
        if compiling.is_set():
            blocks_during_compile[0] += 1
        if (k & 15) == 0:
            for i in range(0, N * 2, 4):
                v = out[i]
                if v != v or v > 1e6 or v < -1e6:
                    rt_nonfinite.append(k)
                    break
        k += 1
    rt_blocks[0] = k


t_rt = threading.Thread(target=rt_thread, daemon=True)
t_ui = threading.Thread(target=ui_thread, daemon=True)
t_rt.start()
t_ui.start()
t_ui.join(JOIN_TIMEOUT)
ui_alive = t_ui.is_alive()
stop.set()
t_rt.join(JOIN_TIMEOUT)
rt_alive = t_rt.is_alive()

check('ui thread finished (no deadlock/hang)', not ui_alive,
      'alive after %.0fs' % JOIN_TIMEOUT)
check('rt thread finished (no deadlock/hang)', not rt_alive,
      'alive after %.0fs' % JOIN_TIMEOUT)
check('rt no hard fault (access violation)', not rt_crash, str(rt_crash[:1]))
check('rt output always finite', not rt_nonfinite,
      'first bad block=%s' % (rt_nonfinite[0] if rt_nonfinite else None))
check('ui: heavy/bad script results as expected', not ui_errors, str(ui_errors[:3]))
check('rt produced audio during race (blocks>%d)' % BLOCKS_MIN,
      rt_blocks[0] > BLOCKS_MIN, 'blocks=%d' % rt_blocks[0])

# B1 核心断言 1：编译窗口内 RT 仍在产出（pre-B1 持锁编译期间每窗口仅 ~1.5 块）
per_window = (blocks_during_compile[0] / compile_windows[0]) if compile_windows[0] else 0.0
check('rt kept producing DURING compiles (>=%d blocks/window, shadow VM no lock wait)'
      % BLOCKS_PER_COMPILE_MIN, per_window >= BLOCKS_PER_COMPILE_MIN,
      'blocks_during_compile=%d over %d compile windows (%.1f/window)'
      % (blocks_during_compile[0], compile_windows[0], per_window))

# B1 核心断言 2：单块墙钟无编译级尖峰（38ms 编译若阻塞 RT 会出现 ~38ms 块）。
# T-04：阈值相对本次进程的基线块耗时，而非固定 15ms 墙钟——批量连跑时
# 前序用例余温/系统调度会把正常块推到 10ms+，固定阈值误报；pre-B1 的
# ~51ms 尖峰对任何合理基线仍会判红。
stall_limit_ms = max(BLOCK_STALL_FLOOR_MS, base_max_ms * BLOCK_STALL_RATIO)
check('rt max block %.1fms < %.1fms (baseline %.3fms x%.0f, no compile-induced stall)'
      % (rt_max_ms[0], stall_limit_ms, base_max_ms, BLOCK_STALL_RATIO),
      rt_max_ms[0] < stall_limit_ms)

# B1 核心断言 3：编译完成后新脚本生效（A 0.5 → B 0.25）
for _ in range(64):
    dll.auradsp_process(h, buf, out, N)
peak_b = max(abs(out[i]) for i in range(N * 2))
check('script B took effect after race (peak ~0.1)', abs(peak_b - 0.1) < 0.01,
      'peak=%.4f' % peak_b)

# 坏脚本不杀活动脚本：状态仍为 1 且音频继续按 B 处理
st = get_i('liveprog.status')
check('bad scripts did not kill active script (status==1)', st == 1, 'status=%d' % st)

# ---- Phase 3：编译期间旧快照存活的语义验证（串行精确复刻） ----
# 加载 A → 起 RT → 编译 HEAVY（sample 段增益同为 0.5，仅 @init 变大） →
# 编译窗口内输出必须保持编译前增益（旧快照存活）；完成后才允许变化。
stop2 = threading.Event()
mid = []          # (t, peak) 时间戳序列


def rt_thread2():
    while not stop2.is_set():
        dll.auradsp_process(h, buf, out, N)
        mid.append((time.perf_counter(), max(abs(out[i]) for i in range(N * 2))))


t_rt2 = threading.Thread(target=rt_thread2, daemon=True)
t_rt2.start()
time.sleep(0.2)
pre = mid[-1][1] if mid else 0.0
t0 = time.perf_counter()
rc = dll.auradsp_set_param(h, b'liveprog.code', heavy_buf, len(heavy_b))
t1 = time.perf_counter()
time.sleep(0.1)
stop2.set()
t_rt2.join(JOIN_TIMEOUT)
during = [p for (t, p) in mid if t0 <= t < t1]
ok_during = bool(during) and all(abs(p - pre) < 0.02 for p in during)
check('old snapshot alive DURING compile (output tracks pre-compile gain)',
      ok_during and rc == 0,
      'rc=%d compile=%.1fms pre=%.4f during=[%.4f..%.4f] n=%d'
      % (rc, (t1 - t0) * 1000.0, pre,
         min(during) if during else -1, max(during) if during else -1, len(during)))
print('  [info] heavy compile wall time = %.1f ms, %d blocks during'
      % ((t1 - t0) * 1000.0, len(during)))

# ---- Phase 4：音频停流后连发加载 → inFlight==0 守卫放行，全部成功不挂 ----
# （pre-B1 设计下第 3 次起会因 eelProcCount 冻结全部「引擎忙」；B1 的
#  eelInFlight==0 双条件修复了该可用性洞。）
rapid_rcs = []
rapid_max_ms = 0.0
for _ in range(5):
    t0 = time.perf_counter()
    rc = dll.auradsp_set_param(h, b'liveprog.code', a_buf, len(a_b))
    dt = (time.perf_counter() - t0) * 1000.0
    rapid_max_ms = max(rapid_max_ms, dt)
    rapid_rcs.append(rc)
    if rc != 0:
        # 唯一可接受的失败：-4 引擎忙（auradsp 层统一映射为 E_PARAM=-1，
        # 以 status=-4 + 文案区分于语法错误）
        st = get_i('liveprog.status')
        err = dll.auradsp_last_error(h).decode()
        check('rapid load failure is engine-busy not syntax error',
              st == -4 and 'busy' in err.lower(), 'status=%d err=%r' % (st, err))
check('stalled-audio rapid loads all succeed (inFlight==0 guard)',
      all(rc == 0 for rc in rapid_rcs), 'rcs=%s' % rapid_rcs)
check('stalled-audio rapid loads bounded (<1500ms each)', rapid_max_ms < 1500.0,
      'max=%.0fms' % rapid_max_ms)
print('  [info] rapid rcs=%s max_wall=%.0fms' % (rapid_rcs, rapid_max_ms))

# RT 恢复流动后槽放行，一次加载即成功
t_rt3 = threading.Thread(target=lambda: [dll.auradsp_process(h, buf, out, N)
                                         for _ in range(200)], daemon=True)
t_rt3.start()
t_rt3.join(JOIN_TIMEOUT)
rc = dll.auradsp_set_param(h, b'liveprog.code', a_buf, len(a_b))
check('slot released after blocks flow again (rc==0)', rc == 0, 'rc=%d' % rc)

# ---- Phase 5：收尾健康检查 ----
set_i('liveprog.enable', 0)
ok_tail = True
for _ in range(32):
    dll.auradsp_process(h, buf, out, N)
    for i in range(0, N * 2, 8):
        v = out[i]
        if v != v or v > 1e6 or v < -1e6:
            ok_tail = False
peak_off = max(abs(out[i]) for i in range(N * 2))
check('engine still healthy after race', ok_tail)
check('disabled liveprog = passthrough (peak ~0.4)', abs(peak_off - 0.4) < 0.02,
      'peak=%.4f' % peak_off)

dll.auradsp_destroy(h)

print()
print('  [info] rt blocks=%d, max block=%.2fms (baseline %.3fms), '
      'blocks during %d compiles=%d'
      % (rt_blocks[0], rt_max_ms[0], base_max_ms, compile_windows[0],
         blocks_during_compile[0]))
if FAIL:
    print('LIVEPROG RACE FAILURES:', FAIL)
    sys.exit(1)
print('liveprog race (B1 shadow VM): all checks passed')
