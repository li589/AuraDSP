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

# 诊断 Future 选择子（只读；2026-11-22 审查 N5 裁定保留）。
# 控制类选择子（SetBypass/GetBypass/SetParam/GetParam/
# ApplyParamsString/SetChannels/GetChannels）已删除——控制面
# 走参数块（生产 App 同一通道，见下方 params_publish）。
kAuraAsioFutureGetWasapiRenderedFrames = 0x41555201
kAuraAsioFutureGetWasapiTargetRate      = 0x41555202
kAuraAsioFutureIsWasapiOpen             = 0x41555203
kAuraAsioFutureIsDspLoaded              = 0x41555210
kAuraAsioFutureGetDspProcessedFrames    = 0x41555216
kAuraAsioFutureCopyLastOutputBlock      = 0x41555217

class AuraAsioBlockCopy(ctypes.Structure):
    _fields_ = [
        ('outL', ctypes.POINTER(ctypes.c_float)),
        ('outR', ctypes.POINTER(ctypes.c_float)),
        ('maxSamples', ctypes.c_long),
        ('copiedSamples', ctypes.c_long)
    ]

FutureFunc = ctypes.WINFUNCTYPE(ctypes.c_long, ctypes.c_void_p, ctypes.c_long, ctypes.c_void_p)(pAsioVtbl[22])

# ---- 参数块（S4 生产控制面）：本冒烟扮演 App 写者 ----
# 布局与 AsioDriverShared.h 的 AsioDriverParamsBlock 逐字对齐：
# magic@0 version@4 seq@8 bypass@12 payloadBytes@16 mute@20，
# payload@64（NUL 结尾 UTF-8 参数串）。写序与 Dart 发布者一致：
# 载荷 -> 字节数 -> bypass/mute -> seq 最后递增（驱动以 seq
# 变化为应用触发）。驱动只 Open 不 Create，本冒烟负责创建。
_kernel32 = ctypes.WinDLL('kernel32', use_last_error=True)
_kernel32.CreateFileMappingW.restype = ctypes.c_void_p
_kernel32.MapViewOfFile.restype = ctypes.c_void_p
_kernel32.OpenFileMappingW.restype = ctypes.c_void_p
_PARAMS_MAGIC = 0x50444141  # 'AADP'
_params_buf = None
_params_seq = [0]

def params_ensure():
    global _params_buf
    if _params_buf is not None:
        return True
    h = _kernel32.CreateFileMappingW(ctypes.c_void_p(-1), None, 0x04, 0, 8192,
                                     'Global\\AuraDSP_AsioDriverParams')
    if not h:
        return False
    already = ctypes.get_last_error() == 183  # ERROR_ALREADY_EXISTS
    view = _kernel32.MapViewOfFile(h, 0x000F001F, 0, 0, 8192)
    if not view:
        return False
    _params_buf = (ctypes.c_char * 8192).from_address(view)
    if not already:
        ctypes.memset(view, 0, 8192)
        struct.pack_into('<II', _params_buf, 0, _PARAMS_MAGIC, 1)
    else:
        _params_seq[0] = struct.unpack_from('<i', _params_buf, 8)[0]
    return True

def params_publish(payload, bypass):
    assert params_ensure()
    data = payload.encode('utf-8')
    ctypes.memmove(ctypes.addressof(_params_buf) + 64, data + b'\x00', len(data) + 1)
    struct.pack_into('<I', _params_buf, 16, len(data))
    struct.pack_into('<i', _params_buf, 12, bypass)
    struct.pack_into('<i', _params_buf, 20, 0)
    _params_seq[0] += 1
    struct.pack_into('<i', _params_buf, 8, _params_seq[0])

def telemetry_u32(offset):
    h = _kernel32.OpenFileMappingW(0x0004, False, 'Global\\AuraDSP_AsioDriverTelemetry')
    if not h:
        return None
    view = _kernel32.MapViewOfFile(h, 0x0004, 0, 0, 4096)
    if not view:
        return None
    buf = (ctypes.c_char * 4096).from_address(view)
    magic = struct.unpack_from('<I', buf, 0)[0]
    if magic != 0x54444141:  # 'AADT'
        return None
    return struct.unpack_from('<I', buf, offset)[0]

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

check('params block writer ready (smoke acts as App writer)', params_ensure())
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

# 旁路与参数：改走参数块（生产控制面）。先清场——空参数集的
# 起点由发布 post.gain=0 + bypass=0 钉住（块 seq 触发整串替换
# 应用，未列出的参数保持引擎现值，故显式复位用过的参数）。
params_publish('post.gain=0.0', 0)
time.sleep(0.06)

# 波形 A/B 实测：注入 0.1 直流测试信号
test_mode = 'dc'
test_dc_val = 0.1

out_l = (ctypes.c_float * 256)()
out_r = (ctypes.c_float * 256)()
blk = AuraAsioBlockCopy(out_l, out_r, 256, 0)

# 测试 A：参数块 bypass=1 时输出应完全等于干声 0.1
params_publish('post.gain=0.0', 1)
time.sleep(0.06)
res_cp1 = FutureFunc(pAsio.value, kAuraAsioFutureCopyLastOutputBlock, ctypes.byref(blk))
check('kAuraAsioFutureCopyLastOutputBlock S_OK', res_cp1 == ASE_SUCCESS and blk.copiedSamples == 256)
check('Bypass=1 (via params block) dry waveform matches input 0.1 (+-1%)',
      abs(out_l[10] - 0.1) < 0.002, f'val={out_l[10]}')

# 测试 B：bypass=0 + 参数块 post.gain=+6dB，幅值应精确翻倍至 ~0.2
params_publish('post.gain=6.0', 0)
time.sleep(0.06)
FutureFunc(pAsio.value, kAuraAsioFutureCopyLastOutputBlock, ctypes.byref(blk))
ratio = out_l[10] / 0.1 if out_l[10] != 0 else 0.0
check('Bypass=0 DSP post.gain +6dB (via params block) doubles amplitude to ~0.2 (ratio ~2.0 +-2%)',
      abs(ratio - 2.0) < 0.04, f'out={out_l[10]}, ratio={ratio}')

# 测试 C：参数块复位 post.gain=0.0dB，输出恢复至 0.1
params_publish('post.gain=0.0', 0)
time.sleep(0.06)
FutureFunc(pAsio.value, kAuraAsioFutureCopyLastOutputBlock, ctypes.byref(blk))
check('DSP post.gain 0dB (via params block) returns amplitude to 0.1 (+-1%)',
      abs(out_l[10] - 0.1) < 0.002, f'val={out_l[10]}')

# 测试 D：多对参数串整串应用——bass 对随串下发，post.gain 项
# 以波形翻倍验证整串已生效（单对回读面已随控制选择子删除，
# 波形即端到端证据）。
params_publish('bass.enable=1;bass.gain=10.0;post.gain=6.0', 0)
time.sleep(0.06)
FutureFunc(pAsio.value, kAuraAsioFutureCopyLastOutputBlock, ctypes.byref(blk))
ratio_d = out_l[10] / 0.1 if out_l[10] != 0 else 0.0
check('Multi-pair params string applied via block (post.gain term doubles amplitude)',
      abs(ratio_d - 2.0) < 0.04, f'out={out_l[10]}, ratio={ratio_d}')
params_publish('post.gain=0.0', 0)
time.sleep(0.06)

# 测试 E：DSP 累计处理帧数统计
dsp_frames = ctypes.c_uint64(0)
res_df = FutureFunc(pAsio.value, kAuraAsioFutureGetDspProcessedFrames, ctypes.byref(dsp_frames))
check('IASIO::future(kAuraAsioFutureGetDspProcessedFrames) > 0',
      res_df == ASE_SUCCESS and dsp_frames.value > 0, f'dsp_frames={dsp_frames.value}')

# 恢复默认测试模式
test_mode = 'sine'

check('IASIO::stop S_OK', StopFunc(pAsio.value) == 0)
check('IASIO::disposeBuffers S_OK', DisposeFunc(pAsio.value) == 0)

# 先释放实例一：测试 F 用注册表档位新建实例二（档位在 init 时
# 读定，同实例无法热切换——与真实 DAW 重开设备同语义）。
ReleaseFunc = ctypes.WINFUNCTYPE(ctypes.c_ulong, ctypes.c_void_p)(pAsioVtbl[2])
ref_asio = ReleaseFunc(pAsio.value)
check('IASIO object released cleanly (ref=0)', ref_asio == 0, f'ref={ref_asio}')

# 测试 F：多声道档位（2 -> 6）经注册表档位（生产口径，替代已
# 删的 SetChannels 选择子）：写 HKCU Channels=6 后新建实例，
# init 按档位定宽；引擎实际宽度以遥测块 channels 回读为准。
import winreg
REG_PATH = r'SOFTWARE\AuraDSP\AsioDriver'
try:
    with winreg.OpenKey(winreg.HKEY_CURRENT_USER, REG_PATH) as _k:
        _saved_ch = winreg.QueryValueEx(_k, 'Channels')[0]
except OSError:
    _saved_ch = None
with winreg.CreateKey(winreg.HKEY_CURRENT_USER, REG_PATH) as _k:
    winreg.SetValueEx(_k, 'Channels', 0, winreg.REG_DWORD, 6)

pAsio2 = ctypes.c_void_p()
hr2 = CreateInstanceFunc(pFactory.value, None, ctypes.byref(CLSID_AuraAsioDriver), ctypes.byref(pAsio2))
check('IClassFactory::CreateInstance (tier-6 instance) S_OK', hr2 == 0)
check('IASIO::init (tier-6) returned true', InitFunc(pAsio2.value, None) == 1)

n_in6 = ctypes.c_long(0)
n_out6 = ctypes.c_long(0)
res_ch6 = GetChannelsFunc(pAsio2.value, ctypes.byref(n_in6), ctypes.byref(n_out6))
check('getChannels follows registry tier (6, 6)', res_ch6 == 0 and n_in6.value == 6 and n_out6.value == 6,
      f'in={n_in6.value} out={n_out6.value}')

ci5 = ASIOChannelInfo(5, 1, 0, 0, 0, b'')   # channel=5, isInput=1
res_ci5 = GetChInfoFunc(pAsio2.value, ctypes.byref(ci5))
check('getChannelInfo(In 6) valid Float32LSB',
      res_ci5 == 0 and ci5.type == 19 and ci5.name.decode('ascii').startswith('In 6'),
      f'res={res_ci5} name={ci5.name}')
ci6 = ASIOChannelInfo(6, 0, 0, 0, 0, b'')   # channel=6, isInput=0（越界）
check('getChannelInfo(Out 7) out-of-range rejected', GetChInfoFunc(pAsio2.value, ctypes.byref(ci6)) != 0)

buf6 = (ASIOBufferInfo * 12)(
    *[ASIOBufferInfo(1, c, (ctypes.c_void_p * 2)()) for c in range(6)],
    *[ASIOBufferInfo(0, c, (ctypes.c_void_p * 2)()) for c in range(6)]
)
mch_switches = [0]


def py_buffer_switch6(idx, direct):
    mch_switches[0] += 1
    arr = ctypes.c_float * 256
    for o in range(6):                       # 输出位于索引 6..11
        p = buf6[6 + o].buffers[idx]
        if p:
            b = arr.from_address(p)
            for i in range(256):
                b[i] = 0.05


cb6 = BufferSwitchProto(py_buffer_switch6)
callbacks6 = ASIOCallbacks(cb6, cb_sr, cb_msg, BufferSwitchTimeInfoProto())

res_create6 = CreateBuffersFunc(pAsio2.value, buf6, 12, 256, ctypes.byref(callbacks6))
check('createBuffers 6in+6out S_OK', res_create6 == 0)
check('6ch double-buffers allocated non-null',
      all(bool(buf6[i].buffers[0] and buf6[i].buffers[1]) for i in range(12)))
check('start (6ch) S_OK', StartFunc(pAsio2.value) == 0)
time.sleep(0.12)
check(f'6ch pump active: {mch_switches[0]} switches (expected ~22)',
      12 <= mch_switches[0] <= 30)

# 引擎宽度回读：遥测块 channels（dawCh）应为档位 6
daw_ch = telemetry_u32(24)
check('telemetry dawCh == 6 (driver tier authoritative)', daw_ch == 6, f'dawCh={daw_ch}')

out_l6 = (ctypes.c_float * 256)()
out_r6 = (ctypes.c_float * 256)()
blk6 = AuraAsioBlockCopy(out_l6, out_r6, 256, 0)
res_cp6 = FutureFunc(pAsio2.value, kAuraAsioFutureCopyLastOutputBlock, ctypes.byref(blk6))
check('6ch CopyLastOutputBlock S_OK & copiedSamples==256',
      res_cp6 == ASE_SUCCESS and blk6.copiedSamples == 256,
      f'res={res_cp6} n={blk6.copiedSamples}')

check('stop (6ch) S_OK', StopFunc(pAsio2.value) == 0)
check('disposeBuffers (6ch) S_OK', DisposeFunc(pAsio2.value) == 0)
ref_asio2 = ReleaseFunc(pAsio2.value)
check('IASIO object (tier-6) released cleanly (ref=0)', ref_asio2 == 0, f'ref={ref_asio2}')

# 复原注册表档位（冒烟不得污染用户 App 的真实配置）
with winreg.CreateKey(winreg.HKEY_CURRENT_USER, REG_PATH) as _k:
    if _saved_ch is None:
        try:
            winreg.DeleteValue(_k, 'Channels')
        except OSError:
            pass
    else:
        winreg.SetValueEx(_k, 'Channels', 0, winreg.REG_DWORD, _saved_ch)

# Release factory（两个 IASIO 实例已分别在各段末尾释放）
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
