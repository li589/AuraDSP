"""smoke_silence_gate.py — 全后端静音门控验收（P2 引擎 + P3 桥状态机）。

背景（2026-10-29 方案）：VM 常驻无音乐实测 1143MB WS / 120 线程 / 15.3% CPU，
去掉桥后 331MB / 0.2%。门控要在「输入静音且尾音已衰完」时跳过效果链，
但不改变任何用户可见行为（viz 帧格式/fps、D4-a、WASAPI 事件驱动均不动）。

验收：
  A. 桥层状态机（silence_gate_test.exe，驱动无关）
     默认启用 / hold=2000ms / -90dBFS 阈值 / 残量双条件 / 同块退出 /
     idleMs / AURADSP_GATE=0 / AURADSP_GATE_DB 覆盖 / 峰值扫描助手。
  B. 引擎层（auradsp_engine.dll）
     B1 默认：1.5s 静音后 -100dBFS 探测块仍有输出（未到 hold）；
             2.2s 后同探测块输出逐位为 0（GATED 快路径）；
             -40dBFS 信号当块恢复（0 块延迟，无淡入）；
             GATED 期间 viz 仍按节流发射（emit_viz 不受门控影响）；
             GATED 块耗时显著低于有信号块（CPU ≈ 0）。
     B2 AURADSP_GATE=0：2.2s 静音后 -100dBFS 探测块仍有输出（门控禁用）。
     B3 AURADSP_GATE_DB=-120：同上（阈值覆盖为 -120dBFS）。
"""
import ctypes
import math
import os
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ENGINE = os.path.join(ROOT, 'core', 'desktop', 'windows', 'out', 'Release',
                      'auradsp_engine.dll')
GATE_TEST = os.path.join(ROOT, 'core', 'desktop', 'windows-drivers', 'out',
                         'Release', 'silence_gate_test.exe')

SR = 48000
BLOCK = 480          # 10ms
FAIL = []


def check(name, cond, detail=''):
    print(('PASS  ' if cond else 'FAIL  ') + name + (
        f'  ({detail})' if detail and not cond else ''))
    if not cond:
        FAIL.append(name)


# --- VizFrame 单一来源（§7-1 ABI 镜像门禁）---
_VIZ_ROOT = os.path.dirname(os.path.abspath(__file__))
while not os.path.isfile(os.path.join(_VIZ_ROOT, 'tools', 'bin', 'viz_frame.py')):
    _VIZ_PARENT = os.path.dirname(_VIZ_ROOT)
    if _VIZ_PARENT == _VIZ_ROOT:
        raise ImportError('未找到 tools/bin/viz_frame.py（VizFrame 的唯一定义处）')
    _VIZ_ROOT = _VIZ_PARENT
if os.path.join(_VIZ_ROOT, 'tools', 'bin') not in sys.path:
    sys.path.insert(0, os.path.join(_VIZ_ROOT, 'tools', 'bin'))
from viz_frame import VizFrame  # noqa: E402


def run_bridge_state_machine():
    if not os.path.isfile(GATE_TEST):
        check('bridge_state_machine_exe_present', False, GATE_TEST)
        return
    p = subprocess.run([GATE_TEST], capture_output=True, text=True,
                       encoding='utf-8', errors='replace')
    out = (p.stdout or '') + (p.stderr or '')
    print(out.strip())
    check('bridge_state_machine_all_pass', p.returncode == 0,
          f'exit={p.returncode}')


def load_engine():
    lib = ctypes.CDLL(ENGINE)
    lib.auradsp_create.restype = ctypes.c_void_p
    lib.auradsp_create.argtypes = [ctypes.c_float, ctypes.c_int]
    lib.auradsp_destroy.argtypes = [ctypes.c_void_p]
    lib.auradsp_process.argtypes = [ctypes.c_void_p,
                                    ctypes.POINTER(ctypes.c_float),
                                    ctypes.POINTER(ctypes.c_float), ctypes.c_int]
    lib.auradsp_viz_read.restype = ctypes.c_uint32
    lib.auradsp_viz_read.argtypes = [ctypes.c_void_p,
                                     ctypes.POINTER(VizFrame), ctypes.c_uint32]
    lib.auradsp_set_param.restype = ctypes.c_int
    lib.auradsp_set_param.argtypes = [ctypes.c_void_p, ctypes.c_char_p,
                                      ctypes.c_void_p, ctypes.c_uint32]
    return lib


def make_block(amp, freq=1000.0, frames=BLOCK, phase=0.0):
    buf = (ctypes.c_float * (frames * 2))()
    w = 2.0 * math.pi * freq / SR
    for i in range(frames):
        v = amp * math.sin(w * (i + phase))
        buf[i * 2] = v
        buf[i * 2 + 1] = v
    return buf


def process(lib, h, src, frames=BLOCK):
    out = (ctypes.c_float * (frames * 2))()
    lib.auradsp_process(h, src, out, frames)
    peak = max(abs(out[i]) for i in range(frames * 2))
    return out, peak


def feed_silence(lib, h, seconds):
    zero = make_block(0.0)
    n = int(seconds * SR / BLOCK)
    for _ in range(n):
        process(lib, h, zero)
    return n * BLOCK


def feed_probe(lib, h, amp):
    return process(lib, h, make_block(amp))[1]


def peak_of(buf, frames=BLOCK):
    return max(abs(buf[i]) for i in range(frames * 2))


def engine_case_default(lib):
    h = lib.auradsp_create(ctypes.c_float(SR), BLOCK)
    check('engine_created', bool(h))
    if not h:
        return

    # 有信号：输出非静音（基线）
    tone = make_block(0.1)
    p = 0.0
    for _ in range(25):
        _, p = process(lib, h, tone)
    check('active_output_nonzero', p > 0.05, f'peak={p:.6f}')

    # 1.5s 静音：未满 hold，-100dBFS 探测块必须仍被处理
    feed_silence(lib, h, 1.5)
    p = feed_probe(lib, h, 1e-5)
    check('probe_before_hold_processed', p > 0.0, f'peak={p:.9f}')

    # 累计 2.2s：GATED，探测块输出逐位为 0
    feed_silence(lib, h, 0.7)
    p = feed_probe(lib, h, 1e-5)
    check('gated_output_bitwise_zero', p == 0.0, f'peak={p:.9f}')

    # 0 块延迟恢复：-40dBFS 信号当块出声
    p = peak_of(process(lib, h, make_block(0.01))[0])
    check('onset_same_block', p > 0.005, f'peak={p:.6f}')

    # 重新进入 GATED，并验证 viz 仍在发射（emit_viz 不受门控影响）
    feed_silence(lib, h, 2.2)
    vf = (VizFrame * 64)()
    lib.auradsp_viz_read(h, vf, 64)          # 先排空进入前的残留帧
    feed_silence(lib, h, 0.3)
    got = lib.auradsp_viz_read(h, vf, 64)
    check('viz_emits_while_gated', got > 0, f'frames={got}')

    lib.auradsp_destroy(h)


def set_int(lib, h, pid, value):
    v = ctypes.c_int(value)
    return lib.auradsp_set_param(h, pid.encode(), ctypes.byref(v), 4)


def timing_case(lib):
    """开一组真实效果器后量：GATED 块必须是 ACTIVE 的零头（跳过整条链）。

    默认链几乎不耗 CPU（直通+计量），GATED/ACTIVE 都淹没在 viz 发射成本里，
    量不出差别；打开 comp/eq/tube/bass/arbmag/limiter 才有区分度。
    """
    h = lib.auradsp_create(ctypes.c_float(SR), BLOCK)
    if not h:
        check('timing_engine_created', False)
        return
    for pid in ('comp.enable', 'eq.enable', 'tube.enable', 'bass.enable',
                'arbmag.enable', 'limiter.enable'):
        set_int(lib, h, pid, 1)
    tone = make_block(0.1)
    zero = make_block(0.0)
    for _ in range(25):
        process(lib, h, tone)
    t_active = measure(lib, h, tone, 300)
    feed_silence(lib, h, 2.2)
    p = feed_probe(lib, h, 1e-5)
    check('timing_gated_confirmed', p == 0.0, f'peak={p:.9f}')
    t_gated = measure(lib, h, zero, 300)
    print(f'       timing: gated={t_gated * 1e6:.1f}us/block '
          f'active={t_active * 1e6:.1f}us/block '
          f'ratio={t_gated / t_active * 100.0:.1f}%')
    check('gated_cpu_near_zero_with_effects', t_gated < t_active * 0.25,
          f'gated={t_gated:.3e}s active={t_active:.3e}s')
    lib.auradsp_destroy(h)


def measure(lib, h, src, blocks):
    t0 = time.perf_counter()
    for _ in range(blocks):
        process(lib, h, src)
    return (time.perf_counter() - t0) / blocks


def engine_case_env(lib, name, env, probe_amp, expect_nonzero):
    old = os.environ.get('AURADSP_GATE'), os.environ.get('AURADSP_GATE_DB')
    if 'AURADSP_GATE' in env:
        os.environ['AURADSP_GATE'] = env['AURADSP_GATE']
    else:
        os.environ.pop('AURADSP_GATE', None)
    if 'AURADSP_GATE_DB' in env:
        os.environ['AURADSP_GATE_DB'] = env['AURADSP_GATE_DB']
    else:
        os.environ.pop('AURADSP_GATE_DB', None)
    try:
        h = lib.auradsp_create(ctypes.c_float(SR), BLOCK)
        if not h:
            check(name, False, 'create failed')
            return
        feed_silence(lib, h, 2.2)
        p = feed_probe(lib, h, probe_amp)
        if expect_nonzero:
            check(name, p > 0.0, f'peak={p:.9f}')
        else:
            check(name, p == 0.0, f'peak={p:.9f}')
        lib.auradsp_destroy(h)
    finally:
        for k, v in zip(('AURADSP_GATE', 'AURADSP_GATE_DB'), old):
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v


def main():
    if not os.path.isfile(ENGINE):
        print(f'SKIP  engine dll not found: {ENGINE}')
        return 0
    run_bridge_state_machine()
    lib = load_engine()
    engine_case_default(lib)
    timing_case(lib)
    # 门控关：静音 2.2s 后 -100dBFS 探测块必须照常处理
    engine_case_env(lib, 'env_gate_0_still_processes', {'AURADSP_GATE': '0'}, 1e-5, True)
    # 阈值覆盖 -120dBFS：-100dBFS 已算"有信号"，不得进入 GATED
    engine_case_env(lib, 'env_gate_db_override_processes',
                    {'AURADSP_GATE_DB': '-120'}, 1e-5, True)

    if FAIL:
        print(f'\nFAILED: {len(FAIL)} -> {FAIL}')
        return 1
    print('\nALL PASS')
    return 0


if __name__ == '__main__':
    sys.exit(main())
