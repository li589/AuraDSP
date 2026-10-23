# -*- coding: utf-8 -*-
"""smoke_cross_mode_consistency.py — E9 跨模式一致性回归（进程内 vs 进程外）。

背景（审查报告 §12 遗留行 / 未决清单 E9）：
R-1（进程模式宿主侧静默单位直通）能在出厂门禁下潜伏，一个重要结构性原因是
两模式「无直接对比门禁」——每个模式各自绿，模式间的分歧不可见。本用例补上
该门禁：同一插件（ConvologyXT，真实 latency 288）、同一确定性输入序列，
分别经进程内与进程外（AURA_PLUGIN_HOST_MODE=process）两种模式处理，对齐
传输管线延迟（E15 重校准口径 1×kTransportFrames = 128 帧，实测 onset
delta 同值）后逐样本比对输出。

输入序列（全局样本索引的确定性函数，两模式逐位相同）：
  [暖机 tone 直至插件生效] + TONE_BLOCKS 块 tone + SILENCE_BLOCKS 块静音
  + 1 个 ch0 脉冲 + CAPTURE_BLOCKS 块采集

块大小 BLOCK=128 = ipc::kTransportFrames：宿主音频线程按传输块 128 帧调用
插件（auradsp_plugin_host_main.cpp L484），进程内引擎同喂 128 帧 → 插件在
两种模式下所见块大小一致，排除块大小相关的数值差异混淆。

状态收敛论证（为何对齐后应逐位一致）：
  - 插件所见历史：两种模式均从「各自首个生效块」起看到同一段 tone→静音→
    脉冲（暖机直通块插件根本没看到），96 块 tone+静音远超插件/供应商链的
    记忆窗 → 脉冲时刻状态一致；
  - 供应商链中 freeverb 等前置级在两模式所见输入完全相同（引擎每块都跑），
    后置级（limiter/loudness 等短记忆）经 96 块收敛；
  - 传输路径为共享内存 memcpy（无损），引擎/宿主编译自同一份源码同一构建。

判据：
  0. 两模式收尾时 slot 健康（remoteFailed/bypassed 均为 False）——E12 红门禁：
     missStreak 设计缺陷会在 ~64 传输块（≈170ms）后把进程外 slot 永久 bypass，
     本断言在比对前给出直接归因，而不是让后续断言莫名报红；
  1. process_latency - inproc_latency == 128（1×kTransportFrames，E15 重校准
     后的 F-7 上报口径；post-F-6 动态流水深实测即 1 块）；
  2. 脉冲响应 onset 差为 1-2 个整传输块（128 的倍数），且 onset_inproc >=
     inproc_latency（IR 不可能早于插件自身延迟——把波形测量与 ABI 上报互相
     钩住）。注意：动态流水深取决于宿主时序（健康流水下代理帧首取块成功
     即为 1 块；宿主稍慢为 2 块），传输只整块搬运音频，故只断言整块性，
     不硬编码 256；静态上报口径由判据 1 单独守；
  3. 对齐后波形逐位一致（ALIGN_TOLERANCE = 0.0）；
  4. IR 非平凡（峰值阈值 + onset 窗能量阈值，排除「双零」与 unity 直通假绿；
     实测 ConvologyXT 默认 IR 仅占 onset 后 1 块，无长尾环响可依）。

能证明什么：相同插件/输入/块大小下，两模式音频输出逐位一致。
不能证明什么：其它块大小组合下的数值一致性（本用例只钉死 128 帧这一格）；
插件自身若不确定（内部随机/线程竞态），本门禁会红——那正是要报的。

用法：
  python smoke_cross_mode_consistency.py                          # 父模式：派生两 worker 并比对
  python smoke_cross_mode_consistency.py --worker {inproc|process} out.json   # 内部 worker
"""
import ctypes
import json
import math
import os
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DLL_PATH = os.path.join(ROOT, "core", "desktop", "windows", "out", "Release", "auradsp_engine.dll")
PLUGIN_NAME = "Convology"

SR = 48000.0
MAX_BLOCK = 1024
BLOCK = 128                       # == ipc::kTransportFrames：两模式插件块大小一致
TONE_BLOCKS = 48                  # 暖机后稳态 tone（收敛插件/供应商链状态）
SILENCE_BLOCKS = 48               # 让 reverb 尾音进入「同一衰减时长」区间
CAPTURE_BLOCKS = 128              # 脉冲后采集（16384 帧 ≈ 0.34s）
WARMUP_MAX_BLOCKS = 80            # 进程外模式宿主懒启动 + 传输暖机直通的上限
PACE_PROCESS_S = 0.003            # 传输环 16 块；128 帧 @48k = 2.67ms 实时，留裕量防溢
IMPULSE_AMP = 0.5                 # 低于限幅门限，保持线性区间（虽然后置链是共模）
ONSET_REL = 0.01                  # onset 检测阈 = 峰值 1%（两模式波形相同，相对阈无偏）
ALIGN_TOLERANCE = 0.0             # 逐位一致门禁；若实证存在合法微小差，须先根因再改此值
EXPECTED_LATENCY_DELTA = 128      # 1 × kTransportFrames（E15 重校准后的上报口径，实测 onset delta 同值）
kTransportFrames = 128            # == ipc::kTransportFrames（动态流水深以整块为单位）


def tone_sample(i, ch):
    """确定性多音 tone（全局样本索引的函数；双声道不同频谱丰富状态）。"""
    if ch == 0:
        return (0.20 * math.sin(2.0 * math.pi * 440.0 * i / SR)
                + 0.12 * math.sin(2.0 * math.pi * 1237.0 * i / SR + 0.7)
                + 0.08 * math.sin(2.0 * math.pi * 3011.0 * i / SR + 1.9))
    return (0.18 * math.sin(2.0 * math.pi * 587.0 * i / SR + 0.3)
            + 0.10 * math.sin(2.0 * math.pi * 1901.0 * i / SR + 1.2)
            + 0.07 * math.sin(2.0 * math.pi * 2503.0 * i / SR + 2.4))


def load_dll():
    dll = ctypes.CDLL(DLL_PATH)
    dll.auradsp_create.restype = ctypes.c_void_p
    dll.auradsp_create.argtypes = [ctypes.c_float, ctypes.c_int]
    dll.auradsp_destroy.argtypes = [ctypes.c_void_p]
    dll.auradsp_process.argtypes = [
        ctypes.c_void_p,
        ctypes.POINTER(ctypes.c_float),
        ctypes.POINTER(ctypes.c_float),
        ctypes.c_int,
    ]
    dll.auradsp_plugin_scan.restype = ctypes.c_int
    dll.auradsp_plugin_scan.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]
    dll.auradsp_plugin_get_count.restype = ctypes.c_int
    dll.auradsp_plugin_get_count.argtypes = [ctypes.c_void_p]
    dll.auradsp_plugin_get_item.restype = ctypes.c_int
    dll.auradsp_plugin_get_item.argtypes = [
        ctypes.c_void_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_int]
    dll.auradsp_plugin_load.restype = ctypes.c_int
    dll.auradsp_plugin_load.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p]
    dll.auradsp_plugin_get_status.argtypes = [
        ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]
    dll.auradsp_plugin_get_status.restype = ctypes.c_int
    dll.auradsp_plugin_get_latency.restype = ctypes.c_uint32
    dll.auradsp_plugin_get_latency.argtypes = [ctypes.c_void_p]
    return dll


def get_status(dll, handle):
    buf = ctypes.create_string_buffer(8192)
    dll.auradsp_plugin_get_status(handle, buf, len(buf))
    return json.loads(buf.value.decode("utf-8"))


def find_plugin(dll, handle):
    count = dll.auradsp_plugin_scan(handle, b"", 0)
    if count <= 0:
        return None
    buf = ctypes.create_string_buffer(4096)
    for i in range(count):
        dll.auradsp_plugin_get_item(handle, i, buf, len(buf))
        try:
            item = json.loads(buf.value.decode("utf-8"))
        except ValueError:
            continue
        if PLUGIN_NAME in item.get("name", ""):
            return item
    return None


def run_worker(mode, out_path):
    """单模式测量 worker：泵送确定性序列，落盘 impulse 起的全部输出。"""
    if mode == "process":
        os.environ["AURA_PLUGIN_HOST_MODE"] = "process"
    else:
        os.environ.pop("AURA_PLUGIN_HOST_MODE", None)

    dll = load_dll()
    handle = dll.auradsp_create(SR, MAX_BLOCK)
    assert handle, "auradsp_create failed"

    target = find_plugin(dll, handle)
    if target is None:
        with open(out_path, "w", encoding="utf-8") as f:
            json.dump({"skipped": True,
                       "reason": f"test plugin containing {PLUGIN_NAME!r} not installed"}, f)
        dll.auradsp_destroy(handle)
        print(f"[SKIP] {mode}: {PLUGIN_NAME} not installed")
        return 0

    assert dll.auradsp_plugin_load(
        handle, target["path"].encode("utf-8"), b"") == 1, f"{mode}: plugin load failed"
    status = get_status(dll, handle)
    latency = int(dll.auradsp_plugin_get_latency(handle))
    print(f"[{mode}] loaded {target['name']}, latency={latency}, "
          f"remoteMode={status.get('remoteMode')}")
    if mode == "process":
        assert status.get("remoteMode") is True, f"expected remote mode, got {status}"

    pace = PACE_PROCESS_S if mode == "process" else 0.0
    state = {"gidx": 0}

    def pump(samples):
        in_arr = (ctypes.c_float * (BLOCK * 2))(*samples)
        out_arr = (ctypes.c_float * (BLOCK * 2))()
        dll.auradsp_process(handle, in_arr, out_arr, BLOCK)
        state["gidx"] += BLOCK
        if pace:
            time.sleep(pace)
        return list(out_arr)

    def tone_block():
        g = state["gidx"]
        return [tone_sample(g + i, i % 2) for i in range(BLOCK * 2)]

    def silence_block():
        return [0.0] * (BLOCK * 2)

    # 暖机：进程外模式宿主懒启动期间代理原样直通，等到输出≠输入才算插件生效
    active = False
    for _ in range(WARMUP_MAX_BLOCKS):
        src = tone_block()
        out = pump(src)
        if max(abs(a - b) for a, b in zip(out, src)) > 1e-3:
            active = True
            break
    assert active, (
        f"{mode}: plugin never became active within {WARMUP_MAX_BLOCKS} blocks "
        "(warm-up passthrough never ended)")
    print(f"[{mode}] plugin active after warm-up (global frame {state['gidx']})")

    for _ in range(TONE_BLOCKS):
        pump(tone_block())
    for _ in range(SILENCE_BLOCKS):
        pump(silence_block())

    impulse = [0.0] * (BLOCK * 2)
    impulse[0] = IMPULSE_AMP               # ch0 单样本脉冲（携带位置信息）
    capture = [pump(impulse)]
    for _ in range(CAPTURE_BLOCKS):
        capture.append(pump(silence_block()))

    final = get_status(dll, handle)
    dll.auradsp_destroy(handle)
    if mode == "process":
        time.sleep(0.5)                    # 给宿主 exe 退出留窗口（destroy 会 reap）

    flat = [v for blk in capture for v in blk]
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump({
            "mode": mode,
            "latency": latency,
            "frames": len(capture) * BLOCK,
            "plugin": target["name"],
            "seqGaps": final.get("seqGaps"),
            "inputOverflows": final.get("inputOverflows"),
            "outputOverflows": final.get("outputOverflows"),
            # E12 红门禁：missStreak 自毁会让 slot 在 ~64 块后永久 bypass，
            # 父级据此给出明确失败信息而不是在 onset/波形断言里莫名报红。
            "remoteFailed": final.get("remoteFailed"),
            "slotBypassed": final.get("bypassed"),
            # E13 守卫：交错路径（remote 分支）必须递增 processCalls。
            "processCalls": final.get("processCalls"),
            "out": flat,
        }, f)
    print(f"[{mode}] captured {len(flat)} samples, seqGaps={final.get('seqGaps')}, "
          f"overflows in/out={final.get('inputOverflows')}/{final.get('outputOverflows')}")
    return 0


def onset_frame(out, frames, threshold):
    """ch0 首个超过阈值的帧号（IR 起点）。"""
    for f in range(frames):
        if abs(out[2 * f]) > threshold:
            return f
    return None


def main():
    if "--worker" in sys.argv:
        i = sys.argv.index("--worker")
        return run_worker(sys.argv[i + 1], sys.argv[i + 2])

    tmp = tempfile.mkdtemp(prefix="auradsp_xmode_")
    try:
        results = {}
        for mode in ("inproc", "process"):
            out_path = os.path.join(tmp, f"{mode}.json")
            env = dict(os.environ)
            if mode == "process":
                env["AURA_PLUGIN_HOST_MODE"] = "process"
            else:
                env.pop("AURA_PLUGIN_HOST_MODE", None)
            print(f"=== worker: {mode} ===")
            proc = subprocess.run(
                [sys.executable, os.path.abspath(__file__), "--worker", mode, out_path],
                env=env, capture_output=True, text=True,
                encoding="utf-8", errors="replace", timeout=300)
            sys.stdout.write(proc.stdout)
            if proc.returncode != 0:
                sys.stderr.write(proc.stderr)
                print(f"[FAIL] {mode} worker exited {proc.returncode}")
                return 1
            with open(out_path, "r", encoding="utf-8") as f:
                results[mode] = json.load(f)
            if results[mode].get("skipped"):
                print(f"[SKIP] cross-mode consistency: {results[mode].get('reason')}")
                return 0

        a = results["inproc"]
        b = results["process"]

        # 判据 0（E12 红门禁）：slot 健康检查先行。
        for d in (a, b):
            assert not d.get("remoteFailed") and not d.get("slotBypassed"), (
                f"[{d['mode']}] slot self-destructed (remoteFailed="
                f"{d.get('remoteFailed')}, bypassed={d.get('slotBypassed')}): "
                "proxy missStreak hits kMissingLimit=64 on routine end-of-block "
                "pump failures — any process-mode session longer than ~170ms "
                "permanently bypasses the plugin (review report E12, P0)")
        print("slot health: remoteFailed=False, bypassed=False (both modes)")

        # E13 守卫：remote 交错路径 processCalls 必须随泵送推进（此前恒 0）。
        assert (b.get("processCalls") or 0) > 100, (
            f"remote processCalls={b.get('processCalls')} did not advance: "
            "interleaved path never increments processCalls (review E13)")
        print(f"remote processCalls advanced: {b.get('processCalls')}")

        n = min(len(a["out"]), len(b["out"]))
        frames = n // 2

        def peak_of(data):
            return max(abs(v) for v in data["out"][:n])

        pa, pb = peak_of(a), peak_of(b)
        oa = onset_frame(a["out"], frames, max(1e-3, ONSET_REL * pa))
        ob = onset_frame(b["out"], frames, max(1e-3, ONSET_REL * pb))

        print("=== 跨模式比对 ===")
        print(f"{'mode':<8} {'latency':>8} {'onset':>7} {'peak':>10} "
              f"{'seqGaps':>8} {'ovf(in/out)':>12}")
        for d, o in ((a, oa), (b, ob)):
            print(f"{d['mode']:<8} {d['latency']:>8} {str(o):>7} {peak_of(d):>10.6f} "
                  f"{str(d['seqGaps']):>8} "
                  f"{str(d['inputOverflows'])}/{str(d['outputOverflows']):>5}")

        # 判据 1：latency 差 = 1×传输块（E15 重校准口径，插件无关的泛化断言）
        lat_delta = b["latency"] - a["latency"]
        assert lat_delta == EXPECTED_LATENCY_DELTA, (
            f"latency delta {lat_delta} != {EXPECTED_LATENCY_DELTA} "
            "(process mode must add exactly 1 transport block — E15 calibration)")
        print(f"latency delta = {lat_delta} (expected {EXPECTED_LATENCY_DELTA})")

        # 判据 2：onset 差 = 1-2 个整传输块，且不早于插件自身延迟
        # （波形测量钩住 ABI 上报）。动态流水深取决于宿主时序，只断言整块性。
        assert oa is not None and ob is not None, "impulse response onset not found"
        onset_delta = ob - oa
        assert onset_delta % kTransportFrames == 0 and 0 < onset_delta <= EXPECTED_LATENCY_DELTA, (
            f"onset delta {onset_delta} is not 1-2 whole transport blocks "
            f"(multiples of {kTransportFrames}): the two modes disagree on "
            "pipeline depth beyond whole-block transport latency")
        assert oa >= a["latency"], (
            f"in-proc onset {oa} earlier than plugin latency {a['latency']}")
        print(f"onset delta = {onset_delta} "
              f"({onset_delta // kTransportFrames} transport block(s)); "
              f"in-proc onset {oa} >= latency {a['latency']}")

        # 判据 4：IR 非平凡（排除双零假绿）。实测 ConvologyXT 默认 IR 极短：
        # 全部能量集中于 onset 后 1 个块（onset 288 / 块 RMS ~0.0265），
        # capture 末窗全零——「尾音环响」判据对该 IR 不成立。改为断言
        # onset 窗（1 块）含真实能量；结合 onset>=latency（排除 unity 直通）
        # 与 peak 阈值（排除双零），假绿面已闭合。
        ir_win = a["out"][2 * oa: 2 * min(oa + BLOCK, frames)]
        ir_rms = math.sqrt(sum(v * v for v in ir_win) / max(1, len(ir_win)))
        assert pa > 0.05, f"IR peak {pa:.6f} too small — impulse never came back"
        assert ir_rms > 1e-4, f"IR onset-window RMS {ir_rms:.6f} too small — no real impulse response"
        print(f"IR peak={pa:.6f}, onset-window RMS={ir_rms:.6f} (non-trivial)")

        # 判据 3：对齐后逐样本比对。onset_delta 为帧数（onset_frame 返回帧号），
        # 交错流的平坦样本偏移 = 2×帧数；起点 = in-proc onset 帧（平坦 2*oa）。
        shift = 2 * onset_delta
        maxdiff = 0.0
        ndiff = 0
        worst_i = -1
        for i in range(2 * oa, n - shift):
            d = abs(a["out"][i] - b["out"][i + shift])
            if d != 0.0:
                ndiff += 1
                if d > maxdiff:
                    maxdiff = d
                    worst_i = i
        total = n - shift - 2 * oa
        print(f"aligned comparison: max|diff|={maxdiff:.9g}, "
              f"differing samples={ndiff}/{total}", end="")
        if worst_i >= 0:
            print(f" (first worst at flat {worst_i} (frame {worst_i // 2}): "
                  f"inproc={a['out'][worst_i]:.9g} process={b['out'][worst_i + shift]:.9g})")
        else:
            print()
        assert maxdiff <= ALIGN_TOLERANCE, (
            f"cross-mode divergence: max|diff|={maxdiff:.9g} > tolerance "
            f"{ALIGN_TOLERANCE} ({ndiff}/{total} samples differ) — the two modes "
            "disagree on audio output for identical plugin/input/block-size")
        print("PASS: in-proc and out-of-process modes agree bit-exactly "
              f"(after {onset_delta}-frame transport alignment)")
        return 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
