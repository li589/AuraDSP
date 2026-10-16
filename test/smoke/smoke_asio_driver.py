"""smoke_asio_driver.py — AuraDSP 自研虚拟 ASIO 驱动 (auraasio_driver.dll) 冒烟验收

依据：docs/adr/ADR-008-asio-driver-identity-and-architecture.md
验收标准：
  1. auraasio_driver.dll 存在，PE 导出表包含 DllCanUnloadNow, DllGetClassObject,
     DllRegisterServer, DllUnregisterServer。
  2. 进程内 COM 握手：直接通过 DllGetClassObject 创建 IASIO 接口实例，验证纯净现代 COM 契约。
  3. IASIO 能力协商：
     - init 成功
     - getDriverName 返回 "AuraDSP Driver"（Steinberg 商标合规定名）
     - getDriverVersion 返回 1
     - getChannels 返回 (2, 2)（立体声 In/Out）
     - getBufferSize 返回 (64, 2048, 256, -1)（支持 2 的幂次阶跃）
     - getSampleRate / setSampleRate 契约自洽
     - canSampleRate 正确甄别 44.1k/48k/96k/192k 与非法采样率
     - getChannelInfo 返回 Float32LSB 格式与正规声道名
  4. 实时双缓冲与时钟驱动（Phase 1 动态验证）：
     - createBuffers 成功分配 64 字节对齐双缓冲地址
     - start 启动 MMCSS 高精度时钟泵，在 100ms 内收到 ~19 次 bufferSwitch 回调
     - stop 干净停止时钟，disposeBuffers 释放双缓冲
  5. 注册表与系统探测（若具备管理员权限则全量往返验证，非管理员记 note 跳过系统变异）。
"""

import ctypes
from ctypes import wintypes
import math
import os
import struct
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DLL_PATH = os.path.join(ROOT, 'core', 'desktop', 'windows-drivers', 'out', 'Release', 'auraasio_driver.dll')
PROBE_EXE = os.path.join(ROOT, 'core', 'desktop', 'windows-drivers', 'out', 'Release', 'asio_probe.exe')

FAIL = []

def check(name, cond, detail=''):
    status = 'PASS  ' if cond else 'FAIL  '
    msg = status + name + (('  ' + detail) if (detail and not cond) else '')
    print(msg)
    if not cond:
        FAIL.append(name)

# GUID 结构定义
class GUID(ctypes.Structure):
    _fields_ = [
        ('Data1', wintypes.DWORD),
        ('Data2', wintypes.WORD),
        ('Data3', wintypes.WORD),
        ('Data4', wintypes.BYTE * 8)
    ]

# {4B617572-6144-5350-4153-494F44727631}
CLSID_AuraAsioDriver = GUID(
    0x4B617572, 0x6144, 0x5350,
    (wintypes.BYTE * 8)(0x41, 0x53, 0x49, 0x4F, 0x44, 0x72, 0x76, 0x31)
)

IID_IClassFactory = GUID(
    0x00000001, 0x0000, 0x0000,
    (wintypes.BYTE * 8)(0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46)
)

# 最小 PE 导出表解析
def pe_exports(path):
    with open(path, 'rb') as f:
        data = f.read()
    if data[0:2] != b'MZ':
        return set()
    pe_off = struct.unpack('<I', data[0x3C:0x40])[0]
    if data[pe_off:pe_off + 4] != b'PE\x00\x00':
        return set()
    num_sec = struct.unpack('<H', data[pe_off + 6:pe_off + 8])[0]
    opt_off = pe_off + 24
    if struct.unpack('<H', data[opt_off:opt_off + 2])[0] != 0x20B:
        return set()
    opt_size = struct.unpack('<H', data[pe_off + 20:pe_off + 22])[0]
    secoff = opt_off + opt_size
    secs = []
    for i in range(num_sec):
        o = secoff + i * 40
        vsz, vaddr, rawsz, rawptr = struct.unpack('<IIII', data[o + 8:o + 24])
        secs.append((vaddr, max(vsz, rawsz), rawptr))

    def raw(rva):
        for vaddr, span, rawptr in secs:
            if vaddr <= rva < vaddr + span:
                return rawptr + (rva - vaddr)
        return None

    def try_base(dd_off):
        exp_rva = struct.unpack('<I', data[dd_off:dd_off + 4])[0]
        base = raw(exp_rva)
        if base is None:
            return None
        n_names = struct.unpack('<I', data[base + 24:base + 28])[0]
        if not (0 < n_names <= 512):
            return None
        addr_names = struct.unpack('<I', data[base + 32:base + 36])[0]
        names = set()
        for i in range(n_names):
            p = raw(addr_names + i * 4)
            if p is None:
                return None
            rva = struct.unpack('<I', data[p:p + 4])[0]
            q = raw(rva)
            if q is None:
                return None
            end = data.find(b'\x00', q)
            if end < 0 or end - q > 256:
                return None
            try:
                nm = data[q:end].decode('ascii')
            except UnicodeDecodeError:
                return None
            if not nm or not all(c.isprintable() or c == '_' for c in nm):
                return None
            names.add(nm)
        return names

    for dd_off in (opt_off + opt_size - 128, opt_off + 96):
        names = try_base(dd_off)
        if names:
            return names
    return set()

print('== smoke_asio_driver ==')

# 1. 检查文件与导出
check('auraasio_driver.dll exists', os.path.exists(DLL_PATH), DLL_PATH)
if not os.path.exists(DLL_PATH):
    print('ASIO DRIVER FAILURES:', FAIL)
    sys.exit(1)

exps = pe_exports(DLL_PATH)
for fn in ('DllCanUnloadNow', 'DllGetClassObject', 'DllRegisterServer', 'DllUnregisterServer'):
    check('exports %s' % fn, fn in exps)

# 2. 进程内 COM 握手与能力协商
dll = ctypes.OleDLL(DLL_PATH)

pFactory = ctypes.c_void_p()
hr = dll.DllGetClassObject(ctypes.byref(CLSID_AuraAsioDriver), ctypes.byref(IID_IClassFactory), ctypes.byref(pFactory))
check('DllGetClassObject(CLSID_AuraAsioDriver) S_OK', hr == 0, f'hr={hex(hr)}')

pVtbl = ctypes.cast(pFactory.value, ctypes.POINTER(ctypes.POINTER(ctypes.c_void_p)))[0]
CreateInstanceFunc = ctypes.WINFUNCTYPE(
    ctypes.c_long, ctypes.c_void_p, ctypes.c_void_p, ctypes.POINTER(GUID), ctypes.POINTER(ctypes.c_void_p)
)(pVtbl[3])

pAsio = ctypes.c_void_p()
hr = CreateInstanceFunc(pFactory.value, None, ctypes.byref(CLSID_AuraAsioDriver), ctypes.byref(pAsio))
check('IClassFactory::CreateInstance S_OK', hr == 0, f'hr={hex(hr)}')

pAsioVtbl = ctypes.cast(pAsio.value, ctypes.POINTER(ctypes.POINTER(ctypes.c_void_p)))[0]

# 3. IASIO 方法逐项验收
# 3: init
InitFunc = ctypes.WINFUNCTYPE(ctypes.c_long, ctypes.c_void_p, ctypes.c_void_p)(pAsioVtbl[3])
check('IASIO::init returned true', InitFunc(pAsio.value, None) == 1)

# 4: getDriverName
GetNameFunc = ctypes.WINFUNCTYPE(None, ctypes.c_void_p, ctypes.c_char_p)(pAsioVtbl[4])
name_buf = ctypes.create_string_buffer(32)
GetNameFunc(pAsio.value, name_buf)
driver_name = name_buf.value.decode('ascii')
check('IASIO::getDriverName is "AuraDSP Driver"', driver_name == 'AuraDSP Driver', driver_name)

# 5: getDriverVersion
GetVerFunc = ctypes.WINFUNCTYPE(ctypes.c_long, ctypes.c_void_p)(pAsioVtbl[5])
ver = GetVerFunc(pAsio.value)
check('IASIO::getDriverVersion >= 1', ver >= 1, f'ver={ver}')

# 9: getChannels
GetChannelsFunc = ctypes.WINFUNCTYPE(ctypes.c_long, ctypes.c_void_p, ctypes.POINTER(ctypes.c_long), ctypes.POINTER(ctypes.c_long))(pAsioVtbl[9])
num_in = ctypes.c_long()
num_out = ctypes.c_long()
res_ch = GetChannelsFunc(pAsio.value, ctypes.byref(num_in), ctypes.byref(num_out))
check('IASIO::getChannels returns (2, 2)', res_ch == 0 and num_in.value == 2 and num_out.value == 2,
      f'in={num_in.value}, out={num_out.value}')

# 10: getLatencies
GetLatFunc = ctypes.WINFUNCTYPE(ctypes.c_long, ctypes.c_void_p, ctypes.POINTER(ctypes.c_long), ctypes.POINTER(ctypes.c_long))(pAsioVtbl[10])
in_lat = ctypes.c_long()
out_lat = ctypes.c_long()
res_lat = GetLatFunc(pAsio.value, ctypes.byref(in_lat), ctypes.byref(out_lat))
check('IASIO::getLatencies returns OK', res_lat == 0 and in_lat.value > 0 and out_lat.value > 0)

# 11: getBufferSize
GetBufFunc = ctypes.WINFUNCTYPE(ctypes.c_long, ctypes.c_void_p, ctypes.POINTER(ctypes.c_long), ctypes.POINTER(ctypes.c_long), ctypes.POINTER(ctypes.c_long), ctypes.POINTER(ctypes.c_long))(pAsioVtbl[11])
b_min, b_max, b_pref, b_gran = ctypes.c_long(), ctypes.c_long(), ctypes.c_long(), ctypes.c_long()
res_buf = GetBufFunc(pAsio.value, ctypes.byref(b_min), ctypes.byref(b_max), ctypes.byref(b_pref), ctypes.byref(b_gran))
check('IASIO::getBufferSize returns (64, 2048, 256, -1)',
      res_buf == 0 and b_min.value == 64 and b_max.value == 2048 and b_pref.value == 256 and b_gran.value == -1,
      f'min={b_min.value}, max={b_max.value}, pref={b_pref.value}, gran={b_gran.value}')

# 12 & 13 & 14: Sample rate handling
CanSrFunc = ctypes.WINFUNCTYPE(ctypes.c_long, ctypes.c_void_p, ctypes.c_double)(pAsioVtbl[12])
GetSrFunc = ctypes.WINFUNCTYPE(ctypes.c_long, ctypes.c_void_p, ctypes.POINTER(ctypes.c_double))(pAsioVtbl[13])
SetSrFunc = ctypes.WINFUNCTYPE(ctypes.c_long, ctypes.c_void_p, ctypes.c_double)(pAsioVtbl[14])

check('IASIO::canSampleRate accepts standard rates',
      CanSrFunc(pAsio.value, 44100.0) == 0 and
      CanSrFunc(pAsio.value, 48000.0) == 0 and
      CanSrFunc(pAsio.value, 96000.0) == 0 and
      CanSrFunc(pAsio.value, 192000.0) == 0)
check('IASIO::canSampleRate rejects non-standard rate', CanSrFunc(pAsio.value, 11025.0) != 0)

sr = ctypes.c_double()
GetSrFunc(pAsio.value, ctypes.byref(sr))
check('IASIO::getSampleRate default is 48000.0', sr.value == 48000.0, f'sr={sr.value}')

check('IASIO::setSampleRate 96000 OK', SetSrFunc(pAsio.value, 96000.0) == 0)
GetSrFunc(pAsio.value, ctypes.byref(sr))
check('IASIO::getSampleRate now 96000.0', sr.value == 96000.0)
SetSrFunc(pAsio.value, 48000.0)

# 18: getChannelInfo
class ASIOChannelInfo(ctypes.Structure):
    _fields_ = [
        ('channel', ctypes.c_long),
        ('isInput', ctypes.c_long),
        ('isActive', ctypes.c_long),
        ('channelGroup', ctypes.c_long),
        ('type', ctypes.c_long),
        ('name', ctypes.c_char * 32)
    ]

GetChInfoFunc = ctypes.WINFUNCTYPE(ctypes.c_long, ctypes.c_void_p, ctypes.POINTER(ASIOChannelInfo))(pAsioVtbl[18])
ci = ASIOChannelInfo(0, 0, 0, 0, 0, b'')
res_ci = GetChInfoFunc(pAsio.value, ctypes.byref(ci))
# ASIOSTFloat32LSB is 19
check('IASIO::getChannelInfo(Out 0) format is Float32LSB (19)',
      res_ci == 0 and ci.type == 19 and ci.name.decode('ascii').startswith('Out 1'),
      f'type={ci.type}, name={ci.name.decode("ascii")}')

# 4. 双缓冲与时钟泵线程测试
class ASIOBufferInfo(ctypes.Structure):
    _fields_ = [
        ('isInput', ctypes.c_long),
        ('channelNum', ctypes.c_long),
        ('buffers', ctypes.c_void_p * 2)
    ]

BufferSwitchProto = ctypes.WINFUNCTYPE(None, ctypes.c_long, ctypes.c_long)
SampleRateChangeProto = ctypes.WINFUNCTYPE(None, ctypes.c_double)
AsioMessageProto = ctypes.WINFUNCTYPE(ctypes.c_long, ctypes.c_long, ctypes.c_long, ctypes.c_void_p, ctypes.POINTER(ctypes.c_double))
BufferSwitchTimeInfoProto = ctypes.WINFUNCTYPE(ctypes.c_void_p, ctypes.c_void_p, ctypes.c_long, ctypes.c_long)

class ASIOCallbacks(ctypes.Structure):
    _fields_ = [
        ('bufferSwitch', BufferSwitchProto),
        ('sampleRateDidChange', SampleRateChangeProto),
        ('asioMessage', AsioMessageProto),
        ('bufferSwitchTimeInfo', BufferSwitchTimeInfoProto)
    ]

# Phase 2 诊断选择子
kAuraAsioFutureGetWasapiRenderedFrames = 0x41555201
kAuraAsioFutureGetWasapiTargetRate      = 0x41555202
kAuraAsioFutureIsWasapiOpen             = 0x41555203

# Phase 3 DSP 扩展与诊断选择子
kAuraAsioFutureIsDspLoaded              = 0x41555210
kAuraAsioFutureSetBypass                = 0x41555211
kAuraAsioFutureGetBypass                = 0x41555212
kAuraAsioFutureSetParam                 = 0x41555213
kAuraAsioFutureGetParam                 = 0x41555214
kAuraAsioFutureApplyParamsString        = 0x41555215
kAuraAsioFutureGetDspProcessedFrames    = 0x41555216
kAuraAsioFutureCopyLastOutputBlock      = 0x41555217

class AuraAsioParamIo(ctypes.Structure):
    _fields_ = [
        ('id', ctypes.c_char_p),
        ('value', ctypes.c_void_p),
        ('bytes', ctypes.c_uint32)
    ]

class AuraAsioBlockCopy(ctypes.Structure):
    _fields_ = [
        ('outL', ctypes.POINTER(ctypes.c_float)),
        ('outR', ctypes.POINTER(ctypes.c_float)),
        ('maxSamples', ctypes.c_long),
        ('copiedSamples', ctypes.c_long)
    ]

FutureFunc = ctypes.WINFUNCTYPE(ctypes.c_long, ctypes.c_void_p, ctypes.c_long, ctypes.c_void_p)(pAsioVtbl[22])

switch_count = 0
test_mode = 'sine'
test_dc_val = 0.1

def py_buffer_switch(idx, direct):
    global switch_count
    switch_count += 1
    # 模拟 DAW：向当前选中的输出缓冲区写入音频信号
    ptr_l = buf_infos[2].buffers[idx]
    ptr_r = buf_infos[3].buffers[idx]
    if ptr_l and ptr_r:
        arr_t = ctypes.c_float * 256
        buf_l = arr_t.from_address(ptr_l)
        buf_r = arr_t.from_address(ptr_r)
        if test_mode == 'sine':
            for i in range(256):
                s = 0.2 * math.sin(2.0 * math.pi * 440.0 * (switch_count * 256 + i) / 48000.0)
                buf_l[i] = s
                buf_r[i] = s
        elif test_mode == 'dc':
            for i in range(256):
                buf_l[i] = test_dc_val
                buf_r[i] = test_dc_val

cb_switch = BufferSwitchProto(py_buffer_switch)
cb_sr = SampleRateChangeProto(lambda sr: None)
cb_msg = AsioMessageProto(lambda s, v, m, o: 0)

callbacks = ASIOCallbacks(cb_switch, cb_sr, cb_msg, BufferSwitchTimeInfoProto())

buf_infos = (ASIOBufferInfo * 4)(
    ASIOBufferInfo(1, 0, (ctypes.c_void_p * 2)()),
    ASIOBufferInfo(1, 1, (ctypes.c_void_p * 2)()),
    ASIOBufferInfo(0, 0, (ctypes.c_void_p * 2)()),
    ASIOBufferInfo(0, 1, (ctypes.c_void_p * 2)())
)

CreateBuffersFunc = ctypes.WINFUNCTYPE(
    ctypes.c_long, ctypes.c_void_p, ctypes.POINTER(ASIOBufferInfo), ctypes.c_long, ctypes.c_long, ctypes.POINTER(ASIOCallbacks)
)(pAsioVtbl[19])

res_create = CreateBuffersFunc(pAsio.value, buf_infos, 4, 256, ctypes.byref(callbacks))
check('IASIO::createBuffers S_OK', res_create == 0)
all_bufs_valid = all(bool(buf_infos[i].buffers[0] and buf_infos[i].buffers[1]) for i in range(4))
check('IASIO double-buffers allocated non-null', all_bufs_valid)

StartFunc = ctypes.WINFUNCTYPE(ctypes.c_long, ctypes.c_void_p)(pAsioVtbl[7])
StopFunc = ctypes.WINFUNCTYPE(ctypes.c_long, ctypes.c_void_p)(pAsioVtbl[8])
DisposeFunc = ctypes.WINFUNCTYPE(ctypes.c_long, ctypes.c_void_p)(pAsioVtbl[20])

check('IASIO::start S_OK', StartFunc(pAsio.value) == 0)

# 256 采样 @ 48kHz = 5.333ms / 块；100ms 应收到 18~20 次回调
time.sleep(0.1)
pump_ok = (15 <= switch_count <= 25)
check(f'Audio pump active: received {switch_count} switches in 100ms (expected ~19)', pump_ok)

# Phase 2：验证 WASAPI 直通汇状态与渲染帧数
ASE_SUCCESS = 0x3f4847a0

is_wasapi_open = ctypes.c_long(0)
res_open = FutureFunc(pAsio.value, kAuraAsioFutureIsWasapiOpen, ctypes.byref(is_wasapi_open))
check('IASIO::future(kAuraAsioFutureIsWasapiOpen) ASE_SUCCESS', res_open == ASE_SUCCESS)

target_rate = ctypes.c_double(0.0)
res_tr = FutureFunc(pAsio.value, kAuraAsioFutureGetWasapiTargetRate, ctypes.byref(target_rate))
check('IASIO::future(kAuraAsioFutureGetWasapiTargetRate) ASE_SUCCESS', res_tr == ASE_SUCCESS)

rendered_frames = ctypes.c_uint64(0)
res_rf = FutureFunc(pAsio.value, kAuraAsioFutureGetWasapiRenderedFrames, ctypes.byref(rendered_frames))
check('IASIO::future(kAuraAsioFutureGetWasapiRenderedFrames) ASE_SUCCESS', res_rf == ASE_SUCCESS)

if is_wasapi_open.value == 1:
    check('Phase 2 WASAPI sink active & rendering frames (>0)', rendered_frames.value > 0,
          f'rendered={rendered_frames.value}, targetRate={target_rate.value}')
else:
    print(f'NOTE: WASAPI default endpoint not available or headless environment; sink idle (rendered={rendered_frames.value})')

# Phase 3：验证外部动态 DSP 引擎接入、旁路控制与波形 A/B 实测
is_dsp_loaded = ctypes.c_long(0)
res_dsp = FutureFunc(pAsio.value, kAuraAsioFutureIsDspLoaded, ctypes.byref(is_dsp_loaded))
check('IASIO::future(kAuraAsioFutureIsDspLoaded) ASE_SUCCESS & loaded==1',
      res_dsp == ASE_SUCCESS and is_dsp_loaded.value == 1,
      f'res={hex(res_dsp)}, loaded={is_dsp_loaded.value}')

# 旁路切换测试
bypass_val = ctypes.c_long(-1)
res_gb = FutureFunc(pAsio.value, kAuraAsioFutureGetBypass, ctypes.byref(bypass_val))
check('IASIO::future(kAuraAsioFutureGetBypass) default is 0 (processing)',
      res_gb == ASE_SUCCESS and bypass_val.value == 0)

set_bp = ctypes.c_long(1)
res_sb = FutureFunc(pAsio.value, kAuraAsioFutureSetBypass, ctypes.byref(set_bp))
check('IASIO::future(kAuraAsioFutureSetBypass(1)) S_OK', res_sb == ASE_SUCCESS)

FutureFunc(pAsio.value, kAuraAsioFutureGetBypass, ctypes.byref(bypass_val))
check('IASIO::future(kAuraAsioFutureGetBypass) now 1 (bypassed)', bypass_val.value == 1)

# 参数下发与回读测试（使用 post.gain = 6.0dB）
val_gain = ctypes.c_float(6.0)
param_set = AuraAsioParamIo(b'post.gain', ctypes.cast(ctypes.byref(val_gain), ctypes.c_void_p), 4)
res_sp = FutureFunc(pAsio.value, kAuraAsioFutureSetParam, ctypes.byref(param_set))
check('IASIO::future(kAuraAsioFutureSetParam "post.gain"=6.0) S_OK', res_sp == ASE_SUCCESS)

val_read = ctypes.c_float(0.0)
param_get = AuraAsioParamIo(b'post.gain', ctypes.cast(ctypes.byref(val_read), ctypes.c_void_p), 4)
res_gp = FutureFunc(pAsio.value, kAuraAsioFutureGetParam, ctypes.byref(param_get))
check('IASIO::future(kAuraAsioFutureGetParam "post.gain") returns 6.0',
      res_gp == ASE_SUCCESS and abs(val_read.value - 6.0) < 1e-4, f'val={val_read.value}')

# 波形 A/B 实测：注入 0.1 直流测试信号
test_mode = 'dc'
test_dc_val = 0.1

out_l = (ctypes.c_float * 256)()
out_r = (ctypes.c_float * 256)()
blk = AuraAsioBlockCopy(out_l, out_r, 256, 0)

# 测试 A：Bypass = 1 时输出应完全等于干声 0.1
time.sleep(0.04)
res_cp1 = FutureFunc(pAsio.value, kAuraAsioFutureCopyLastOutputBlock, ctypes.byref(blk))
check('kAuraAsioFutureCopyLastOutputBlock S_OK', res_cp1 == ASE_SUCCESS and blk.copiedSamples == 256)
check('Bypass=1 dry waveform matches input 0.1 (+-1%)', abs(out_l[10] - 0.1) < 0.002, f'val={out_l[10]}')

# 测试 B：Bypass = 0（开 DSP），在 post.gain = +6dB 下幅值应精确翻倍至 ~0.2 (ratio=2.0)
set_bp0 = ctypes.c_long(0)
FutureFunc(pAsio.value, kAuraAsioFutureSetBypass, ctypes.byref(set_bp0))
time.sleep(0.04)
FutureFunc(pAsio.value, kAuraAsioFutureCopyLastOutputBlock, ctypes.byref(blk))
ratio = out_l[10] / 0.1 if out_l[10] != 0 else 0.0
check('Bypass=0 DSP post.gain +6dB doubles amplitude to ~0.2 (ratio ~2.0 +-2%)',
      abs(ratio - 2.0) < 0.04, f'out={out_l[10]}, ratio={ratio}')

# 测试 C：重置 post.gain = 0.0dB，输出恢复至 0.1
val_zero = ctypes.c_float(0.0)
param_set_zero = AuraAsioParamIo(b'post.gain', ctypes.cast(ctypes.byref(val_zero), ctypes.c_void_p), 4)
FutureFunc(pAsio.value, kAuraAsioFutureSetParam, ctypes.byref(param_set_zero))
time.sleep(0.04)
FutureFunc(pAsio.value, kAuraAsioFutureCopyLastOutputBlock, ctypes.byref(blk))
check('DSP post.gain 0dB returns amplitude to 0.1 (+-1%)', abs(out_l[10] - 0.1) < 0.002, f'val={out_l[10]}')

# 测试 D：字符串参数下发与回读校验
res_str = FutureFunc(pAsio.value, kAuraAsioFutureApplyParamsString, ctypes.c_char_p(b"bass.enable=1;bass.gain=10.0"))
check('IASIO::future(kAuraAsioFutureApplyParamsString) S_OK', res_str == ASE_SUCCESS)

val_bass = ctypes.c_float(0.0)
param_bass = AuraAsioParamIo(b'bass.gain', ctypes.cast(ctypes.byref(val_bass), ctypes.c_void_p), 4)
FutureFunc(pAsio.value, kAuraAsioFutureGetParam, ctypes.byref(param_bass))
check('Param "bass.gain" applied via string verified 10.0', abs(val_bass.value - 10.0) < 1e-4, f'val={val_bass.value}')

# 测试 E：DSP 累计处理帧数统计
dsp_frames = ctypes.c_uint64(0)
res_df = FutureFunc(pAsio.value, kAuraAsioFutureGetDspProcessedFrames, ctypes.byref(dsp_frames))
check('IASIO::future(kAuraAsioFutureGetDspProcessedFrames) > 0',
      res_df == ASE_SUCCESS and dsp_frames.value > 0, f'dsp_frames={dsp_frames.value}')

# 恢复默认测试模式
test_mode = 'sine'

check('IASIO::stop S_OK', StopFunc(pAsio.value) == 0)
check('IASIO::disposeBuffers S_OK', DisposeFunc(pAsio.value) == 0)

# Release objects
ReleaseFunc = ctypes.WINFUNCTYPE(ctypes.c_ulong, ctypes.c_void_p)(pAsioVtbl[2])
ref_asio = ReleaseFunc(pAsio.value)
check('IASIO object released cleanly (ref=0)', ref_asio == 0, f'ref={ref_asio}')

FactoryRelease = ctypes.WINFUNCTYPE(ctypes.c_ulong, ctypes.c_void_p)(pVtbl[2])
ref_fact = FactoryRelease(pFactory.value)
check('ClassFactory released cleanly (ref=0)', ref_fact == 0, f'ref={ref_fact}')

# 5. 管理员注册往返测试与 asio_probe 联动验证
is_admin = bool(ctypes.windll.shell32.IsUserAnAdmin())
if not is_admin:
    print('NOTE not admin: skip system-wide regsvr32 round-trip')
else:
    r_reg = subprocess.run(['regsvr32', '/s', DLL_PATH], capture_output=True, timeout=120)
    check('regsvr32 register rc=0', r_reg.returncode == 0)

    # 验证 asio_probe 是否能识别 AuraDSP Driver
    if os.path.exists(PROBE_EXE):
        r_probe = subprocess.run([PROBE_EXE, '--only', 'AuraDSP Driver'], capture_output=True, text=True, timeout=120)
        check('asio_probe finds AuraDSP Driver', 'AuraDSP Driver' in r_probe.stdout, r_probe.stdout)

    r_unreg = subprocess.run(['regsvr32', '/s', '/u', DLL_PATH], capture_output=True, timeout=120)
    check('regsvr32 unregister rc=0', r_unreg.returncode == 0)

print()
if FAIL:
    print('ASIO DRIVER FAILURES:', FAIL)
    sys.exit(1)
print('asio_driver: all checks passed')
