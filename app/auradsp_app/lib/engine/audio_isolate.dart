/*
 * audio_isolate.dart — 音频引擎 isolate
 *
 * 独占 auradsp_handle 与 WASAPI 输出：源(信号/WAV) → auradsp_process → WASAPI。
 * 主 isolate 仅经消息协议控制（UI 卡顿不影响音频线程——商业形态隔离）。
 *
 * WASAPI：shared 模式轮询推（v1；event-driven 待后续迭代，CPU 开销可忽略）。
 * COM vtable 索引按 x64 ABI 手写（IUnknown 0-2 起）。
 */
import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'auradsp_ffi.dart';
import 'debug_log.dart';

/* ---------------- GUID ---------------- */

final class Guid extends Struct {
  @Uint32()
  external int d1;
  @Uint16()
  external int d2;
  @Uint16()
  external int d3;
  @Array(8)
  external Array<Uint8> d4;

  static Pointer<Guid> alloc(String s) {
    final p = malloc<Guid>();
    final hex = s.replaceAll('-', '');
    p.ref.d1 = int.parse(hex.substring(0, 8), radix: 16);
    p.ref.d2 = int.parse(hex.substring(8, 12), radix: 16);
    p.ref.d3 = int.parse(hex.substring(12, 16), radix: 16);
    for (var i = 0; i < 8; i++) {
      p.ref.d4[i] = int.parse(hex.substring(16 + i * 2, 18 + i * 2), radix: 16);
    }
    return p;
  }
}

const _iidDeviceEnumerator = 'A95664D2-9614-4F35-A746-DE8DB63617E6';
const _clsidDeviceEnumerator = 'BCDE0395-E52F-467C-8E3D-C4579291692E';
const _iidAudioClient = '1CB9AD4C-DBFA-4C32-B178-C2F568A703B2';
const _iidAudioRenderClient = 'F294ACFC-3146-4483-A7BF-ADDCA7C260E2';

// KSDATAFORMAT_SUBTYPE_* 在 WAVEFORMATEXTENSIBLE 内存中的小端字节
// {00000003-0000-0010-8000-00AA00389B71} IEEE_FLOAT
const _subFloatLe = [
  0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00,
  0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71
];
// {00000001-0000-0010-8000-00AA00389B71} PCM
const _subPcmLe = [
  0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00,
  0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71
];

bool _matchLe(Pointer<Uint8> b, int off, List<int> want) {
  for (var i = 0; i < want.length; i++) {
    if (b[off + i] != want[i]) return false;
  }
  return true;
}

/// 把引擎输出（stereo interleaved）按设备混音格式写入 WASAPI 缓冲。
/// 共享模式通常为 float32，但部分驱动为 int32/int16——按位深正确转换。
void writeToDevice(WasapiOut w, Pointer<Float> devOut, int frames, int devCh,
    Float32List src) {
  void put(int i, double v) {
    final c = v.clamp(-1.0, 1.0);
    if (w.mix.isFloat) {
      devOut[i] = c;
    } else if (w.mix.bitsPerSample == 16) {
      devOut.cast<Int16>()[i] = (c * 32767).toInt();
    } else {
      devOut.cast<Int32>()[i] = (c * 2147483647).toInt();
    }
  }

  if (devCh == 2) {
    if (w.mix.isFloat) {
      devOut.asTypedList(frames * 2).setRange(0, frames * 2, src);
      return;
    }
    for (var i = 0; i < frames * 2; i++) {
      put(i, src[i]);
    }
    return;
  }
  for (var f = 0; f < frames; f++) {
    for (var c = 0; c < devCh; c++) {
      put(f * devCh + c, c < 2 ? src[f * 2 + c] : 0.0);
    }
  }
}

Pointer<T> _vt<T extends NativeType>(Pointer<Void> obj, int index) {
  final vtbl = obj.cast<Pointer<Pointer<Void>>>().value;
  return vtbl[index].cast<T>();
}

/* ---------------- WASAPI COM 绑定 ---------------- */

/// WAVEFORMATEX / WAVEFORMATEXTENSIBLE 兼容读取
final class WavFormatEx {
  final int formatTag, channels, sampleRate, bitsPerSample;
  final bool isFloat;
  final Pointer<Uint8> raw;
  WavFormatEx._(this.raw, this.formatTag, this.channels, this.sampleRate,
      this.bitsPerSample, this.isFloat);

  static WavFormatEx read(Pointer<Void> p) {
    final b = p.cast<Uint8>();
    int u16(int o) => b[o] | (b[o + 1] << 8);
    int u32(int o) =>
        b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);
    final tag = u16(0);
    final ch = u16(2);
    final rate = u32(4);
    final bits = u16(14);
    final cbSize = u16(16);
    var isFloat = tag == 3;
    if (tag == 0xFFFE && cbSize >= 22) {
      // EXTENSIBLE: SubFormat GUID @ 偏移 24；Data1/2/3 在内存为小端，按小端字节比较
      if (_matchLe(b, 24, _subFloatLe)) {
        isFloat = true;
      } else if (_matchLe(b, 24, _subPcmLe)) {
        isFloat = false;
      }
    }
    return WavFormatEx._(b, tag, ch, rate, bits, isFloat);
  }
}

/// WASAPI 输出（COM vtable 直调，全部显式 Dart 签名）
final class WasapiOut {
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

  // 渲染热路径 vtable 方法（init 末段绑定）
  late final int Function(Pointer<Void>, Pointer<Uint32>) getCurrentPadding;
  late final int Function(Pointer<Void>, int, Pointer<Pointer<Uint8>>)
      getBufferFn;
  late final int Function(Pointer<Void>, int, int) releaseBufferFn;
  late final int Function(Pointer<Void>) startFn, stopFn;

  late final Pointer<Void> enumerator, device, client, renderClient;
  late final WavFormatEx mix;
  late final int bufferFrames;

  bool started = false;

  void init() {
    dbgLog('WASAPI init: begin');
    final hr = coInitializeEx(0, 0x0); // COINIT_MULTITHREADED
    dbgLog('CoInitializeEx hr=$hr');
    if (hr < 0 && hr != -2147417850) {
      // RPC_E_CHANGED_MODE 可容忍
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

    // ---- 按时序交错绑定/调用（vtable 绑定依赖前一步产出的对象指针） ----

    // IMMDeviceEnumerator::GetDefaultAudioEndpoint(eRender=0, eMultimedia=1)
    final getDefaultAudioEndpoint = _vt<NativeFunction<
            Int32 Function(Pointer<Void>, Int32, Int32,
                Pointer<Pointer<Void>>)>>(enumerator, 4)
        .asFunction<int Function(Pointer<Void>, int, int,
            Pointer<Pointer<Void>>)>();
    final pDev = malloc<Pointer<Void>>();
    _hr('GetDefaultAudioEndpoint',
        getDefaultAudioEndpoint(enumerator, 0, 1, pDev));
    device = pDev.value;
    malloc.free(pDev);
    dbgLog('GetDefaultAudioEndpoint ok');

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
    dbgLog('Activate(IAudioClient) ok');

    // IAudioClient::GetMixFormat
    final getMixFormatFn = _vt<NativeFunction<
            Int32 Function(Pointer<Void>, Pointer<Pointer<Void>>)>>(client, 8)
        .asFunction<int Function(Pointer<Void>, Pointer<Pointer<Void>>)>();
    final pFmt = malloc<Pointer<Void>>();
    _hr('GetMixFormat', getMixFormatFn(client, pFmt));
    mix = WavFormatEx.read(pFmt.value);
    dbgLog('mix: tag=0x${mix.formatTag.toRadixString(16)} ch=${mix.channels} '
        'rate=${mix.sampleRate} bits=${mix.bitsPerSample} float=${mix.isFloat}');

    // Initialize(shared=0, flags=0, 20ms, periodicity=0, mixFormat, NULL)
    final initializeFn = _vt<NativeFunction<
            Int32 Function(Pointer<Void>, Int32, Uint32, Int64, Int64,
                Pointer<Void>, Pointer<Void>)>>(client, 3)
        .asFunction<int Function(Pointer<Void>, int, int, int, int,
            Pointer<Void>, Pointer<Void>)>();
    final hrInit =
        initializeFn(client, 0, 0, 200000, 0, pFmt.value, nullptr);
    dbgLog('Initialize hr=0x${(hrInit & 0xFFFFFFFF).toRadixString(16)}');
    _hr('Initialize', hrInit);
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
    dbgLog('bufferFrames=$bufferFrames');

    // GetService(IID_IAudioRenderClient)
    final getServiceFn = _vt<NativeFunction<
            Int32 Function(Pointer<Void>, Pointer<Guid>,
                Pointer<Pointer<Void>>)>>(client, 14)
        .asFunction<int Function(Pointer<Void>, Pointer<Guid>,
            Pointer<Pointer<Void>>)>();
    final iidRc = Guid.alloc(_iidAudioRenderClient);
    final pRc = malloc<Pointer<Void>>();
    _hr('GetService', getServiceFn(client, iidRc, pRc));
    malloc.free(iidRc);
    renderClient = pRc.value;
    malloc.free(pRc);
    dbgLog('GetService(IAudioRenderClient) ok — init done');

    // 渲染热路径方法：绑定到字段（client/renderClient 此时均已就绪）
    getCurrentPadding = _vt<NativeFunction<
            Int32 Function(Pointer<Void>, Pointer<Uint32>)>>(client, 6)
        .asFunction<int Function(Pointer<Void>, Pointer<Uint32>)>();
    getBufferFn = _vt<NativeFunction<
            Int32 Function(Pointer<Void>, Int32,
                Pointer<Pointer<Uint8>>)>>(renderClient, 3)
        .asFunction<
            int Function(Pointer<Void>, int, Pointer<Pointer<Uint8>>)>();
    releaseBufferFn = _vt<NativeFunction<
            Int32 Function(Pointer<Void>, Int32, Uint32)>>(renderClient, 4)
        .asFunction<int Function(Pointer<Void>, int, int)>();
    startFn = _vt<NativeFunction<Int32 Function(Pointer<Void>)>>(client, 10)
        .asFunction<int Function(Pointer<Void>)>();
    stopFn = _vt<NativeFunction<Int32 Function(Pointer<Void>)>>(client, 11)
        .asFunction<int Function(Pointer<Void>)>();
  }

  int getCurrentPaddingNow() {
    final p = malloc<Uint32>();
    _hr('GetCurrentPadding', getCurrentPadding(client, p));
    final v = p.value;
    malloc.free(p);
    return v;
  }

  Pointer<Float> getBuffer(int frames) {
    final p = malloc<Pointer<Uint8>>();
    // 注意：IAudioRenderClient 的方法必须用 renderClient 作 this
    _hr('GetBuffer', getBufferFn(renderClient, frames, p));
    final data = p.value.cast<Float>();
    malloc.free(p);
    return data;
  }

  void releaseBuffer(int frames) {
    _hr('ReleaseBuffer', releaseBufferFn(renderClient, frames, 0));
  }

  void start() {
    _hr('Start', startFn(client));
    started = true;
  }

  void stop() {
    if (started) {
      stopFn(client);
      started = false;
    }
  }

  void _hr(String what, int hr) {
    if (hr < 0) {
      dbgLog('WASAPI FAIL $what hr=0x${(hr & 0xFFFFFFFF).toRadixString(16)}');
      throw StateError(
          'WASAPI $what failed hr=0x${(hr & 0xFFFFFFFF).toRadixString(16)}');
    }
  }
}

/* ---------------- WAV 解码 ---------------- */

final class DecodedWav {
  final Float32List data; // stereo interleaved
  final int sampleRate;
  DecodedWav(this.data, this.sampleRate);
}

DecodedWav? decodeWavFile(String path) {
  final bytes = File(path).readAsBytesSync();
  final bd = ByteData.sublistView(bytes);
  if (bytes.length < 44) return null;
  if (bytes[0] != 0x52 || bytes[1] != 0x49) return null; // "RI"
  var off = 12; // 跳过 RIFF size + WAVE
  int fmtTag = 0, ch = 0, rate = 0, bits = 0;
  int dataOff = -1, dataLen = 0;
  while (off + 8 <= bytes.length) {
    final id = String.fromCharCodes(bytes.sublist(off, off + 4));
    final sz = bd.getUint32(off + 4, Endian.little);
    if (id == 'fmt ') {
      fmtTag = bd.getUint16(off + 8, Endian.little);
      ch = bd.getUint16(off + 10, Endian.little);
      rate = bd.getUint32(off + 12, Endian.little);
      bits = bd.getUint16(off + 8 + 14, Endian.little);
      if (fmtTag == 0xFFFE && sz >= 40) {
        // SubFormat 首个 DWORD 即 subtype 序号（PCM=1/FLOAT=3）
        fmtTag = bd.getUint32(off + 8 + 24, Endian.little);
      }
    } else if (id == 'data') {
      dataOff = off + 8;
      dataLen = math.min(sz, bytes.length - dataOff);
    }
    off += 8 + sz + (sz & 1); // RIFF chunk 对齐 2
  }
  if (dataOff < 0 || ch < 1 || rate < 8000) return null;

  final frames = dataLen ~/ (bits ~/ 8 * ch);
  final out = Float32List(frames * 2);
  const scale = 1.0 / 2147483648.0;
  for (var f = 0; f < frames; f++) {
    for (var c = 0; c < 2; c++) {
      final srcCh = c % ch;
      final base = dataOff + f * ch * (bits ~/ 8) + srcCh * (bits ~/ 8);
      double v;
      switch (bits) {
        case 16:
          v = bd.getInt16(base, Endian.little) / 32768.0;
          break;
        case 24:
          // 符号扩展 24 位 → [-1,1)
          final s = ((bytes[base + 2] << 24) |
                  (bytes[base + 1] << 16) |
                  (bytes[base] << 8)) >>
              8;
          v = s / 8388608.0;
          break;
        case 32:
          v = fmtTag == 3
              ? bd.getFloat32(base, Endian.little)
              : bd.getInt32(base, Endian.little) * scale;
          break;
        default:
          return null;
      }
      out[f * 2 + c] = v.isFinite ? v.clamp(-1.0, 1.0) : 0.0;
    }
  }
  return DecodedWav(out, rate);
}

/* ---------------- 信号源 ---------------- */

abstract class Source {
  /// 填充 frames×2 交织帧
  void fill(Float32List out, int frames, int deviceRate);
}

class ToneSource implements Source {
  final double freq;
  double _phase = 0;
  ToneSource(this.freq);

  @override
  void fill(Float32List out, int frames, int deviceRate) {
    final d = 2 * math.pi * freq / deviceRate;
    for (var i = 0; i < frames; i++) {
      final v = math.sin(_phase) * 0.3;
      _phase += d;
      if (_phase > 2 * math.pi) _phase -= 2 * math.pi;
      out[i * 2] = v;
      out[i * 2 + 1] = v;
    }
  }
}

class PinkSource implements Source {
  double b0 = 0, b1 = 0, b2 = 0, b3 = 0, b4 = 0, b5 = 0, b6 = 0;
  final math.Random _rng = math.Random();

  @override
  void fill(Float32List out, int frames, int deviceRate) {
    for (var i = 0; i < frames; i++) {
      final w = _rng.nextDouble() * 2 - 1;
      b0 = 0.99886 * b0 + w * 0.0555179;
      b1 = 0.99332 * b1 + w * 0.0750759;
      b2 = 0.96900 * b2 + w * 0.1538520;
      b3 = 0.86650 * b3 + w * 0.3104856;
      b4 = 0.55000 * b4 + w * 0.5329522;
      b5 = -0.7616 * b5 - w * 0.0168980;
      final v = (b0 + b1 + b2 + b3 + b4 + b5 + b6 + w * 0.5362) * 0.05;
      b6 = w * 0.115926;
      out[i * 2] = v;
      out[i * 2 + 1] = v;
    }
  }
}

class FileSource implements Source {
  final Float32List data;
  final int srcRate;
  double _pos = 0;
  bool loop = true;
  FileSource(this.data, this.srcRate);

  @override
  void fill(Float32List out, int frames, int deviceRate) {
    final ratio = srcRate / deviceRate;
    final total = data.length ~/ 2;
    for (var i = 0; i < frames; i++) {
      if (_pos >= total - 1) {
        if (!loop) {
          for (var k = i; k < frames; k++) {
            out[k * 2] = 0;
            out[k * 2 + 1] = 0;
          }
          return;
        }
        _pos = 0;
      }
      final i0 = _pos.floor();
      final frac = _pos - i0;
      final i1 = math.min(i0 + 1, total - 1);
      out[i * 2] = data[i0 * 2] * (1 - frac) + data[i1 * 2] * frac;
      out[i * 2 + 1] = data[i0 * 2 + 1] * (1 - frac) + data[i1 * 2 + 1] * frac;
      _pos += ratio;
    }
  }
}

/* ---------------- 消息协议 ---------------- */

const vizIntervalMs = 33;

void audioIsolateMain(Map<String, dynamic> cfg) {
  final toMain = cfg['toMain'] as SendPort;
  final fromMain = ReceivePort();

  void send(Map<String, dynamic> m) => toMain.send(m);

  AuraDspLib? lib;
  Pointer<Void>? handle;
  WasapiOut? wasapi;
  Source? source;
  bool bypass = false;
  bool running = true;
  int? lastViz;
  var vizCount = 0;
  int? lastSentState;
  double? lastSentLatency;

  fromMain.listen((raw) {
    final m = raw as Map;
    dbgLog('cmd: ${m['cmd']} ${m['kind'] ?? m['id'] ?? ''} ${m['value'] ?? ''}');
    try {
      switch (m['cmd'] as String) {
        case 'setParam':
          final t0 = DateTime.now();
          final rc = AuraDspLib.setValue(lib!, handle!, m['id'] as String,
              isFloat: m['isFloat'] as bool, value: (m['value'] as num).toDouble());
          final tookMs = DateTime.now().difference(t0).inMilliseconds;
          // 关键证据：引擎应用耗时。旧实现全量重建混响/EQ 时这里是几十~几百 ms。
          dbgLog('setParam ${m['id']}=${m['value']} rc=$rc took=${tookMs}ms');
          String? err;
          if (rc != Status.ok) {
            final e = lib.lastError(handle);
            err = e == nullptr ? null : e.toDartString();
          }
          send({'evt': 'paramResult', 'id': m['id'], 'rc': rc, 'msg': err});
          if (rc == Status.ok) {
            // 仅在状态/延迟真的变化时才回推，避免拖滑块时 UI 整页双倍重建
            final st = lib.getState(handle);
            final lat = lib.getLatencyMs(handle);
            if (st != lastSentState || lat != lastSentLatency) {
              lastSentState = st;
              lastSentLatency = lat;
              send({'evt': 'state', 'state': st, 'latencyMs': lat});
            }
          }
          break;
        case 'getParams':
          {
            final p = lib!;
            final h = handle!;
            int? rdInt(Pointer<Uint8> idp) {
              final vp = malloc<Int32>();
              try {
                final rc = p.getParam(h, idp, vp.cast(), 4);
                return rc == 0 ? vp.value : null;
              } finally {
                malloc.free(vp);
              }
            }

            double? rdFloat(Pointer<Uint8> idp) {
              final vp = malloc<Float>();
              try {
                final rc = p.getParam(h, idp, vp.cast(), 4);
                return rc == 0 ? vp.value : null;
              } finally {
                malloc.free(vp);
              }
            }

            Pointer<Uint8> idp(String s) => AuraDspLib.idBytes(s);
            final iBass = idp('bass.enable'), iBassG = idp('bass.gain');
            final iRev = idp('reverb.preset'), iMix = idp('stereo.mix');
            final iEq = idp('eq.enable'), iPost = idp('post.gain');
            final iLim = idp('limiter.enable'), iMode = idp('mode.latency');
            final iCh = idp('channels.mode');
            final iLpEn = idp('liveprog.enable'), iLpSt = idp('liveprog.status');
            final iCvEn = idp('convolver.enable'), iCvRd = idp('convolver.ready');
            final iCvF = idp('convolver.ir.frames'), iCvCh = idp('convolver.ir.channels');
            final iCvSr = idp('convolver.ir.srcRate'), iCvPk = idp('convolver.ir.peak');
            final iCvSpec = idp('convolver.ir.spectrum');
            final iTb = idp('tube.enable'), iXf = idp('crossfeed.enable');
            final iSbU = idp('stereo.bandUsed');
            final iCvM = idp('convolver.mix');
            final iDdE = idp('ddc.enable'), iDdR = idp('ddc.ready');
            final iShE = idp('shelf.enable'), iShF = idp('shelf.freq'), iShG = idp('shelf.gain');
            final iFvE = idp('freeverb.enable'), iFvD = idp('freeverb.decay');
            final iFvDa = idp('freeverb.damp'), iFvW = idp('freeverb.wet'), iFvDr = idp('freeverb.dry');
            List<List<double>>? readIrSpectrum(int ch) {
              if (ch <= 0 || ch > 8) return null;
              final count = ch * 32;
              final ptr = malloc<Float>(count);
              try {
                final rc = p.getParam(h, iCvSpec, ptr.cast(), count * 4);
                if (rc != 0) return null;
                final res = <List<double>>[];
                for (var c = 0; c < ch; c++) {
                  final list = <double>[];
                  for (var b = 0; b < 32; b++) {
                    list.add(ptr[c * 32 + b]);
                  }
                  res.add(list);
                }
                return res;
              } finally {
                malloc.free(ptr);
              }
            }
            try {
              final cvReady = rdInt(iCvRd) ?? 0;
              final cvChannels = rdInt(iCvCh) ?? 0;
              send({
                'evt': 'params',
                'bassEnable': rdInt(iBass) ?? 0,
                'bassGain': rdFloat(iBassG) ?? 0.0,
                'reverbPreset': rdInt(iRev) ?? -1,
                'stereoMix': rdFloat(iMix) ?? 0.5,
                'eqEnable': rdInt(iEq) ?? 0,
                'postGain': rdFloat(iPost) ?? 0.0,
                'limiterEnable': rdInt(iLim) ?? 1,
                'latencyMode': rdInt(iMode) ?? 1,
                'channelsMode': rdInt(iCh) ?? 0,
                'lpEnable': rdInt(iLpEn) ?? 0,
                'lpStatus': rdInt(iLpSt) ?? 0,
                'convEnable': rdInt(iCvEn) ?? 0,
                'convReady': cvReady,
                'convFrames': rdInt(iCvF) ?? 0,
                'convChannels': cvChannels,
                'convSrcRate': rdInt(iCvSr) ?? 0,
                'convPeak': rdFloat(iCvPk) ?? 0.0,
                'convSpectrum': (cvReady == 1 && cvChannels > 0)
                    ? readIrSpectrum(cvChannels)
                    : null,
                'tubeEnable': rdInt(iTb) ?? 0,
                'xfeedEnable': rdInt(iXf) ?? 0,
                'stereoBandUsed': rdInt(iSbU) ?? 0,
                'convMix': rdFloat(iCvM) ?? 1.0,
                'ddcEnable': rdInt(iDdE) ?? 0,
                'ddcReady': rdInt(iDdR) ?? 0,
                'shelfEnable': rdInt(iShE) ?? 0,
                'shelfFreq': rdFloat(iShF) ?? 100.0,
                'shelfGain': rdFloat(iShG) ?? 0.0,
                'fvEnable': rdInt(iFvE) ?? 0,
                'fvDecay': rdFloat(iFvD) ?? 0.5,
                'fvDamp': rdFloat(iFvDa) ?? 0.5,
                'fvWet': rdFloat(iFvW) ?? 0.3,
                'fvDry': rdFloat(iFvDr) ?? 1.0,
              });
            } finally {
              for (final q in [iBass, iBassG, iRev, iMix, iEq, iPost, iLim, iMode, iCh, iLpEn, iLpSt, iCvEn, iCvRd, iCvF, iCvCh, iCvSr, iCvPk, iCvSpec, iTb, iXf, iSbU, iShE, iShF, iShG, iFvE, iFvD, iFvDa, iFvW, iFvDr, iCvM, iDdE, iDdR]) {
                malloc.free(q);
              }
            }
            break;
          }
        case 'setParamStr':
          {
            // 字符串参数（v1.1：liveprog.code）。rc!=0 时 lastError 带编译错误文案。
            final t0 = DateTime.now();
            final rc = AuraDspLib.setString(
                lib!, handle!, m['id'] as String, m['text'] as String);
            final tookMs = DateTime.now().difference(t0).inMilliseconds;
            dbgLog('setParamStr ${m['id']} (${(m['text'] as String).length}B) '
                'rc=$rc took=${tookMs}ms');
            String? err;
            if (rc != Status.ok) {
              final e = lib.lastError(handle);
              err = e == nullptr ? null : e.toDartString();
            }
            send({'evt': 'paramResult', 'id': m['id'], 'rc': rc, 'msg': err});
            if (rc == Status.ok && m['id'] == 'liveprog.code') {
              final st = AuraDspLib.getInt(lib, handle, 'liveprog.status');
              send({'evt': 'liveprog', 'status': st});
            }
            break;
          }
        case 'source':
          final kind = m['kind'] as String;
          switch (kind) {
            case 'stop':
              source = null;
              break;
            case 'tone':
              source = ToneSource(440);
              break;
            case 'pink':
              source = PinkSource();
              break;
            case 'file':
              final w = decodeWavFile(m['path'] as String);
              if (w == null) {
                send({'evt': 'error', 'msg': 'WAV 解析失败（仅支持 PCM 16/24/32 与 float32）'});
              } else {
                source = FileSource(w.data, w.sampleRate);
              }
              break;
          }
          send({'evt': 'playing', 'playing': source != null});
          break;
        case 'bypass':
          bypass = m['value'] as bool;
          break;
        case 'shutdown':
          running = false;
          break;
      }
    } catch (e) {
      send({'evt': 'error', 'msg': e.toString()});
    }
  });
  send({'evt': 'isoReady', 'port': fromMain.sendPort});

  /* ---- 引擎 + WASAPI 初始化 ---- */
  try {
    lib = AuraDspLib.load();
    dbgLog('engine dll loaded');
    wasapi = WasapiOut()..init();
    handle = lib.create(wasapi.mix.sampleRate.toDouble(), 2048);
    dbgLog('auradsp_create rate=${wasapi.mix.sampleRate} '
        'handle=${handle == nullptr ? "NULL" : "ok"}');
    if (handle == nullptr) throw StateError('auradsp_create returned null');
    wasapi.start();
    dbgLog('WASAPI started, latency=${lib.getLatencyMs(handle)}ms');
    lastSentState = lib.getState(handle);
    lastSentLatency = lib.getLatencyMs(handle);
    send({
      'evt': 'ready',
      'abi': lib.abi(),
      'version': lib.version().toDartString(),
      'deviceRate': wasapi.mix.sampleRate,
      'deviceCh': wasapi.mix.channels,
      'bufferFrames': wasapi.bufferFrames,
      'latencyMs': lib.getLatencyMs(handle),
    });
  } catch (e) {
    send({'evt': 'fatal', 'msg': e.toString()});
    return;
  }

  /* ---- 渲染循环（shared 轮询推） ---- */
  const maxBlock = 2048; // 必须 ≤ auradsp_create 的 max_block_frames 契约
  final srcPtr = malloc<Float>(maxBlock * 2);
  final srcBuf = srcPtr.asTypedList(maxBlock * 2);
  final outPtrEng = malloc<Float>(maxBlock * 2);
  final engOut = outPtrEng.asTypedList(maxBlock * 2);
  String? lastPumpErr;
  var lastPumpErrAt = 0;
  var pumpRounds = 0;
  var procRounds = 0;
  Future<void> pump() async {
    dbgLog('pump loop start');
    while (running) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      pumpRounds++;
      try {
        final w = wasapi!;
        final padding = w.getCurrentPaddingNow();
        final avail = w.bufferFrames - padding;
        if (avail <= 0) continue;
        final frames = math.min(avail, maxBlock);
        if (pumpRounds <= 30 || pumpRounds % 2000 == 0) {
          dbgLog('pump#$pumpRounds padding=$padding avail=$avail frames=$frames '
              'src=${source.runtimeType} bypass=$bypass');
        }

        if (source != null) {
          source!.fill(srcBuf, frames, w.mix.sampleRate);
          if (frames > maxBlock) {
            dbgLog('GUARD: frames=$frames > maxBlock=$maxBlock!');
          }
          final devCh = w.mix.channels;
          if (!bypass) {
            procRounds++;
            if (procRounds == 1) {
              dbgLog('first process: in0=${srcBuf[0]} in1=${srcBuf[1]}');
            }
            lib!.process(handle!, srcPtr, outPtrEng, frames);
            if (procRounds == 1) {
              dbgLog('first process done: out0=${engOut[0]} out1=${engOut[1]}');
            }
          }
          final devOut = w.getBuffer(frames);
          writeToDevice(w, devOut, frames, devCh, bypass ? srcBuf : engOut);
          w.releaseBuffer(frames);

          // 可视化节流拉取：引擎 ~10ms 产一帧，UI 33ms 拉一次，
          // 一次最多读 8 帧并只取最新（避免队列积压导致画面滞后）
          final now = DateTime.now().millisecondsSinceEpoch;
          if (lastViz == null || now - lastViz! >= vizIntervalMs) {
            lastViz = now;
            final vf = malloc<VizFrame>(8);
            try {
              final n = lib!.vizRead(handle!, vf, 8);
              if (n > 0) {
                final fr = (vf + (n - 1)).ref;
                vizCount++;
                if (vizCount <= 5 || vizCount % 100 == 0) {
                  final sp = fr.spectrumToList();
                  dbgLog('viz#$vizCount n=$n seq=${fr.seq} '
                      'max=${sp.reduce(math.max).toStringAsFixed(3)} '
                      'l=${fr.levelLDbfs.toStringAsFixed(1)} '
                      'r=${fr.levelRDbfs.toStringAsFixed(1)}');
                }
                send({
                  'evt': 'viz',
                  'spectrum': fr.spectrumToList(),
                  'l': fr.levelLDbfs,
                  'r': fr.levelRDbfs,
                  'ts': fr.timestampMs,
                  'seq': fr.seq,
                });
              }
            } finally {
              malloc.free(vf);
            }
          }
        }
      } catch (e, st) {
        // 错误节流：同一消息 3s 内只上报一次，防 UI 事件洪泛（5ms 一轮的循环）
        final now = DateTime.now().millisecondsSinceEpoch;
        final msg = e.toString();
        dbgLog('PUMP ERROR: $msg\n$st');
        if (msg != lastPumpErr || now - lastPumpErrAt > 3000) {
          lastPumpErr = msg;
          lastPumpErrAt = now;
          send({'evt': 'error', 'msg': msg});
        }
      }
    }
    // 收尾
    try {
      wasapi?.stop();
      if (handle != null) lib?.destroy(handle);
    } catch (_) {}
  }

  unawaited(pump());
}
