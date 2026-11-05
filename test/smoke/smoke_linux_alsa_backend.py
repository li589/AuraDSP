# -*- coding: utf-8 -*-
"""smoke_linux_alsa_backend — ALSA 专家模式门禁（二期 A3，2026-11-02）。

两半：
  1. 源码不变量（无条件执行）：ALSA 实现文件在位、工厂按
     linuxAudioBackend 分派、AppConfig 三字段与 spawn 注入齐全、
     resolveAlsaDevice 纯函数在 alsa_ffi.dart（out/in 共用单源）。
  2. libasound 活体契约（ctypes 直绑，与 Dart 实现同口径）：
     对 "null" PCM 设备完成 open→hw_params 协商（48k/float32/
     period 256/buffer 1024）→writei 若干块→delay/avail 读数
     →drop+prepare 后续写→close；再打开采集侧 readi 一轮；
     不存在设备 hw:Loopback 应以负码干净失败。
     libasound 缺失时活体半自 SKIP（开发机无 ALSA 不等于产品
     失败）；CI 的 J3 装了 pulseaudio（依赖 libasound），活体
     半在流水线里实跑。
"""
import ctypes
import os
import sys

TEST_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ROOT = os.path.dirname(TEST_DIR)
APP = os.path.join(ROOT, "app", "auradsp_app")

FAILS = []


def check(cond, msg):
    print(("  PASS " if cond else "  FAIL ") + msg)
    if not cond:
        FAILS.append(msg)


def read(rel):
    with open(os.path.join(APP, rel), encoding="utf-8") as f:
        return f.read()


def source_invariants():
    ffi = read("lib/engine/audio_out/alsa_ffi.dart")
    out = read("lib/engine/audio_out/audio_out_alsa.dart")
    inp = read("lib/engine/audio_out/audio_in_alsa.dart")
    wasapi = read("lib/engine/audio_out/audio_out_wasapi.dart")
    config = read("lib/core/config.dart")
    core = read("lib/core/state/state_core.dart")
    linux_iso = read("lib/engine/audio_isolate_linux.dart")
    check("alsaOpenNegotiated" in ffi and "resolveAlsaDevice" in ffi,
          "alsa_ffi.dart 提供共享协商段与设备名解析")
    check("class AlsaAudioOut implements AudioOut" in out,
          "audio_out_alsa.dart 实现 AudioOut 端口")
    check("class AlsaAudioIn" in inp, "audio_in_alsa.dart 在位")
    check("linuxBackend == 'alsa'" in wasapi and "AlsaAudioOut(" in wasapi,
          "工厂按 linuxAudioBackend 分派 ALSA 实现")
    check(all(k in config for k in
              ("linuxAudioBackend", "alsaOutputDevice", "alsaCaptureDevice")),
          "AppConfig 含 ALSA 三字段")
    check("'linuxAudioBackend': config.linuxAudioBackend" in core,
          "spawn cfg 注入 linuxAudioBackend")
    check("_attachAlsaCapture" in linux_iso and "hw:Loopback" in linux_iso,
          "driver 专家路径直采 hw:Loopback")
    check("alsaMaxStalledRetries" in out and "alsaMaxStalledRetries" in inp,
          "ALSA 读写循环带无进展上限（防设备异常时泵空转）")
    check("hw_params_set_channels" in ffi and "SetChannels" in ffi
          and "rc = lib.hwParamsSetChannels" in ffi,
          "协商校验 access/声道返回码（防帧布局错位静默过关）")
    check("alsaRateMatches" in linux_iso,
          "driver 专家路径校验采集协商率与泵率一致（防变速变调）")
    check("alsa-capture-unavailable" in linux_iso,
          "ALSA 采集失败有专属 note")
    # 全项目审查 DRV-02（2026-11-05）：Linux 输出流死亡必须能累计到
    # 端点死亡判定（旧逻辑只认 WASAPI HRESULT，PA/ALSA 永远凑不齐）。
    iso = read("lib/engine/audio_isolate.dart")
    check("Platform.isLinux" in iso and "pa_simple" in iso
          and "snd_pcm" in iso and "wasapiLost" in iso,
          "[DRV-02] 泵对 Linux 输出后端 StateError 有端点死亡累计路径")


SND_PCM_STREAM_PLAYBACK = 0
SND_PCM_STREAM_CAPTURE = 1
SND_PCM_ACCESS_RW_INTERLEAVED = 3
SND_PCM_FORMAT_FLOAT_LE = 14


def _negotiate(lib, pcm, period_want):
    size = lib.snd_pcm_hw_params_sizeof()
    params = ctypes.create_string_buffer(size)
    lib.snd_pcm_hw_params_any(pcm, params)
    lib.snd_pcm_hw_params_set_access(pcm, params,
                                     SND_PCM_ACCESS_RW_INTERLEAVED)
    lib.snd_pcm_hw_params_set_format(pcm, params, SND_PCM_FORMAT_FLOAT_LE)
    lib.snd_pcm_hw_params_set_channels(pcm, params, 2)
    rate = ctypes.c_uint32(48000)
    direction = ctypes.c_int32(0)
    lib.snd_pcm_hw_params_set_rate_near(pcm, params, ctypes.byref(rate),
                                        ctypes.byref(direction))
    period = ctypes.c_uint64(period_want)
    lib.snd_pcm_hw_params_set_period_size_near(pcm, params,
                                               ctypes.byref(period),
                                               ctypes.byref(direction))
    buffer = ctypes.c_uint64(period_want * 4)
    lib.snd_pcm_hw_params_set_buffer_size_near(pcm, params,
                                               ctypes.byref(buffer),
                                               ctypes.byref(direction))
    rc = lib.snd_pcm_hw_params(pcm, params)
    if rc < 0:
        return None
    got_period = ctypes.c_uint64(0)
    lib.snd_pcm_hw_params_get_period_size(params, ctypes.byref(got_period),
                                          ctypes.byref(direction))
    got_buffer = ctypes.c_uint64(0)
    lib.snd_pcm_hw_params_get_buffer_size(params, ctypes.byref(got_buffer),
                                          None)
    return got_period.value, got_buffer.value


def live_contract():
    try:
        lib = ctypes.CDLL("libasound.so.2")
    except OSError:
        print("  SKIP libasound 不存在（活体半跳过）")
        return
    lib.snd_pcm_open.restype = ctypes.c_int
    lib.snd_pcm_open.argtypes = [ctypes.POINTER(ctypes.c_void_p),
                                 ctypes.c_char_p, ctypes.c_int, ctypes.c_int]
    lib.snd_pcm_writei.restype = ctypes.c_int64
    lib.snd_pcm_readi.restype = ctypes.c_int64
    lib.snd_strerror.restype = ctypes.c_char_p

    def open_dev(name, stream):
        pcm = ctypes.c_void_p()
        rc = lib.snd_pcm_open(ctypes.byref(pcm), name.encode(), stream, 0)
        return rc, pcm

    rc, pcm = open_dev("null", SND_PCM_STREAM_PLAYBACK)
    check(rc >= 0 and pcm.value, f"open(null, playback) rc={rc}")
    if rc >= 0:
        neg = _negotiate(lib, pcm, 256)
        check(neg is not None, "hw_params 协商成功")
        if neg:
            check(neg[0] == 256 and neg[1] == 1024,
                  f"协商命中 period=256 buffer=1024（实际 {neg}）")
        lib.snd_pcm_prepare(pcm)
        block = (ctypes.c_float * (256 * 2))(*([0.25] * (256 * 2)))
        total = 0
        for _ in range(8):
            w = lib.snd_pcm_writei(pcm, block, 256)
            if w > 0:
                total += w
        check(total == 2048, f"writei 累计 {total} 帧（期望 2048）")
        dly = ctypes.c_int64(-1)
        lib.snd_pcm_delay(pcm, ctypes.byref(dly))
        check(0 <= dly.value <= 1024, f"delay 读数 {dly.value} 在界内")
        lib.snd_pcm_drop(pcm)
        lib.snd_pcm_prepare(pcm)
        w = lib.snd_pcm_writei(pcm, block, 256)
        check(w == 256, "drop+prepare 后续写成功")
        lib.snd_pcm_close(pcm)

    rc, cap = open_dev("null", SND_PCM_STREAM_CAPTURE)
    check(rc >= 0 and cap.value, f"open(null, capture) rc={rc}")
    if rc >= 0:
        _negotiate(lib, cap, 256)
        lib.snd_pcm_prepare(cap)
        buf = (ctypes.c_float * (256 * 2))()
        r = lib.snd_pcm_readi(cap, buf, 256)
        check(r == 256, f"readi 读满 {r} 帧")
        lib.snd_pcm_close(cap)

    rc, miss = open_dev("hw:Loopback", SND_PCM_STREAM_PLAYBACK)
    if rc >= 0 and miss.value:
        # 真机/已加载模块环境：打开成功同样合法，关掉即可。
        lib.snd_pcm_close(miss)
        print("  PASS hw:Loopback 可打开（snd-aloop 已加载）")
    else:
        err = lib.snd_strerror(rc)
        check(rc < 0 and bool(err), f"缺设备干净失败 rc={rc} {err}")


def main():
    source_invariants()
    live_contract()
    print("smoke_linux_alsa_backend: " + ("FAIL" if FAILS else "PASS"))
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
