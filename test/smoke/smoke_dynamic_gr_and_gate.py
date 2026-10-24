"""smoke_dynamic_gr_and_gate.py — 动态效果器高级参数（Gate 迟滞/底线/Hold，Dyneq 三频段独立时间）与实时增益衰减（GR）计量管道验收。

验收标准：
  1. Gate 新参数 set/get 对称性与边界钳位：
     - gate.hysteresis [0, 12] dB
     - gate.range [-80, 0] dB
     - gate.hold / gate.hold_ms [0, 500] ms
  2. Dyneq 三频段独立双时间常数：
     - dyneq.b1/b2/b3.attack/release 独立读写
     - 别名支持 (low/mid/high, band1/band2/band3)
     - 全局 dyneq.attack/release 向后兼容广播
  3. Gate DSP 迟滞区间 (Hysteresis) 防抖动：
     - 门限=-30dBFS, 迟滞=6dB (开门=-30dBFS, 关门=-36dBFS)
     - 信号在 -33dBFS (滞后区间内)：从静音启动保持关闭；从开门后下降则保持开启
  4. Gate DSP 衰减底线 (Range Floor)：
     - range=-20dB 时，门完全关闭后的衰减被限制在 ~20dB，不切断底噪
  5. 实时增益衰减 (GR) 计量管道：
     - Limiter GR (gr.limiter): 大幅值阶跃输入 (>0dBFS) 产生精准衰减读数
     - Compressor GR (gr.comp): 压缩器工作时提供分贝级衰减读数
     - Gate GR (gr.gate): 门控衰减时提供分贝级衰减读数
     - Dyneq GR (gr.dyneq, gr.dyneq.low/mid/high): 各频段独立衰减读数与频段选择性
  6. SPSC VizFrame 桥接：
     - auradsp_viz_frame 槽位 24..29 精确对应 Limiter/Comp/Gate/Dyneq(3) GR 分贝值
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


def check(name, cond, detail=''):
    msg = ('PASS  ' if cond else 'FAIL  ') + name
    if detail and not cond:
        msg += f'  ({detail})'
    print(msg)
    if not cond:
        FAIL.append(name)


# --- VizFrame 单一来源（§7-1 ABI 镜像门禁）---
# ctypes 镜像只在 tools/bin/viz_frame.py 定义一次，这里不再手抄。
# 手抄件的危险：头文件 sizeof 改了却漏改某个脚本 → 脚本按旧尺寸申请缓冲、
# 引擎按新尺寸写 → 静默堆越界（审查 A1/A2/A3 三处即此）。viz_frame 导入时
# 自带 sizeof / ABI 版本哨兵，出错就地抛 AssertionError。
_VIZ_ROOT = os.path.dirname(os.path.abspath(__file__))
while not os.path.isfile(os.path.join(_VIZ_ROOT, 'tools', 'bin', 'viz_frame.py')):
    _VIZ_PARENT = os.path.dirname(_VIZ_ROOT)
    if _VIZ_PARENT == _VIZ_ROOT:
        raise ImportError('未找到 tools/bin/viz_frame.py（VizFrame 的唯一定义处）')
    _VIZ_ROOT = _VIZ_PARENT
if os.path.join(_VIZ_ROOT, 'tools', 'bin') not in sys.path:
    sys.path.insert(0, os.path.join(_VIZ_ROOT, 'tools', 'bin'))
from viz_frame import VizFrame  # noqa: E402


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
dll.auradsp_viz_read.restype = ctypes.c_uint32
dll.auradsp_viz_read.argtypes = [ctypes.c_void_p, ctypes.POINTER(VizFrame), ctypes.c_uint32]
dll.auradsp_destroy.argtypes = [ctypes.c_void_p]

h = dll.auradsp_create(SR, BLOCK)
assert h, 'create failed'


def set_i(pid, v):
    return dll.auradsp_set_param(h, pid.encode(), ctypes.byref(ctypes.c_int32(v)), 4)


def set_f(pid, v):
    return dll.auradsp_set_param(h, pid.encode(), ctypes.byref(ctypes.c_float(v)), 4)


def get_f(pid):
    v = ctypes.c_float(0.0)
    rc = dll.auradsp_get_param(h, pid.encode(), ctypes.byref(v), 4)
    return rc, v.value


def get_i(pid):
    v = ctypes.c_int32(0)
    rc = dll.auradsp_get_param(h, pid.encode(), ctypes.byref(v), 4)
    return rc, v.value


def reset_engine():
    # 禁用所有效果器
    for fx in ['gate.enable', 'comp.enable', 'dyneq.enable', 'limiter.enable',
               'tube.enable', 'exciter.enable', 'bass.enable', 'eq.enable']:
        set_i(fx, 0)
    set_f('input.gain', 0.0)
    set_f('post.gain', 0.0)


# =========================================================================
# 1. Gate 新参数 set/get 对称性与钳位
# =========================================================================
print("--- 1. Gate Hysteresis, Range & Hold Parameters ---")
check("gate.hysteresis default/set/get",
      set_f("gate.hysteresis", 4.5) == 0 and abs(get_f("gate.hysteresis")[1] - 4.5) < 1e-4)
set_f("gate.hysteresis", -5.0)
check("gate.hysteresis clamp low", abs(get_f("gate.hysteresis")[1] - 0.0) < 1e-4)
set_f("gate.hysteresis", 20.0)
check("gate.hysteresis clamp high", abs(get_f("gate.hysteresis")[1] - 12.0) < 1e-4)

check("gate.range set/get",
      set_f("gate.range", -35.0) == 0 and abs(get_f("gate.range")[1] - (-35.0)) < 1e-4)
set_f("gate.range", -100.0)
check("gate.range clamp low", abs(get_f("gate.range")[1] - (-80.0)) < 1e-4)
set_f("gate.range", 10.0)
check("gate.range clamp high", abs(get_f("gate.range")[1] - 0.0) < 1e-4)

check("gate.hold_ms set/get",
      set_f("gate.hold_ms", 75.0) == 0 and abs(get_f("gate.hold_ms")[1] - 75.0) < 1e-4)
check("gate.hold alias set/get",
      set_f("gate.hold", 120.0) == 0 and abs(get_f("gate.hold_ms")[1] - 120.0) < 1e-4)
set_f("gate.hold_ms", -10.0)
check("gate.hold clamp low", abs(get_f("gate.hold_ms")[1] - 0.0) < 1e-4)
set_f("gate.hold_ms", 600.0)
check("gate.hold clamp high", abs(get_f("gate.hold_ms")[1] - 500.0) < 1e-4)


# =========================================================================
# 2. Dyneq 三频段独立双时间常数与广播
# =========================================================================
print("\n--- 2. Dyneq Independent Band Attack/Release & Broadcast ---")
check("dyneq.b1.attack set/get",
      set_f("dyneq.b1.attack", 25.0) == 0 and abs(get_f("dyneq.b1.attack")[1] - 25.0) < 1e-4)
check("dyneq.b1.release set/get",
      set_f("dyneq.b1.release", 300.0) == 0 and abs(get_f("dyneq.b1.release")[1] - 300.0) < 1e-4)
check("dyneq.low.attack alias", abs(get_f("dyneq.low.attack")[1] - 25.0) < 1e-4)
check("dyneq.band1.release alias", abs(get_f("dyneq.band1.release")[1] - 300.0) < 1e-4)

check("dyneq.b2.attack set/get",
      set_f("dyneq.b2.attack", 12.0) == 0 and abs(get_f("dyneq.b2.attack")[1] - 12.0) < 1e-4)
check("dyneq.b2.release set/get",
      set_f("dyneq.b2.release", 80.0) == 0 and abs(get_f("dyneq.b2.release")[1] - 80.0) < 1e-4)

check("dyneq.b3.attack set/get",
      set_f("dyneq.b3.attack", 1.5) == 0 and abs(get_f("dyneq.b3.attack")[1] - 1.5) < 1e-4)
check("dyneq.b3.release set/get",
      set_f("dyneq.b3.release", 25.0) == 0 and abs(get_f("dyneq.b3.release")[1] - 25.0) < 1e-4)

# 全局 dyneq.attack / dyneq.release 广播验证
set_f("dyneq.attack", 5.0)
check("dyneq.attack broadcast to b1/b2/b3",
      abs(get_f("dyneq.b1.attack")[1] - 5.0) < 1e-4 and
      abs(get_f("dyneq.b2.attack")[1] - 5.0) < 1e-4 and
      abs(get_f("dyneq.b3.attack")[1] - 5.0) < 1e-4)

set_f("dyneq.release", 220.0)
check("dyneq.release broadcast to b1/b2/b3",
      abs(get_f("dyneq.b1.release")[1] - 220.0) < 1e-4 and
      abs(get_f("dyneq.b2.release")[1] - 220.0) < 1e-4 and
      abs(get_f("dyneq.b3.release")[1] - 220.0) < 1e-4)


# =========================================================================
# 3. Gate DSP 迟滞 (Hysteresis) 防抖动验证
# =========================================================================
print("\n--- 3. Gate Hysteresis Anti-Chatter Behavior ---")
reset_engine()
set_i("gate.enable", 1)
set_f("gate.threshold", -30.0)  # T_open = -30 dBFS
set_f("gate.hysteresis", 6.0)   # T_close = -36 dBFS
set_f("gate.range", -40.0)
set_f("gate.attack", 1.0)
set_f("gate.release", 20.0)
set_f("gate.hold_ms", 0.0)

# 测试信号：-33 dBFS 正弦波（处于迟滞窗口 -36dBFS ~ -30dBFS 之间）
amp_in_window = 10.0 ** (-33.0 / 20.0)   # ≈ 0.022387
amp_above_open = 10.0 ** (-20.0 / 20.0)  # 0.1

def process_burst(amp, blocks=30):
    rms = 0.0
    for b in range(blocks):
        in_b = (ctypes.c_float * (BLOCK * 2))()
        out_b = (ctypes.c_float * (BLOCK * 2))()
        for i in range(BLOCK):
            val = amp * math.sin(2.0 * math.pi * 1000.0 * i / SR)
            in_b[i * 2] = in_b[i * 2 + 1] = val
        dll.auradsp_process(h, in_b, out_b, BLOCK)
        if b >= blocks - 4:
            acc = sum(out_b[i * 2] ** 2 for i in range(BLOCK)) / BLOCK
            rms += math.sqrt(acc)
    return rms / 4.0

# 阶段 A：从静音开始直接输入 -33dBFS -> 低于 T_open (-30dBFS) -> 门保持关闭（衰减 ~40dB）
rms_closed = process_burst(amp_in_window, blocks=30)
rc, gr_gate_val = get_f("gr.gate")
check("gate stays closed in hysteresis zone from silence",
      gr_gate_val > 35.0, f"expected GR > 35dB, got {gr_gate_val:.2f}dB")

# 阶段 B：送入 -20dBFS 强信号把门冲开 -> T_open 被触发，门开启 (GR -> 0)
rms_open = process_burst(amp_above_open, blocks=30)
rc, gr_gate_open = get_f("gr.gate")
check("gate opens above threshold", gr_gate_open < 1.0, f"expected GR < 1dB, got {gr_gate_open:.2f}dB")

# 阶段 C：将信号降回 -33dBFS -> 高于 T_close (-36dBFS) -> 门依然保持开启！
rms_stay_open = process_burst(amp_in_window, blocks=30)
rc, gr_gate_stay = get_f("gr.gate")
check("gate stays OPEN in hysteresis zone when falling from above",
      gr_gate_stay < 1.0 and rms_stay_open > rms_closed * 10.0,
      f"expected GR < 1dB and RMS > 10x closed, got GR={gr_gate_stay:.2f}dB, rms={rms_stay_open:.5f} vs {rms_closed:.5f}")


# =========================================================================
# 4. Gate DSP 衰减底线 (Range Floor) 验证
# =========================================================================
print("\n--- 4. Gate Range (Floor) Behavior ---")
reset_engine()
set_i("gate.enable", 1)
set_f("gate.threshold", -20.0)
set_f("gate.range", -15.0)  # 地板设定为 -15dB
set_f("gate.attack", 1.0)
set_f("gate.release", 10.0)
set_f("gate.hold_ms", 0.0)

# 输入 -40dBFS 信号（远低于阈值 -20dBFS）
amp_quiet = 10.0 ** (-40.0 / 20.0)
process_burst(amp_quiet, blocks=40)
rc, gr_floor = get_f("gr.gate")
check("gate GR clamped to Range floor (-15dB)",
      14.0 <= gr_floor <= 16.0, f"expected GR ~ 15dB, got {gr_floor:.2f}dB")


# =========================================================================
# 5. Dynamic EQ 独立频段 GR 计量与选择性
# =========================================================================
print("\n--- 5. Dynamic EQ Independent Band GR Metering ---")
reset_engine()
set_i("dyneq.enable", 1)
set_i("dyneq.mid.enable", 1)
set_f("dyneq.mid.freq", 1000.0)
set_f("dyneq.mid.threshold", -20.0)
set_f("dyneq.mid.range", 12.0)
set_f("dyneq.mid.gain", 0.0)

# 输入 1000Hz 强信号 (0 dBFS, amp = 1.0)
def process_freq_burst(freq, amp, blocks=40):
    for b in range(blocks):
        in_b = (ctypes.c_float * (BLOCK * 2))()
        out_b = (ctypes.c_float * (BLOCK * 2))()
        for i in range(BLOCK):
            val = amp * math.sin(2.0 * math.pi * freq * (b * BLOCK + i) / SR)
            in_b[i * 2] = in_b[i * 2 + 1] = val
        dll.auradsp_process(h, in_b, out_b, BLOCK)

process_freq_burst(1000.0, 1.0, blocks=50)

rc, gr_dyneq_total = get_f("gr.dyneq")
rc, gr_dyneq_low   = get_f("gr.dyneq.low")
rc, gr_dyneq_mid   = get_f("gr.dyneq.mid")
rc, gr_dyneq_high  = get_f("gr.dyneq.high")

check("dyneq.mid GR triggered for 1kHz tone",
      gr_dyneq_mid > 3.0, f"expected mid GR > 3dB, got {gr_dyneq_mid:.2f}dB")
check("dyneq total GR tracks active band",
      abs(gr_dyneq_total - gr_dyneq_mid) < 0.1, f"total={gr_dyneq_total:.2f}, mid={gr_dyneq_mid:.2f}")
check("dyneq.low GR remains ~0dB (frequency selectivity)",
      gr_dyneq_low < 0.5, f"expected low GR < 0.5dB, got {gr_dyneq_low:.2f}dB")
check("dyneq.high GR remains ~0dB (frequency selectivity)",
      gr_dyneq_high < 0.5, f"expected high GR < 0.5dB, got {gr_dyneq_high:.2f}dB")


# =========================================================================
# 6. Limiter & Compressor 实时 GR 计量
# =========================================================================
print("\n--- 6. Limiter & Compressor GR Metering ---")
# 6.1 Limiter GR
reset_engine()
set_i("limiter.enable", 1)
set_f("limiter.threshold", -6.0)       # -6 dBFS (vendor chain limits input to 0 dBFS / 1.0)
set_f("limiter.release_ms", 50.0)
set_i("limiter.lookahead", 1)

# 输入 +6dBFS 信号 (amp = 2.0)
process_freq_burst(1000.0, 2.0, blocks=40)
rc, gr_lim = get_f("gr.limiter")
check("limiter GR detects +6dB overload (~6dB attenuation)",
      5.0 <= gr_lim <= 7.0, f"expected GR ~ 6dB, got {gr_lim:.2f}dB")

# 6.2 Compressor GR
reset_engine()
set_i("comp.enable", 1)
# 设置强压缩以确保触发增益衰减
process_freq_burst(1000.0, 1.5, blocks=40)
rc, gr_comp = get_f("gr.comp")
check("compressor GR reporting active (>0dB)",
      gr_comp > 0.0, f"expected comp GR > 0dB, got {gr_comp:.2f}dB")


# =========================================================================
# 7. SPSC VizFrame 桥接验证 (Slots 24..29)
# =========================================================================
print("\n--- 7. SPSC VizFrame GR Slots 24..29 Verification ---")
reset_engine()

# 先排空 SPSC 环形缓冲中的旧测试帧
drain = (VizFrame * 64)()
while dll.auradsp_viz_read(h, drain, 64) > 0:
    pass

set_i("limiter.enable", 1)
set_f("limiter.threshold", -6.0)
process_freq_burst(1000.0, 2.0, blocks=40)

v_frames = (VizFrame * 16)()
n = dll.auradsp_viz_read(h, v_frames, 16)
check("viz frames emitted and readable", n > 0, f"got {n} frames")

if n > 0:
    last_f = v_frames[n - 1]
    viz_gr_lim = last_f.stage_levels_l[24]
    rc, curr_gr_lim = get_f("gr.limiter")
    check("viz stage_levels[24] carries limiter GR",
          abs(viz_gr_lim - curr_gr_lim) < 1.0 and viz_gr_lim > 4.0,
          f"viz GR={viz_gr_lim:.2f}dB vs atomic={curr_gr_lim:.2f}dB")

dll.auradsp_destroy(h)

print("\n" + "="*50)
if FAIL:
    print(f"FAILED ({len(FAIL)} errors): {FAIL}")
    sys.exit(1)
else:
    print("ALL DYNAMIC GR & GATE TESTS PASSED 100%!")
    sys.exit(0)
