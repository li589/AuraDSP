// audio_in_wasapi.dart —— Windows WASAPI 设备捕获（COM vtable 直调）。
//
// 管线全接线（2026-11-10 用户裁定）新增：此前 Windows 侧零捕获
// 实现，管线 WASAPI 输入（回录/麦克风）是空壳。本文件与
// audio_out_wasapi.dart 镜像组织：同一 enumerator/COM 模式、
// 同一 WavFormatEx 解析、同一 Initialize 请求率+回退口径。
//
// 两种流向由 init 的 loopback 决定：
// loopback=true —— 在端点上以 AUDCLNT_STREAMFLAGS_
// LOOPBACK 打开捕获，抓该端点的渲染混音
// （内录/回录语义）；
// loopback=false —— 在端点（麦克风等）上普通捕获。
//
// 消费模型是拉模型：drainInto 把当前所有待读整包排空、转
// float 立体声写入调用方缓冲（IAudioCaptureClient 要求整包
// 消费，装不下整包时留待下轮，绝不部分读）。
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../debug_log.dart';
import 'audio_out_wasapi.dart' show Guid, WavFormatEx;

const _iidDeviceEnumerator = 'A95664D2-9614-4F35-A746-DE8DB63617E6';
const _clsidDeviceEnumerator = 'BCDE0395-E52F-467C-8E3D-C4579291692E';
const _iidAudioClient = '1CB9AD4C-DBFA-4C32-B178-C2F568A703B2';
const _iidAudioCaptureClient = 'C8ADBD64-E71E-48A0-A4DE-185C395CD317';

const _audclntStreamflagsLoopback = 0x00020000;
const _audclntBufferflagsSilent = 0x2;

Pointer<T> _vt<T extends NativeType>(Pointer<Void> obj, int index) {
final vtbl = obj.cast<Pointer<Pointer<Void>>>().value;
return vtbl[index].cast<T>();
}

/// WASAPI 捕获设备（渲染端点回录 / 捕获端点直采）。
///
/// 生命周期：init → start → drainInto* → stop。init 一次性
/// （COM 对象字段 late final），换端点须新建实例（与
/// WasapiOut 同口径）。
final class WasapiCapture {
final DynamicLibrary ole32 = DynamicLibrary.open('ole32.dll');

late final int Function(Pointer<Guid>, Pointer<Void>, int, Pointer<Guid>,
Pointer<Pointer<Void>>) coCreateInstance = ole32
.lookup<
NativeFunction<
Int32 Function(Pointer<Guid>, Pointer<Void>, Uint32,
Pointer<Guid>, Pointer<Pointer<Void>>)>>('CoCreateInstance')
.asFunction<int Function(Pointer<Guid>, Pointer<Void>, int, Pointer<Guid>,
Pointer<Pointer<Void>>)>();

late final int Function(int, int) coInitializeEx = ole32
.lookup<NativeFunction<Int32 Function(IntPtr, Uint32)>>('CoInitializeEx')
.asFunction<int Function(int, int)>();

late final void Function(Pointer<Void>) coTaskMemFree = ole32
.lookup<NativeFunction<Void Function(Pointer<Void>)>>('CoTaskMemFree')
.asFunction();

// 捕获热路径 vtable 方法（init 末段绑定）
late final int Function(Pointer<Void>, Pointer<Pointer<Uint8>>,
Pointer<Uint32>, Pointer<Uint32>, Pointer<Uint64>, Pointer<Uint64>)
getBufferFn;
late final int Function(Pointer<Void>, int) releaseBufferFn;
late final int Function(Pointer<Void>, Pointer<Uint32>)
getNextPacketSizeFn;
late final int Function(Pointer<Void>) startFn, stopFn;

late final Pointer<Void> enumerator, device, client, captureClient;
late final WavFormatEx mix;

late final int bufferFrames;
bool started = false;

/// 打开来源：'loopback'（渲染端点回录）或 'capture'（捕获端点）。
String flow = '';

int get sampleRate => mix.sampleRate;
int get channels => mix.channels;

void init({
String endpointId = '',
required bool loopback,
int? requestedSampleRate,
}) {
flow = loopback? 'loopback': 'capture';
dbgLog('WASAPI-IN init: begin flow=$flow id=${endpointId.isEmpty? "(default)": endpointId}');
final hr = coInitializeEx(0, 0x0); // COINIT_MULTITHREADED
if (hr < 0 && hr!= -2147417850) {
throw StateError('CoInitializeEx hr=$hr');
}
final clsid = Guid.alloc(_clsidDeviceEnumerator);
final iidEnum = Guid.alloc(_iidDeviceEnumerator);
final pEnum = malloc<Pointer<Void>>();
try {
_hr('CoCreateInstance',
coCreateInstance(clsid, nullptr, 23 /*CLSCTX_ALL*/, iidEnum, pEnum));
enumerator = pEnum.value;
} finally {
malloc.free(clsid);
malloc.free(iidEnum);
malloc.free(pEnum);
}

final pDev = malloc<Pointer<Void>>();
if (endpointId.isNotEmpty) {
final getDevice = _vt<NativeFunction<
Int32 Function(Pointer<Void>, Pointer<Utf16>,
Pointer<Pointer<Void>>)>>(enumerator, 5)
.asFunction<int Function(Pointer<Void>, Pointer<Utf16>,
Pointer<Pointer<Void>>)>();
final idPtr = endpointId.toNativeUtf16();
try {
_hr('GetDevice', getDevice(enumerator, idPtr, pDev));
} finally {
malloc.free(idPtr);
}
dbgLog('WASAPI-IN GetDevice ok');
} else {
// GetDefaultAudioEndpoint：回录走渲染流向（eRender=0），
// 直采走捕获流向（eCapture=1）；角色同渲染侧 eMultimedia=1。
final getDefaultAudioEndpoint = _vt<NativeFunction<
Int32 Function(Pointer<Void>, Int32, Int32,
Pointer<Pointer<Void>>)>>(enumerator, 4)
.asFunction<int Function(Pointer<Void>, int, int,
Pointer<Pointer<Void>>)>();
_hr(
'GetDefaultAudioEndpoint',
getDefaultAudioEndpoint(
enumerator, loopback? 0: 1, 1, pDev));
dbgLog('WASAPI-IN GetDefaultAudioEndpoint ok');
}
device = pDev.value;
malloc.free(pDev);

// IMMDevice::Activate(IID_IAudioClient)
final activate = _vt<NativeFunction<
Int32 Function(Pointer<Void>, Pointer<Guid>, Uint32, Pointer<Void>,
Pointer<Pointer<Void>>)>>(device, 3)
.asFunction<int Function(Pointer<Void>, Pointer<Guid>, int,
Pointer<Void>, Pointer<Pointer<Void>>)>();
final iidClient = Guid.alloc(_iidAudioClient);
final pCli = malloc<Pointer<Void>>();
_hr('Activate', activate(device, iidClient, 1, nullptr, pCli));
malloc.free(iidClient);
client = pCli.value;
malloc.free(pCli);
dbgLog('WASAPI-IN Activate(IAudioClient) ok');

// IAudioClient::GetMixFormat（与渲染侧同一解析）
final getMixFormatFn = _vt<NativeFunction<
Int32 Function(Pointer<Void>, Pointer<Pointer<Void>>)>>(client, 8)
.asFunction<int Function(Pointer<Void>, Pointer<Pointer<Void>>)>();
final pFmt = malloc<Pointer<Void>>();
_hr('GetMixFormat', getMixFormatFn(client, pFmt));
final deviceMix = WavFormatEx.read(pFmt.value);
dbgLog('WASAPI-IN mix: tag=0x${deviceMix.formatTag.toRadixString(16)} '
'ch=${deviceMix.channels} rate=${deviceMix.sampleRate} '
'bits=${deviceMix.bitsPerSample} float=${deviceMix.isFloat}');

final initializeFn = _vt<NativeFunction<
Int32 Function(Pointer<Void>, Int32, Uint32, Int64, Int64,
Pointer<Void>, Pointer<Void>)>>(client, 3)
.asFunction<int Function(Pointer<Void>, int, int, int, int,
Pointer<Void>, Pointer<Void>)>();
final flags = loopback? _audclntStreamflagsLoopback: 0;

Pointer<Void> fmtPtr = pFmt.value;
Pointer<Uint8>? customFmt;
var requestedRateApplied = false;
if (requestedSampleRate!= null &&
requestedSampleRate > 0 &&
requestedSampleRate!= deviceMix.sampleRate) {
customFmt = deviceMix.cloneWithRate(requestedSampleRate);
fmtPtr = customFmt.cast<Void>();
requestedRateApplied = true;
}

var hrInit = initializeFn(client, 0, flags, 200000, 0, fmtPtr, nullptr);
if (hrInit!= 0 && requestedRateApplied) {
dbgLog('WASAPI-IN Initialize(rate=$requestedSampleRate) rejected '
'hr=0x${(hrInit & 0xFFFFFFFF).toRadixString(16)} — fallback to device mix');
final rejected = customFmt!;
customFmt = null;
requestedRateApplied = false;
fmtPtr = pFmt.value;
hrInit = initializeFn(client, 0, flags, 200000, 0, fmtPtr, nullptr);
malloc.free(rejected);
}
if (requestedRateApplied) {
mix = WavFormatEx.read(customFmt!.cast<Void>());
dbgLog('WASAPI-IN negotiated format: rate=${mix.sampleRate} '
'(device native ${deviceMix.sampleRate})');
} else {
mix = deviceMix;
}
dbgLog('WASAPI-IN Initialize hr=0x${(hrInit & 0xFFFFFFFF).toRadixString(16)}');
_hr('Initialize', hrInit);
if (customFmt!= null) malloc.free(customFmt);
coTaskMemFree(pFmt.value);
malloc.free(pFmt);

// GetBufferSize
final getBufferSizeFn = _vt<NativeFunction<
Int32 Function(Pointer<Void>, Pointer<Uint32>)>>(client, 4)
.asFunction<int Function(Pointer<Void>, Pointer<Uint32>)>();
final pBuf = malloc<Uint32>();
_hr('GetBufferSize', getBufferSizeFn(client, pBuf));
bufferFrames = pBuf.value;
malloc.free(pBuf);
dbgLog('WASAPI-IN bufferFrames=$bufferFrames');

// GetService(IID_IAudioCaptureClient)
final getServiceFn = _vt<NativeFunction<
Int32 Function(Pointer<Void>, Pointer<Guid>,
Pointer<Pointer<Void>>)>>(client, 14)
.asFunction<int Function(Pointer<Void>, Pointer<Guid>,
Pointer<Pointer<Void>>)>();
final iidCc = Guid.alloc(_iidAudioCaptureClient);
final pCc = malloc<Pointer<Void>>();
_hr('GetService', getServiceFn(client, iidCc, pCc));
malloc.free(iidCc);
captureClient = pCc.value;
malloc.free(pCc);
dbgLog('WASAPI-IN GetService(IAudioCaptureClient) ok — init done');

getBufferFn = _vt<NativeFunction<
Int32 Function(
Pointer<Void>,
Pointer<Pointer<Uint8>>,
Pointer<Uint32>,
Pointer<Uint32>,
Pointer<Uint64>,
Pointer<Uint64>)>>(captureClient, 3)
.asFunction<int Function(Pointer<Void>, Pointer<Pointer<Uint8>>,
Pointer<Uint32>, Pointer<Uint32>, Pointer<Uint64>,
Pointer<Uint64>)>();
releaseBufferFn = _vt<NativeFunction<
Int32 Function(Pointer<Void>, Uint32)>>(captureClient, 4)
.asFunction<int Function(Pointer<Void>, int)>();
getNextPacketSizeFn = _vt<NativeFunction<
Int32 Function(Pointer<Void>, Pointer<Uint32>)>>(captureClient, 5)
.asFunction<int Function(Pointer<Void>, Pointer<Uint32>)>();
startFn = _vt<NativeFunction<Int32 Function(Pointer<Void>)>>(client, 10)
.asFunction<int Function(Pointer<Void>)>();
stopFn = _vt<NativeFunction<Int32 Function(Pointer<Void>)>>(client, 11)
.asFunction<int Function(Pointer<Void>)>();
}

void start() {
_hr('Start', startFn(client));
started = true;
}

static const int _kAudclntEDeviceInvalidated = 0x88890004;

void stop() {
if (!started) return;
final hr = stopFn(client);
if (hr < 0 && (hr & 0xFFFFFFFF)!= _kAudclntEDeviceInvalidated) {
_hr('Stop', hr);
}
started = false;
}

double _sample(Pointer<Uint8> data, int idx) {
if (mix.isFloat) return data.cast<Float>()[idx];
if (mix.bitsPerSample == 16) return data.cast<Int16>()[idx] / 32768.0;
return data.cast<Int32>()[idx] / 2147483648.0;
}

/// 把当前所有待读整包排空，转 float 立体声交织写入 [out]
/// （从帧 0 起），至多 [maxFrames] 帧；返回实际写入帧数。
///
/// 整包契约：下一包若装不下剩余空间，留待下轮（绝不部分
/// 读——IAudioCaptureClient 要求 GetBuffer 的帧数整包
/// ReleaseBuffer）。SILENT 包写零（其数据指针内容未定义）。
/// 声道归一：取前两声道（单声道复制到双声道），与渲染侧
/// 的截断语义一致。设备失效等 HRESULT 失败抛 StateError。
int drainInto(Float32List out, int maxFrames) {
var written = 0;
while (written < maxFrames) {
final pSize = malloc<Uint32>();
_hr('GetNextPacketSize', getNextPacketSizeFn(captureClient, pSize));
final packet = pSize.value;
malloc.free(pSize);
if (packet == 0) break;
if (written + packet > maxFrames) break;
final pData = malloc<Pointer<Uint8>>();
final pFrames = malloc<Uint32>();
final pFlags = malloc<Uint32>();
final pDevPos = malloc<Uint64>();
final pQpcPos = malloc<Uint64>();
try {
_hr(
'CaptureGetBuffer',
getBufferFn(
captureClient, pData, pFrames, pFlags, pDevPos, pQpcPos));
final frames = pFrames.value;
final silent = (pFlags.value & _audclntBufferflagsSilent)!= 0;
final data = pData.value;
final ch = mix.channels;
for (var f = 0; f < frames; f++) {
final base = f * ch;
final l = silent? 0.0: _sample(data, base);
final r = silent? 0.0: _sample(data, base + (ch > 1? 1: 0));
out[(written + f) * 2] = l;
out[(written + f) * 2 + 1] = r;
}
_hr('CaptureReleaseBuffer', releaseBufferFn(captureClient, frames));
written += frames;
} finally {
malloc.free(pData);
malloc.free(pFrames);
malloc.free(pFlags);
malloc.free(pDevPos);
malloc.free(pQpcPos);
}
}
return written;
}

static final ThrottledLog _failLog =
ThrottledLog('wasapi-in-fail', head: 5, every: 200);

void _hr(String what, int hr) {
if (hr < 0) {
if (_failLog.shouldLog) {
dbgLog('WASAPI-IN FAIL $what hr=0x${(hr & 0xFFFFFFFF).toRadixString(16)}');
}
throw StateError(
'WASAPI capture $what failed hr=0x${(hr & 0xFFFFFFFF).toRadixString(16)}');
}
}
}
