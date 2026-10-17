// part of audio_isolate.dart —— P1 按区拆分，纯搬运零改行。
part of 'audio_isolate.dart';
bool _matchLe(Pointer<Uint8> b, int off, List<int> want) {
  for (var i = 0; i < want.length; i++) {
    if (b[off + i] != want[i]) return false;
  }
  return true;
}

/// 把引擎输出（stereo interleaved）按设备混音格式写入 WASAPI 缓冲。
/// 共享模式通常为 float32，但部分驱动为 int32/int16——按位深正确转换。
/// Phase 2 直通：src 可为 Nch 交织（srcCh），超出设备声道截断、不足补零。
void writeToDevice(WasapiOut w, Pointer<Float> devOut, int frames, int devCh,
    Float32List src, {int srcCh = 2}) {
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

  if (devCh == 2 && srcCh == 2) {
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
      put(f * devCh + c, c < srcCh ? src[f * srcCh + c] : 0.0);
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
    return WavFormatEx._(b, tag, ch, rate, bits, isFloat).._cbSize = cbSize;
  }

  /// 结构总字节数（18 字节固定头 + cbSize 扩展），用于整块复制后改采样率。
  int get totalBytes => 18 + _cbSize;
  int _cbSize = 0;

  /// 复制一份，把 nSamplesPerSec（偏移 4）改成 [rate]，并按新速率重算
  /// nAvgBytesPerSec（偏移 8 = rate × nBlockAlign）。
  ///
  /// 这是请求非设备原生采样率的安全做法：保留 formatTag / channels /
  /// bitsPerSample / channel mask / SubFormat GUID，只改速率相关两处，
  /// 避免手搓 WAVEFORMATEXTENSIBLE 触发 AUDCLNT_E_INVALID_FORMAT。
  /// 注意：只改 nSamplesPerSec 而漏改 nAvgBytesPerSec 会让结构自相矛盾，
  /// WASAPI 直接 E_INVALIDARG（0x80070057）——正是之前 44100 被拒的原因。
  /// shared 模式下 Windows 会自行重采样到设备原生率。
  Pointer<Uint8> cloneWithRate(int rate) {
    final out = malloc<Uint8>(totalBytes);
    for (var i = 0; i < totalBytes; i++) {
      out[i] = raw[i];
    }
    final b = out;
    b[4] = rate & 0xFF;
    b[5] = (rate >> 8) & 0xFF;
    b[6] = (rate >> 16) & 0xFF;
    b[7] = (rate >> 24) & 0xFF;
    final blockAlign = b[12] | (b[13] << 8);
    final avg = rate * blockAlign;
    b[8] = avg & 0xFF;
    b[9] = (avg >> 8) & 0xFF;
    b[10] = (avg >> 16) & 0xFF;
    b[11] = (avg >> 24) & 0xFF;
    return out;
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

  /// 本次 init 选中的端点实名（排障用；_hr 失败时拼进异常，红屏直接见名）。
  String endpointName = '';

  void init({int? requestedSampleRate}) {
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

    // 端点实名（排障用：再报 DEVICE_INVALIDATED 时，日志直接写明是哪块设备，
    // 不用猜默认端点是谁）。PKEY_Device_FriendlyName =
    // {A45C254E-DF1C-4EFD-8020-67D146A850E0},14。best-effort，失败不拦初始化。
    try {
      final openStore = _vt<
              NativeFunction<
                  Int32 Function(
                      Pointer<Void>, Int32, Pointer<Pointer<Void>>)>>(
              device, 4)
          .asFunction<
              int Function(Pointer<Void>, int, Pointer<Pointer<Void>>)>();
      final pStore = malloc<Pointer<Void>>();
      try {
        if (openStore(device, 0, pStore) == 0) {
          final store = pStore.value;
          final getValue = _vt<
                  NativeFunction<
                      Int32 Function(
                          Pointer<Void>, Pointer<Void>, Pointer<Void>)>>(
                  store, 5)
              .asFunction<
                  int Function(
                      Pointer<Void>, Pointer<Void>, Pointer<Void>)>();
          final key = malloc<Uint8>(20);
          final prop = malloc<Uint8>(16);
          try {
            final g =
                Guid.alloc('A45C254E-DF1C-4EFD-8020-67D146A850E0');
            try {
              final gp = g.cast<Uint8>();
              for (var i = 0; i < 16; i++) {
                key[i] = gp[i];
              }
              key[16] = 14;
              key[17] = 0;
              key[18] = 0;
              key[19] = 0;
              for (var i = 0; i < 16; i++) {
                prop[i] = 0;
              }
              if (getValue(store, key.cast(), prop.cast()) == 0) {
                final vt = prop[0] | (prop[1] << 8);
                if (vt == 31) {
                  // VT_LPWSTR：指针在偏移 8（+8 个 Uint8 步进；之前误读偏移 0，
                  // 把 vt 当指针解引用导致启动即 native 崩溃——Dart 拦不住）。
                  final wstr = (prop + 8).cast<Pointer<Utf16>>().value;
                  if (wstr.address != 0) {
                    final name = wstr.toDartString();
                    endpointName = name;
                    dbgLog('endpoint: $name');
                    coTaskMemFree(wstr.cast());
                  }
                }
              }
            } finally {
              malloc.free(g);
            }
          } finally {
            malloc.free(key);
            malloc.free(prop);
          }
          _vt<NativeFunction<Void Function(Pointer<Void>)>>(store, 2)
              .asFunction<void Function(Pointer<Void>)>()(store);
        }
      } finally {
        malloc.free(pStore);
      }
    } catch (_) {
      // 实名失败不影响初始化（老驱动可能缺属性页）
    }

    // 端点状态（1=ACTIVE 2=DISABLED 4=NOTPRESENT 8=UNPLUGGED）：幽灵设备
    // 在这里现形（PnP 列表里 OK 不代表能用）。
    try {
      final getState = _vt<
              NativeFunction<Int32 Function(Pointer<Void>, Pointer<Uint32>)>>(
              device, 6)
          .asFunction<int Function(Pointer<Void>, Pointer<Uint32>)>();
      final pSt = malloc<Uint32>();
      try {
        if (getState(device, pSt) == 0) {
          dbgLog('endpoint state=${pSt.value}');
        }
      } finally {
        malloc.free(pSt);
      }
    } catch (_) {}

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
    final deviceMix = WavFormatEx.read(pFmt.value);
    dbgLog('mix: tag=0x${deviceMix.formatTag.toRadixString(16)} '
        'ch=${deviceMix.channels} rate=${deviceMix.sampleRate} '
        'bits=${deviceMix.bitsPerSample} float=${deviceMix.isFloat}');

    // Initialize(shared=0, flags=0, 20ms, periodicity=0, mixFormat, NULL)
    final initializeFn = _vt<NativeFunction<
            Int32 Function(Pointer<Void>, Int32, Uint32, Int64, Int64,
                Pointer<Void>, Pointer<Void>)>>(client, 3)
        .asFunction<int Function(Pointer<Void>, int, int, int, int,
            Pointer<Void>, Pointer<Void>)>();

    // 若 config.sampleRate 指定了与设备原生不同的速率，就按该速率请求 shared
    // 格式（config.sampleRate 此前从不被消费，引擎实际一直跟着设备走）。
    // 这不只是"配置生效"：引擎的 Freeverb 梳状滤波长度按 fs 标定，
    // 在 44.1k/96k 设备上混响音调与延迟都会偏。
    Pointer<Void> fmtPtr = pFmt.value;
    Pointer<Uint8>? customFmt;
    var requestedRateApplied = false;
    if (requestedSampleRate != null &&
        requestedSampleRate > 0 &&
        requestedSampleRate != deviceMix.sampleRate) {
      customFmt = deviceMix.cloneWithRate(requestedSampleRate);
      fmtPtr = customFmt.cast<Void>();
      requestedRateApplied = true;
    }

    var hrInit = initializeFn(client, 0, 0, 200000, 0, fmtPtr, nullptr);
    if (hrInit != 0 && requestedRateApplied) {
      // 设备不接受该格式（部分声卡/驱动会拒），退回设备原生混音格式
      dbgLog('Initialize(rate=$requestedSampleRate) rejected '
          'hr=0x${(hrInit & 0xFFFFFFFF).toRadixString(16)} — fallback to device mix');
      final rejected = customFmt!;
      customFmt = null;
      requestedRateApplied = false;
      fmtPtr = pFmt.value;
      hrInit = initializeFn(client, 0, 0, 200000, 0, fmtPtr, nullptr);
      malloc.free(rejected);
    }
    // mix 必须反映**实际协商到的**格式，后续 writeToDevice 的位深换算依赖它
    if (requestedRateApplied) {
      mix = WavFormatEx.read(customFmt!.cast<Void>());
      dbgLog('negotiated format: rate=${mix.sampleRate} '
          '(device native ${deviceMix.sampleRate})');
    } else {
      mix = deviceMix;
    }
    dbgLog('Initialize hr=0x${(hrInit & 0xFFFFFFFF).toRadixString(16)}');
    _hr('Initialize', hrInit);
    if (customFmt != null) malloc.free(customFmt);
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
      throw StateError('WASAPI $what failed hr=0x${(hr & 0xFFFFFFFF).toRadixString(16)}'
          '${endpointName.isNotEmpty ? " (endpoint: $endpointName)" : ""}');
    }
  }
}
