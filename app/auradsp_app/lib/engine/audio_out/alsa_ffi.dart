// alsa_ffi.dart —— libasound FFI 单源定义（二期 ALSA 专家模式）。
//
// audio_out_alsa.dart 与 audio_in_alsa.dart 共用（同 pulse_simple_ffi.dart
// 的单源先例，防两侧镜像漂移）。只声明两侧都需要的核心面：PCM 打开/
// 关闭、hw_params 协商、prepare/drop/drain、读写、延迟与状态、错误文案、
// 设备枚举（device_name_hint）。
//
// 指针层级备忘（A0 探针实测）：
//   - snd_pcm_t 在 FFI 里是 Pointer<Void>（不透明句柄）；
//   - hw_params 是固定大小的不透明块：用 snd_pcm_hw_params_sizeof()
//     取字节数再 malloc，禁止假设结构体布局；
//   - snd_device_name_free_hint 取的是枚举返回的数组指针本身
//     （void**），且符号名是 free_hint（不是 hint_free）。
import '../../core/error_sink.dart';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import '../native_library_loader.dart';

/* ---- PCM 流方向 ---- */
const int alsaStreamPlayback = 0;
const int alsaStreamCapture = 1;

/* ---- 格式与访问模式（snd_pcm_format_t / snd_pcm_access_t） ---- */
const int alsaFormatS16Le = 2;
const int alsaFormatFloatLe = 14;
const int alsaAccessRwInterleaved = 3;

/* ---- PCM 状态（snd_pcm_state_t） ---- */
const int alsaStatePrepared = 2;
const int alsaStateRunning = 3;
const int alsaStateXrun = 4;
const int alsaStateSuspended = 7;

/// -EPIPE：写入过慢导致欠载（XRUN），prepare 后可续写。
const int alsaErrPipe = -32;

/// 读写循环的连续无进展上限：XRUN 恢复（prepare）成功但设备仍
/// 恒 -EPIPE、或单次 IO 返回 0 时计一次；超过上限即抛错走上层
/// 降级，杜绝设备异常时泵线程在单次调用内无限空转（打磨一期）。
const int alsaMaxStalledRetries = 10;

/// 采集协商率与泵运行率是否一致（纯逻辑，可单测）：ALSA 无服务端
/// 重采样（不像 PulseAudio），采集率与输出率不一致时泵按错率
/// 消费样本会变速变调，必须在接管线时拦下。pumpRate<=0 表示
/// 输出尚未初始化、无法判断，按可用处理（调用方另有兜底）。
bool alsaRateMatches({required int negotiated, required int pumpRate}) =>
    pumpRate <= 0 || negotiated == pumpRate;

/* ---- 函数原型 ---- */
typedef AlsaOpenNative = Int32 Function(
    Pointer<Pointer<Void>>, Pointer<Utf8>, Int32, Int32);
typedef AlsaOpenDart = int Function(
    Pointer<Pointer<Void>>, Pointer<Utf8>, int, int);
typedef AlsaSizeofNative = Size Function();
typedef AlsaSizeofDart = int Function();
typedef AlsaPcmParamsNative = Int32 Function(Pointer<Void>, Pointer<Void>);
typedef AlsaPcmParamsDart = int Function(Pointer<Void>, Pointer<Void>);
typedef AlsaSetEnumNative = Int32 Function(
    Pointer<Void>, Pointer<Void>, Int32);
typedef AlsaSetEnumDart = int Function(Pointer<Void>, Pointer<Void>, int);
typedef AlsaSetRateNative = Int32 Function(
    Pointer<Void>, Pointer<Void>, Pointer<Uint32>, Pointer<Int32>);
typedef AlsaSetRateDart = int Function(
    Pointer<Void>, Pointer<Void>, Pointer<Uint32>, Pointer<Int32>);
typedef AlsaGetRateNative = Int32 Function(
    Pointer<Void>, Pointer<Uint32>, Pointer<Int32>);
typedef AlsaGetRateDart = int Function(
    Pointer<Void>, Pointer<Uint32>, Pointer<Int32>);
typedef AlsaSetFramesNative = Int32 Function(
    Pointer<Void>, Pointer<Void>, Pointer<Uint64>, Pointer<Int32>);
typedef AlsaSetFramesDart = int Function(
    Pointer<Void>, Pointer<Void>, Pointer<Uint64>, Pointer<Int32>);
typedef AlsaGetFramesNative = Int32 Function(
    Pointer<Void>, Pointer<Uint64>, Pointer<Int32>);
typedef AlsaGetFramesDart = int Function(
    Pointer<Void>, Pointer<Uint64>, Pointer<Int32>);
typedef AlsaUnaryNative = Int32 Function(Pointer<Void>);
typedef AlsaUnaryDart = int Function(Pointer<Void>);
typedef AlsaIoNative = Int64 Function(Pointer<Void>, Pointer<Void>, Uint64);
typedef AlsaIoDart = int Function(Pointer<Void>, Pointer<Void>, int);
typedef AlsaDelayNative = Int32 Function(Pointer<Void>, Pointer<Int64>);
typedef AlsaDelayDart = int Function(Pointer<Void>, Pointer<Int64>);
typedef AlsaAvailNative = Int64 Function(Pointer<Void>);
typedef AlsaAvailDart = int Function(Pointer<Void>);
typedef AlsaStateNative = Int32 Function(Pointer<Void>);
typedef AlsaStateDart = int Function(Pointer<Void>);
typedef AlsaStrerrorNative = Pointer<Utf8> Function(Int32);
typedef AlsaStrerrorDart = Pointer<Utf8> Function(int);
typedef AlsaHintNative = Int32 Function(
    Int32, Pointer<Utf8>, Pointer<Pointer<Pointer<Void>>>);
typedef AlsaHintDart = int Function(
    int, Pointer<Utf8>, Pointer<Pointer<Pointer<Void>>>);
typedef AlsaHintGetNative = Pointer<Utf8> Function(
    Pointer<Void>, Pointer<Utf8>);
typedef AlsaHintGetDart = Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>);
typedef AlsaHintFreeNative = Int32 Function(Pointer<Pointer<Void>>);
typedef AlsaHintFreeDart = int Function(Pointer<Pointer<Void>>);

class AlsaLib {
  AlsaLib._(this._lib);

  final DynamicLibrary _lib;

  late final open = _lib.lookupFunction<AlsaOpenNative, AlsaOpenDart>(
      'snd_pcm_open');
  late final hwParamsSizeof =
      _lib.lookupFunction<AlsaSizeofNative, AlsaSizeofDart>(
          'snd_pcm_hw_params_sizeof');
  late final hwParamsAny =
      _lib.lookupFunction<AlsaPcmParamsNative, AlsaPcmParamsDart>(
          'snd_pcm_hw_params_any');
  late final hwParamsSetAccess =
      _lib.lookupFunction<AlsaSetEnumNative, AlsaSetEnumDart>(
          'snd_pcm_hw_params_set_access');
  late final hwParamsSetFormat =
      _lib.lookupFunction<AlsaSetEnumNative, AlsaSetEnumDart>(
          'snd_pcm_hw_params_set_format');
  late final hwParamsSetChannels =
      _lib.lookupFunction<AlsaSetEnumNative, AlsaSetEnumDart>(
          'snd_pcm_hw_params_set_channels');
  late final hwParamsSetRateNear =
      _lib.lookupFunction<AlsaSetRateNative, AlsaSetRateDart>(
          'snd_pcm_hw_params_set_rate_near');
  late final hwParamsSetPeriodNear =
      _lib.lookupFunction<AlsaSetFramesNative, AlsaSetFramesDart>(
          'snd_pcm_hw_params_set_period_size_near');
  late final hwParamsSetBufferNear =
      _lib.lookupFunction<AlsaSetFramesNative, AlsaSetFramesDart>(
          'snd_pcm_hw_params_set_buffer_size_near');
  late final hwParams =
      _lib.lookupFunction<AlsaPcmParamsNative, AlsaPcmParamsDart>(
          'snd_pcm_hw_params');
  late final hwParamsGetPeriod =
      _lib.lookupFunction<AlsaGetFramesNative, AlsaGetFramesDart>(
          'snd_pcm_hw_params_get_period_size');
  late final hwParamsGetBuffer =
      _lib.lookupFunction<AlsaGetFramesNative, AlsaGetFramesDart>(
          'snd_pcm_hw_params_get_buffer_size');
  late final hwParamsGetRate =
      _lib.lookupFunction<AlsaGetRateNative, AlsaGetRateDart>(
          'snd_pcm_hw_params_get_rate');
  late final prepare =
      _lib.lookupFunction<AlsaUnaryNative, AlsaUnaryDart>('snd_pcm_prepare');
  late final writei =
      _lib.lookupFunction<AlsaIoNative, AlsaIoDart>('snd_pcm_writei');
  late final readi =
      _lib.lookupFunction<AlsaIoNative, AlsaIoDart>('snd_pcm_readi');
  late final delay =
      _lib.lookupFunction<AlsaDelayNative, AlsaDelayDart>('snd_pcm_delay');
  late final availUpdate =
      _lib.lookupFunction<AlsaAvailNative, AlsaAvailDart>(
          'snd_pcm_avail_update');
  late final state =
      _lib.lookupFunction<AlsaStateNative, AlsaStateDart>('snd_pcm_state');
  late final drop =
      _lib.lookupFunction<AlsaUnaryNative, AlsaUnaryDart>('snd_pcm_drop');
  late final drain =
      _lib.lookupFunction<AlsaUnaryNative, AlsaUnaryDart>('snd_pcm_drain');
  late final close =
      _lib.lookupFunction<AlsaUnaryNative, AlsaUnaryDart>('snd_pcm_close');
  late final strerror =
      _lib.lookupFunction<AlsaStrerrorNative, AlsaStrerrorDart>(
          'snd_strerror');
  late final deviceNameHint =
      _lib.lookupFunction<AlsaHintNative, AlsaHintDart>(
          'snd_device_name_hint');
  late final deviceNameGetHint =
      _lib.lookupFunction<AlsaHintGetNative, AlsaHintGetDart>(
          'snd_device_name_get_hint');
  late final deviceNameFreeHint =
      _lib.lookupFunction<AlsaHintFreeNative, AlsaHintFreeDart>(
          'snd_device_name_free_hint');

  static AlsaLib load() {
    return AlsaLib._(NativeLibraryLoader.openFirst(
        const ['libasound.so.2', 'libasound.so'],
        what: 'ALSA library'));
  }

  String errorText(int code) {
    try {
      return strerror(code).toDartString();
    } catch (e, st) {
      swallow(e, st);
      return 'alsa error $code';
    }
  }
}

/// 协商公共段：打开 [device] 并把 hw_params 谈到「交错 + 指定格式
/// 优先 + 双声道 + 目标速率/period/buffer」，返回 (pcm, 实际格式,
/// 实际速率, 实际period, 实际buffer)。out/in 两侧共用；失败抛
/// StateError（带 strerror 文案与设备名，便于设置页/日志定位）。
({Pointer<Void> pcm, int format, int rate, int period, int buffer})
    alsaOpenNegotiated(
  AlsaLib lib, {
  required String device,
  required int stream,
  required int requestedRate,
  required int wantPeriod,
  required List<int> formatPreference,
}) {
  final pp = malloc<Pointer<Void>>();
  final namePtr = device.toNativeUtf8();
  final int orc;
  try {
    orc = lib.open(pp, namePtr, stream, 0);
  } finally {
    malloc.free(namePtr);
  }
  if (orc < 0) {
    malloc.free(pp);
    throw StateError(
        'snd_pcm_open($device) failed: ${lib.errorText(orc)}');
  }
  final pcm = pp.value;
  malloc.free(pp);

  final params = malloc<Uint8>(lib.hwParamsSizeof());
  try {
    var rc = lib.hwParamsAny(pcm, params.cast());
    if (rc < 0) {
      throw StateError(
          'snd_pcm_hw_params_any($device): ${lib.errorText(rc)}');
    }
    // access/声道是帧布局的前提：谈不拢必须当场失败，不能让
    // apply 以单声道等形态蒙混过关——上层按交错立体声帧解释
    // 缓冲，声道数错位即垃圾音频且无声无息（打磨一期）。
    rc = lib.hwParamsSetAccess(pcm, params.cast(), alsaAccessRwInterleaved);
    if (rc < 0) {
      throw StateError(
          'snd_pcm_hw_params_set_access($device): ${lib.errorText(rc)}');
    }
    var format = 0;
    for (final f in formatPreference) {
      if (lib.hwParamsSetFormat(pcm, params.cast(), f) >= 0) {
        format = f;
        break;
      }
    }
    if (format == 0) {
      throw StateError('snd_pcm_hw_params_set_format($device): '
          'no acceptable format in $formatPreference');
    }
    rc = lib.hwParamsSetChannels(pcm, params.cast(), 2);
    if (rc < 0) {
      throw StateError(
          'snd_pcm_hw_params_set_channels($device, 2): '
          '${lib.errorText(rc)}');
    }
    final rate = malloc<Uint32>()..value = requestedRate;
    final dir = malloc<Int32>()..value = 0;
    final period = malloc<Uint64>()..value = wantPeriod;
    final buffer = malloc<Uint64>()..value = wantPeriod * 4;
    try {
      lib.hwParamsSetRateNear(pcm, params.cast(), rate, dir);
      lib.hwParamsSetPeriodNear(pcm, params.cast(), period, dir);
      lib.hwParamsSetBufferNear(pcm, params.cast(), buffer, dir);
      rc = lib.hwParams(pcm, params.cast());
      if (rc < 0) {
        throw StateError(
            'snd_pcm_hw_params($device): ${lib.errorText(rc)}');
      }
      final gp = malloc<Uint64>();
      final gb = malloc<Uint64>();
      final gr = malloc<Uint32>();
      try {
        lib.hwParamsGetPeriod(params.cast(), gp, dir);
        lib.hwParamsGetBuffer(params.cast(), gb, dir);
        lib.hwParamsGetRate(params.cast(), gr, dir);
        return (
          pcm: pcm,
          format: format,
          rate: gr.value,
          period: gp.value,
          buffer: gb.value
        );
      } finally {
        malloc.free(gp);
        malloc.free(gb);
        malloc.free(gr);
      }
    } finally {
      malloc.free(rate);
      malloc.free(dir);
      malloc.free(period);
      malloc.free(buffer);
    }
  } catch (e) {
    lib.close(pcm);
    rethrow;
  } finally {
    malloc.free(params);
  }
}

/// ALSA 设备名解析（纯逻辑，可单测）：空/纯空白 → 'default'
/// （ALSA 的逻辑默认设备）；其余原样（hw:/plughw:/自定义名）。
String resolveAlsaDevice(String raw) {
  final t = raw.trim();
  return t.isEmpty ? 'default' : t;
}

/// 枚举名去重（纯逻辑，保序）：hint 列表里同一设备可能以不同
/// 描述/方向条目重复出现，喂给设置页下拉前先收敛（打磨三期）。
List<String> dedupeAlsaNames(Iterable<String> names) {
  final seen = <String>{};
  final out = <String>[];
  for (final n in names) {
    if (seen.add(n)) out.add(n);
  }
  return out;
}

/// hint 的 IOID 与目标方向是否匹配（纯逻辑）：IOID 缺失
/// （null 等未标注条目）按匹配处理，不误伤双向设备。
bool alsaHintMatchesDirection(String? ioid, {required bool capture}) {
  if (ioid == null || ioid.isEmpty) return true;
  return capture ? ioid == 'Input' : ioid == 'Output';
}

/// 枚举 ALSA PCM 设备名（snd_device_name_hint 的 NAME 项）。
/// 设置页设备编辑用；失败（无 libasound 等）返回空表，不抛——
/// 枚举只是便利，设备名始终可手填。注意 free 的指针层级：
/// free_hint 取枚举返回的数组指针本身（A0 探针实测）。
List<String> listAlsaPcmDeviceNames({bool capture = false}) {
  final names = <String>[];
  AlsaLib lib;
  try {
    lib = AlsaLib.load();
  } catch (e, st) {
    swallow(e, st);
    return names;
  }
  final hints = malloc<Pointer<Pointer<Void>>>();
  final iface = 'pcm'.toNativeUtf8();
  try {
    final rc = lib.deviceNameHint(-1, iface, hints);
    if (rc < 0 || hints.value == nullptr) return names;
    final key = 'NAME'.toNativeUtf8();
    final ioKey = 'IOID'.toNativeUtf8();
    try {
      var p = hints.value;
      while (p.value != nullptr) {
        final n = lib.deviceNameGetHint(p.value, key);
        if (n != nullptr) {
          final s = n.toDartString();
          // 按方向过滤：采集字段只列可采集的设备（IOID=Input），
          // 输出字段只列可播放的（IOID=Output），未标注不误伤。
          final io = lib.deviceNameGetHint(p.value, ioKey);
          final ioid = io == nullptr ? null : io.toDartString();
          if (s.isNotEmpty &&
              alsaHintMatchesDirection(ioid, capture: capture)) {
            names.add(s);
          }
        }
        p++;
      }
    } finally {
      malloc.free(key);
      malloc.free(ioKey);
    }
    lib.deviceNameFreeHint(hints.value);
  } catch (e, st) {
    // swallow: 枚举中途异常：返回已收集部分（尽力而为的便利功能）。
    swallow(e, st);
  } finally {
    malloc.free(iface);
    malloc.free(hints);
  }
  return dedupeAlsaNames(names);
}
