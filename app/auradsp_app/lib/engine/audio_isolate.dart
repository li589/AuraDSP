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
import 'audio_vbridge.dart';
import 'audio_abridge.dart';
import 'audio_vaio_bridge.dart';
import 'debug_log.dart';


part 'audio_guid.dart';
part 'audio_device.dart';
part 'audio_wav.dart';
part 'audio_sources.dart';
part 'audio_slots.dart';





/* ---------------- 消息协议 ---------------- */

/// 引擎配置的兜底值。AppModel 在 Isolate.spawn 时下发真实值（见 state.dart _spawn）；
/// 缺字段时用这些，保证单独启动 isolate（如测试）也能跑。
const int kFallbackMaxBlockFrames = 2048;
const int kFallbackVizFps = 30;
const int kFallbackSampleRate = 0; // 0 = 跟随设备 mix format
const int kFallbackVizFftSize = 4096;
const double kFallbackMaxIrSeconds = 30.0;
const double kFallbackMaxFileMb = 64.0;

int _cfgInt(Map<String, dynamic> cfg, String key, int fallback) {
  final v = cfg[key];
  return v is num ? v.toInt() : fallback;
}

double _cfgDouble(Map<String, dynamic> cfg, String key, double fallback) {
  final v = cfg[key];
  return v is num ? v.toDouble() : fallback;
}

void audioIsolateMain(Map<String, dynamic> cfg) {
  final toMain = cfg['toMain'] as SendPort;
  final fromMain = ReceivePort();

  // 真正生效的引擎配置（不再是写死在代码里的常量）
  final maxBlockFrames =
      _cfgInt(cfg, 'maxBlockFrames', kFallbackMaxBlockFrames).clamp(256, 8192);
  final vizFps = _cfgInt(cfg, 'vizFps', kFallbackVizFps).clamp(5, 120);
  final requestedRate = _cfgInt(cfg, 'sampleRate', kFallbackSampleRate);
  final vizFftSize =
      _cfgInt(cfg, 'vizFftSize', kFallbackVizFftSize).clamp(1024, 8192);
  final maxIrSeconds =
      _cfgDouble(cfg, 'maxIrDurationSeconds', kFallbackMaxIrSeconds);
  final maxFileMb = _cfgDouble(cfg, 'maxFileSizeMb', kFallbackMaxFileMb);
  // UI 拉取节流：与 config.vizFps 同源，不再是写死的 33ms
  final vizIntervalMs = (1000.0 / vizFps).round();

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

  // VB-Callback 模式面（05 桥）：与 WASAPI 路径互斥，一次只跑一边。
  bool vbActive = false;
  AuraVmBridge? vb;
  // ASIO 模式面（04 桥）：与 VB/WASAPI 同互斥（一次只跑一个后端）。
  bool asioActive = false;
  AuraAsioBridge? ab;
  String asioDriverInUse = ''; // 当前桥会话用的驱动名（诊断对账用）
  // AuraVAIO 虚拟声卡模式面（Mode 1 桥）：与 VB/ASIO/WASAPI 互斥。
  bool vaioActive = false;
  AuraVaioBridge? vaio;
  String vaioOutputEndpointInUse = '';
  int vaioStatusTick = 0;
  // 参数镜像：每次 setParam 记录，vb_start 后全量回放，保证两边一致。
  final Map<String, ({bool isFloat, double value})> paramMirror = {};
  // 字符串参数镜像（liveprog.code / arbmag.string）：成功才记；进 VB 时全量
  // 回放，桥内另有镜像应对 CHANGE 重建（与 paramMirror 同口径）。
  final Map<String, String> paramStrMirror = {};
  // VB 总线掩码（session 级；进桥/重建后下发，CHANGE 重建不丢——掩码活在 ctx）。
  int vbBusMask = 0xFF;
  int vbStatusTick = 0;
  bool vbVizNullLogged = false;
  bool vbNoCbLogged = false;
  bool vbVizOkLogged = false;
  int vbStatusAt = 0;
  bool vaioVizNullLogged = false;
  bool vaioNoCbLogged = false;
  bool vaioVizOkLogged = false;
  int vaioStatusAt = 0;

  // 欠载（avail<=0）或无音源时引擎不再产出 viz 帧，UI 会把最后一帧电平永久冻住。
  // 持续空闲后补发一帧全零，使电平与频谱回落到 0。
  //
  // 关键：WASAPI 下 avail 间歇性 <= 0 是常态，若「每次进入空闲就补发」，
  // 零帧会与紧随其后的真实帧在 ~200Hz 上交替，表现为频谱/电平疯狂闪烁。
  // 故必须持续空闲满 80 轮（400ms / 每轮 5ms）才补发一次。
  const idleVizRounds = 80;
  var idleRounds = 0;
  var idleVizSent = false;
  var lastSpectrumLen = 32;
  var lastStageLen = 32; // 与 kEngineStageCount 对齐

  void sendIdleViz() {
    if (idleVizSent) return;
    idleVizSent = true;
    send({
      'evt': 'viz',
      'spectrum': List<double>.filled(lastSpectrumLen, 0.0),
      'eqIn': List<double>.filled(lastSpectrumLen, 0.0),
      'l': -90.0,
      'r': -90.0,
      'stageL': List<double>.filled(lastStageLen, -90.0),
      'stageR': List<double>.filled(lastStageLen, -90.0),
      'ts': DateTime.now().millisecondsSinceEpoch,
      'seq': -1,
    });
  }

  /* ---- VB-Callback 模式面（与 WASAPI 路径互斥） ---- */

  void startVbBridge() {
    if (vbActive) return;
    dbgLog('vbmode: start requested');
    try {
      vb ??= AuraVmBridge.load();
    } catch (e) {
      send(
          {'evt': 'vbstatus', 'running': false, 'note': 'bridge-missing: $e'});
      return;
    }
    final rc = vb!.start(AuraDspLib.loadedPath ?? '', '');
    dbgLog('vbmode: start rc=$rc');
    if (rc != 0) {
      final st = vb!.status();
      send({
        'evt': 'vbstatus',
        'running': false,
        'note': (st?['note'] as String?) ?? 'start-rc=$rc'
      });
      return;
    }
    // 全量回放参数镜像（setParamStr 如 liveprog.code 暂不同步：桥 handle 用默认值）。
    var replayed = 0;
    for (final e in paramMirror.entries) {
      vb!.setParam(e.key, isFloat: e.value.isFloat, value: e.value.value);
      replayed++;
    }
    dbgLog('vbmode: replayed $replayed params');
    // 字符串参数回放（LiveProg/ArbMag 在 VB 下生效就靠这次；桥内镜像只负责
    // CHANGE 重建，首次进桥必须由这里推过去）。
    var replayedStr = 0;
    for (final e in paramStrMirror.entries) {
      final brc = vb!.setParamStr(e.key, e.value);
      if (brc > 0) replayedStr++;
    }
    dbgLog('vbmode: replayed $replayedStr str params');
    // 旁路态同步（用户此前可能已开旁路；桥默认关）。
    final bypassRc = vb!.setBypass(bypass);
    dbgLog('vbmode: bypass sync isolate=$bypass rc=$bypassRc');
    // 总线掩码同步（model 持久化的选择；桥默认全开）。
    final maskRc = vb!.setBusMask(vbBusMask);
    dbgLog('vbmode: busmask sync isolate=$vbBusMask rc=$maskRc');
    try {
      wasapi?.stop();
    } catch (_) {}
    source = null;
    vbActive = true;
    vbVizNullLogged = false;
    vbNoCbLogged = false;
    vbVizOkLogged = false;
    vbStatusAt = DateTime.now().millisecondsSinceEpoch;
    final st = vb!.status();
    dbgLog('vbmode: started handles=${st?['handles']} groups=${st?['groups']} '
        'frames=${st?['frames']} peakIn=${st?['peakIn']} note=${st?['note']}');
    send({'evt': 'vbstatus', ...?st, 'running': true});
  }

  void stopVbBridge() {
    if (!vbActive) return;
    dbgLog('vbmode: stop requested');
    try {
      vb?.testStop();
    } catch (_) {}
    try {
      vb?.stop();
    } catch (_) {}
    vbActive = false;
    try {
      wasapi?.start();
    } catch (_) {}
    send({'evt': 'vbstatus', 'running': false});
  }

  /* ---- ASIO 模式面（04 桥；与 VB/WASAPI 互斥） ---- */

  /// 驱动清单回执：无论后续能否启动，都先把 detect 结果发给设置页。
  void detectAsioDrivers() {
    try {
      ab ??= AuraAsioBridge.load();
    } catch (e) {
      send({'evt': 'asiodrivers', 'drivers': [], 'note': 'bridge-missing: $e'});
      return;
    }
    final list = ab!.detect();
    if (list == null) {
      send({'evt': 'asiodrivers', 'drivers': [], 'note': 'detect-failed'});
      return;
    }
    if (list.isEmpty) {
      send({'evt': 'asiodrivers', 'drivers': [], 'note': 'no-drivers'});
      return;
    }
    send({'evt': 'asiodrivers', 'drivers': list, 'note': ''});
  }

  /// driver/bufSize/outPair 由主 isolate 随命令带参（config 真相源在主侧）。
  /// driver 为空则取清单第一个（零配置可用；清单也空则报 no-drivers）。
  void startAsioBridge(
      {required String driver, required int bufSize, required int outPair}) {
    if (asioActive) return;
    dbgLog('asiomode: start requested driver="$driver" '
        'buf=$bufSize pair=$outPair');
    try {
      ab ??= AuraAsioBridge.load();
    } catch (e) {
      send({'evt': 'asiostatus', 'running': false, 'note': 'bridge-missing: $e'});
      return;
    }
    // 零配置兜底：driver 空则 detect 取第一个；顺带回传清单（设置页下拉）。
    var drv = driver;
    final list = ab!.detect() ?? const [];
    send({'evt': 'asiodrivers', 'drivers': list,
        'note': list.isEmpty ? 'no-drivers' : ''});
    if (drv.isEmpty) {
      if (list.isEmpty) {
        send({'evt': 'asiostatus', 'running': false, 'note': 'no-drivers'});
        return;
      }
      drv = (list.first['name'] as String?) ?? '';
      if (drv.isEmpty) {
        send({'evt': 'asiostatus', 'running': false, 'note': 'no-drivers'});
        return;
      }
    }
    // 主 isolate 下发的 engineDll 为空时桥内自动搜索；有 loadedPath 就显式传
    //（与 vbmode 同策略：App 真相源优先）。
    final rc = ab!.start(drv, engineDll: AuraDspLib.loadedPath ?? '',
        bufSize: bufSize, outPair: outPair);
    dbgLog('asiomode: start rc=$rc');
    if (rc != 0) {
      final st = ab!.status();
      send({
        'evt': 'asiostatus',
        'running': false,
        'note': (st?['note'] as String?) ?? 'start-rc=$rc'
      });
      return;
    }
    // 全量回放参数镜像（与 vbmode 同款：桥 handle 用默认值起步）。
    var replayed = 0;
    for (final e in paramMirror.entries) {
      ab!.setParam(e.key, isFloat: e.value.isFloat, value: e.value.value);
      replayed++;
    }
    dbgLog('asiomode: replayed $replayed params');
    // 字符串参数回放（LiveProg/ArbMag 在 ASIO 下生效就靠这次；ASIO 重建一律
    // 走本函数，重放必到）。
    var replayedStr = 0;
    for (final e in paramStrMirror.entries) {
      if (ab!.setParamStr(e.key, e.value) == 0) replayedStr++;
    }
    dbgLog('asiomode: replayed $replayedStr str params');
    // 旁路态同步（用户此前可能已开旁路；桥默认关）。
    final bypassRc = ab!.setBypass(bypass);
    dbgLog('asiomode: bypass sync isolate=$bypass rc=$bypassRc');
    try {
      wasapi?.stop();
    } catch (_) {}
    source = null;
    asioActive = true;
    asioDriverInUse = drv;
    vbVizNullLogged = false;
    vbNoCbLogged = false;
    vbVizOkLogged = false;
    vbStatusAt = DateTime.now().millisecondsSinceEpoch;
    final st = ab!.status();
    dbgLog('asiomode: started sr=${st?['sr']} nbs=${st?['nbs']} '
        'outPair=${st?['outPair']} driver=${st?['driver']} note=${st?['note']}');
    send({'evt': 'asiostatus', ...?st, 'running': true, 'driverInUse': drv});
  }

  void stopAsioBridge() {
    if (!asioActive) return;
    dbgLog('asiomode: stop requested');
    try {
      ab?.testStop();
    } catch (_) {}
    try {
      ab?.stop();
    } catch (_) {}
    asioActive = false;
    asioDriverInUse = '';
    try {
      wasapi?.start();
    } catch (_) {}
    send({'evt': 'asiostatus', 'running': false});
  }

  /* ---- AuraVAIO 虚拟声卡模式面（Mode 1 桥；与 VB/ASIO/WASAPI 互斥） ---- */

  void detectVaio() {
    try {
      vaio ??= AuraVaioBridge.load();
    } catch (e) {
      send({'evt': 'vaiodetect', 'found': false, 'note': 'bridge-missing: $e', 'endpoints': []});
      return;
    }
    final info = vaio!.detect();
    send({'evt': 'vaiodetect', ...?info});
  }

  void startVaioBridge({String outputEndpointSubstr = ''}) {
    if (vaioActive) return;
    dbgLog('vaiomode: start requested output="$outputEndpointSubstr"');
    try {
      vaio ??= AuraVaioBridge.load();
    } catch (e) {
      send({'evt': 'vaiostatus', 'running': false, 'note': 'bridge-missing: $e'});
      return;
    }
    final rc = vaio!.start(AuraDspLib.loadedPath ?? '', '', outputEndpointSubstr: outputEndpointSubstr);
    dbgLog('vaiomode: start rc=$rc');
    if (rc != 0) {
      final st = vaio!.status();
      send({
        'evt': 'vaiostatus',
        'running': false,
        'note': (st?['note'] as String?) ?? 'start-rc=$rc',
      });
      return;
    }
    // 回放参数镜像
    var replayed = 0;
    for (final e in paramMirror.entries) {
      vaio!.setParam(e.key, isFloat: e.value.isFloat, value: e.value.value);
      replayed++;
    }
    dbgLog('vaiomode: replayed $replayed params');
    var replayedStr = 0;
    for (final e in paramStrMirror.entries) {
      final brc = vaio!.setParamStr(e.key, e.value);
      if (brc >= 0) replayedStr++;
    }
    dbgLog('vaiomode: replayed $replayedStr str params');
    vaio!.setBypass(bypass);
    try {
      wasapi?.stop();
    } catch (_) {}
    source = null;
    vaioActive = true;
    vaioOutputEndpointInUse = outputEndpointSubstr;
    vaioVizNullLogged = false;
    vaioNoCbLogged = false;
    vaioVizOkLogged = false;
    vaioStatusAt = DateTime.now().millisecondsSinceEpoch;
    final st = vaio!.status();
    send({'evt': 'vaiostatus', ...?st, 'running': true});
  }

  void stopVaioBridge() {
    if (!vaioActive) return;
    dbgLog('vaiomode: stop requested');
    try {
      vaio?.testStop();
    } catch (_) {}
    try {
      vaio?.stop();
    } catch (_) {}
    vaioActive = false;
    vaioOutputEndpointInUse = '';
    try {
      wasapi?.start();
    } catch (_) {}
    send({'evt': 'vaiostatus', 'running': false});
  }

  /* 高频日志采样器：setParam / setParamStr 每帧都可能触发（拖滑块 ~60Hz），
   * 无门控的同步落盘会在音频泵线程上产生上百次/秒 flushSync，
   * 直接抬升 WASAPI 抖动、诱发 underrun。 */
  final logSetParam = ThrottledLog('setParam');
  final logSetParamStr = ThrottledLog('setParamStr');
  final logCmd = ThrottledLog('cmd', head: 40, every: 200);

  fromMain.listen((raw) {
    final m = raw as Map;
    // 命令轨迹（采样）：完整命令流对排障有用，但每帧一条会淹没日志
    if (logCmd.shouldLog) {
      dbgLog('cmd: ${m['cmd']} ${m['kind'] ?? m['id'] ?? ''} ${m['value'] ?? ''}');
    }
    try {
      switch (m['cmd'] as String) {
        case 'setParam':
          final t0 = DateTime.now();
          final rc = AuraDspLib.setValue(lib!, handle!, m['id'] as String,
              isFloat: m['isFloat'] as bool, value: (m['value'] as num).toDouble());
          // 参数镜像 + VB 桥同路由（setParamStr 如 liveprog.code 暂不同步）。
          paramMirror[m['id'] as String] = (
            isFloat: m['isFloat'] as bool,
            value: (m['value'] as num).toDouble()
          );
                    if (vbActive && vb != null) {
            final brc = vb!.setParam(m['id'] as String,
                isFloat: m['isFloat'] as bool,
                value: (m['value'] as num).toDouble());
            // 桥 handle 为空（如 CHANGE 重建间隙）会返回 0：记一笔备查。
            if (brc == 0) dbgLog('vbmode: setParam ${m['id']} applied 0');
          }
          if (asioActive && ab != null) {
            final arc = ab!.setParam(m['id'] as String,
                isFloat: m['isFloat'] as bool,
                value: (m['value'] as num).toDouble());
            if (arc == 0) dbgLog('asiomode: setParam ${m['id']} applied 0');
          }
          if (vaioActive && vaio != null) {
            final vrc = vaio!.setParam(m['id'] as String,
                isFloat: m['isFloat'] as bool,
                value: (m['value'] as num).toDouble());
            if (vrc != 0) dbgLog('vaiomode: setParam ${m['id']} rc=$vrc');
          }
          final tookMs = DateTime.now().difference(t0).inMilliseconds;
          // 关键证据：引擎应用耗时。旧实现全量重建混响/EQ 时这里是几十~几百 ms。
          logSetParam.admit('${m['id']}=${m['value']} rc=$rc took=${tookMs}ms');
          String? err;
          if (rc != Status.ok) {
            final e = lib.lastError(handle);
            err = e == nullptr ? null : e.toDartString();
          }
          send({'evt': 'paramResult', 'id': m['id'], 'rc': rc, 'msg': err, 'tookMs': tookMs});
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
            final iLim = idp('limiter.enable');
            final iCh = idp('channels.mode');
            final iLpEn = idp('liveprog.enable'), iLpSt = idp('liveprog.status');
            final iCvEn = idp('convolver.enable'), iCvRd = idp('convolver.ready');
            final iCvF = idp('convolver.ir.frames'), iCvCh = idp('convolver.ir.channels');
            final iCvSr = idp('convolver.ir.srcRate'), iCvPk = idp('convolver.ir.peak');
            final iCvSpec = idp('convolver.ir.spectrum');
            final iTb = idp('tube.enable'), iXf = idp('crossfeed.enable');
            // P-011：电子管音色/混合/补偿回读
            final iTbS = idp(ParamId.tubeStyle), iTbM = idp(ParamId.tubeMix), iTbC = idp(ParamId.tubeCompensation);
            final iXfM = idp(ParamId.xfeedMode), iXfFc = idp(ParamId.xfeedFcut), iXfFd = idp(ParamId.xfeedFeed);
            final iSbU = idp('stereo.bandUsed');
            final iCvM = idp('convolver.mix');
            final iDdE = idp('ddc.enable'), iDdR = idp('ddc.ready');
            final iShE = idp('shelf.enable'), iShF = idp('shelf.freq'), iShG = idp('shelf.gain');
            final iBmE = idp(ParamId.bassmonoEnable), iBmF = idp(ParamId.bassmonoFreq);
            final iHsE = idp(ParamId.haasEnable), iHsD = idp(ParamId.haasDelay), iHsM = idp(ParamId.haasMix);
            final iHsS = idp(ParamId.haasSide);
            final iSpE = idp(ParamId.spatialEnable), iSpS = idp(ParamId.spatialStyle);
            final iSpR = idp(ParamId.spatialRoom), iSpW = idp(ParamId.spatialWidth);
            final iSpC = idp(ParamId.spatialCenter), iSpG = idp(ParamId.spatialOutGain);
            final iSpA = idp(ParamId.spatialAutoGain);
            final iExE = idp(ParamId.exciterEnable), iExA = idp(ParamId.exciterAmount), iExF = idp(ParamId.exciterHifreq);
            // P-010：每效果输出增益门 + 自动补偿
            final iBoG = idp(ParamId.bassOutGain), iBoA = idp(ParamId.bassAutoGain);
            final iEoG = idp(ParamId.eqOutGain), iEoA = idp(ParamId.eqAutoGain);
            final iToG = idp(ParamId.tubeOutGain), iToA = idp(ParamId.tubeAutoGain);
            final iCoG = idp(ParamId.compOutGain), iCoA = idp(ParamId.compAutoGain);
            final iRoG = idp(ParamId.reverbOutGain), iRoA = idp(ParamId.reverbAutoGain);
            // 噪声门 + Deesser
            final iGtE = idp(ParamId.gateEnable), iGtT = idp(ParamId.gateThreshold);
            final iGtA = idp(ParamId.gateAttack), iGtR = idp(ParamId.gateRelease);
            final iGtG = idp(ParamId.gateAutoGain);
            final iDsE = idp(ParamId.deesserEnable), iDsF = idp(ParamId.deesserFreq), iDsA = idp(ParamId.deesserAmount);
            // 全参数动态EQ
            final iDyE = idp(ParamId.dyneqEnable), iDyA = idp(ParamId.dyneqAttack), iDyR = idp(ParamId.dyneqRelease);
            final iDyLE = idp(ParamId.dyneqLowEnable), iDyLF = idp(ParamId.dyneqLowFreq), iDyLQ = idp(ParamId.dyneqLowQ);
            final iDyLG = idp(ParamId.dyneqLowGain), iDyLR = idp(ParamId.dyneqLowRange), iDyLT = idp(ParamId.dyneqLowThreshold);
            final iDyME = idp(ParamId.dyneqMidEnable), iDyMF = idp(ParamId.dyneqMidFreq), iDyMQ = idp(ParamId.dyneqMidQ);
            final iDyMG = idp(ParamId.dyneqMidGain), iDyMR = idp(ParamId.dyneqMidRange), iDyMT = idp(ParamId.dyneqMidThreshold);
            final iDyHE = idp(ParamId.dyneqHighEnable), iDyHF = idp(ParamId.dyneqHighFreq), iDyHQ = idp(ParamId.dyneqHighQ);
            final iDyHG = idp(ParamId.dyneqHighGain), iDyHR = idp(ParamId.dyneqHighRange), iDyHT = idp(ParamId.dyneqHighThreshold);
            final iLdE = idp(ParamId.loudnessEnable), iLdA = idp(ParamId.loudnessAmount);
            final iBhH = idp(ParamId.bassHarmonics), iBhB = idp(ParamId.bassHarmonicBlend);
            final iBhS = idp(ParamId.bassSubFreq), iBhC = idp(ParamId.bassCutoffF);
            final iFtE = idp(ParamId.filterEnable), iFtT = idp(ParamId.filterType);
            final iFtF = idp(ParamId.filterFreq), iFtQ = idp(ParamId.filterQ);
            final iFvE = idp('freeverb.enable'), iFvD = idp('freeverb.decay');
            final iFvDa = idp('freeverb.damp'), iFvW = idp('freeverb.wet'), iFvDr = idp('freeverb.dry');
            final iCpE = idp(ParamId.compEnable), iCpT = idp(ParamId.compTimeconstant);
            final iCpG = idp(ParamId.compGranularity), iCpR = idp(ParamId.compTfresolution);
            final iArbE = idp(ParamId.arbmagEnable), iArbR = idp(ParamId.arbmagReady);
            final iArbN = idp(ParamId.arbmagNodeCount);
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
                'stereoMix': rdFloat(iMix) ?? 0.0, // 兜底必须=ParamDefaults.stereoMix（UI 为真，原 0.5）
                'eqEnable': rdInt(iEq) ?? 0,
                'postGain': rdFloat(iPost) ?? 0.0,
                'limiterEnable': rdInt(iLim) ?? 1,
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
                'tubeStyle': rdInt(iTbS) ?? 0,
                'tubeMix': rdFloat(iTbM) ?? 1.0,
                'tubeCompensation': rdFloat(iTbC) ?? 0.0,
                'xfeedEnable': rdInt(iXf) ?? 0,
                'xfeedMode': rdInt(iXfM) ?? 0,
                'xfeedFcut': rdFloat(iXfFc) ?? 700.0,
                'xfeedFeed': rdFloat(iXfFd) ?? 4.5,
                'stereoBandUsed': rdInt(iSbU) ?? 0,
                'convMix': rdFloat(iCvM) ?? 1.0,
                'ddcEnable': rdInt(iDdE) ?? 0,
                'ddcReady': rdInt(iDdR) ?? 0,
                'shelfEnable': rdInt(iShE) ?? 0,
                'shelfFreq': rdFloat(iShF) ?? 100.0,
                'shelfGain': rdFloat(iShG) ?? 0.0,
                'bassmonoEnable': rdInt(iBmE) ?? 0,
                'bassmonoFreq': rdFloat(iBmF) ?? 120.0,
                'haasEnable': rdInt(iHsE) ?? 0,
                'haasDelay': rdFloat(iHsD) ?? 12.0,
                'haasMix': rdFloat(iHsM) ?? 1.0,
                'haasSide': rdInt(iHsS) ?? 0,
                'spatialEnable': rdInt(iSpE) ?? 0,
                'spatialStyle': rdInt(iSpS) ?? 0,
                'spatialRoom': rdFloat(iSpR) ?? 0.7,
                'spatialWidth': rdFloat(iSpW) ?? 1.0,
                'spatialCenter': rdFloat(iSpC) ?? 0.8,
                'spatialOutGain': rdFloat(iSpG) ?? 0.0,
                'spatialAutoGain': rdInt(iSpA) ?? 0,
                'exciterEnable': rdInt(iExE) ?? 0,
                'exciterAmount': rdFloat(iExA) ?? 0.3,
                'exciterHifreq': rdFloat(iExF) ?? 5000.0,
                'bassOutGain': rdFloat(iBoG) ?? 0.0,
                'bassAutoGain': rdInt(iBoA) ?? 0,
                'eqOutGain': rdFloat(iEoG) ?? 0.0,
                'eqAutoGain': rdInt(iEoA) ?? 0,
                'tubeOutGain': rdFloat(iToG) ?? 0.0,
                'tubeAutoGain': rdInt(iToA) ?? 0,
                'compOutGain': rdFloat(iCoG) ?? 0.0,
                'compAutoGain': rdInt(iCoA) ?? 0,
                'reverbOutGain': rdFloat(iRoG) ?? 0.0,
                'reverbAutoGain': rdInt(iRoA) ?? 0,
                'gateEnable': rdInt(iGtE) ?? 0,
                'gateThreshold': rdFloat(iGtT) ?? -40.0,
                'gateAttack': rdFloat(iGtA) ?? 10.0,
                'gateRelease': rdFloat(iGtR) ?? 100.0,
                'gateAutoGain': rdInt(iGtG) ?? 0,
                'deesserEnable': rdInt(iDsE) ?? 0,
                'deesserFreq': rdFloat(iDsF) ?? 6000.0,
                'deesserAmount': rdFloat(iDsA) ?? 0.5,
                'dyneqEnable': rdInt(iDyE) ?? 0,
                'dyneqAttack': rdFloat(iDyA) ?? 2.0,
                'dyneqRelease': rdFloat(iDyR) ?? 120.0,
                'dyneqLowEnable': rdInt(iDyLE) ?? 0,
                'dyneqLowFreq': rdFloat(iDyLF) ?? 120.0,
                'dyneqLowQ': rdFloat(iDyLQ) ?? 0.707,
                'dyneqLowGain': rdFloat(iDyLG) ?? 0.0,
                'dyneqLowRange': rdFloat(iDyLR) ?? 6.0,
                'dyneqLowThreshold': rdFloat(iDyLT) ?? -30.0,
                'dyneqMidEnable': rdInt(iDyME) ?? 0,
                'dyneqMidFreq': rdFloat(iDyMF) ?? 1000.0,
                'dyneqMidQ': rdFloat(iDyMQ) ?? 1.0,
                'dyneqMidGain': rdFloat(iDyMG) ?? 0.0,
                'dyneqMidRange': rdFloat(iDyMR) ?? 6.0,
                'dyneqMidThreshold': rdFloat(iDyMT) ?? -30.0,
                'dyneqHighEnable': rdInt(iDyHE) ?? 0,
                'dyneqHighFreq': rdFloat(iDyHF) ?? 6000.0,
                'dyneqHighQ': rdFloat(iDyHQ) ?? 0.707,
                'dyneqHighGain': rdFloat(iDyHG) ?? 0.0,
                'dyneqHighRange': rdFloat(iDyHR) ?? 6.0,
                'dyneqHighThreshold': rdFloat(iDyHT) ?? -30.0,
                'loudnessEnable': rdInt(iLdE) ?? 0,
                'loudnessAmount': rdFloat(iLdA) ?? 0.5,
                'bassHarmonics': rdFloat(iBhH) ?? 0.45,
                'bassHarmonicBlend': rdFloat(iBhB) ?? 0.5,
                'bassSubFreq': rdFloat(iBhS) ?? 25.0,
                'bassCutoffF': rdFloat(iBhC) ?? 120.0,
                'filterEnable': rdInt(iFtE) ?? 0,
                'filterType': rdInt(iFtT) ?? 0,
                'filterFreq': rdFloat(iFtF) ?? 80.0,
                'filterQ': rdFloat(iFtQ) ?? 0.707,
                'fvEnable': rdInt(iFvE) ?? 0,
                'fvDecay': rdFloat(iFvD) ?? 0.5,
                'fvDamp': rdFloat(iFvDa) ?? 0.5,
                'fvWet': rdFloat(iFvW) ?? 0.35, // 兜底必须=ParamDefaults.fvWet（UI 为真，原 0.3）
                'fvDry': rdFloat(iFvDr) ?? 1.0,
                'compEnable': rdInt(iCpE) ?? 0,
                'compTimeconstant': rdFloat(iCpT) ?? 0.14,
                'compGranularity': rdInt(iCpG) ?? 1,
                'compTfresolution': rdInt(iCpR) ?? 1,
                'arbmagEnable': rdInt(iArbE) ?? 0,
                'arbmagReady': rdInt(iArbR) ?? 0,
                'arbmagNodeCount': rdInt(iArbN) ?? 0,
              });
            } finally {
              for (final q in [iBass, iBassG, iRev, iMix, iEq, iPost, iLim, iCh, iLpEn, iLpSt, iCvEn, iCvRd, iCvF, iCvCh, iCvSr, iCvPk, iCvSpec, iTb, iXf, iSbU, iShE, iShF, iShG, iBmE, iBmF, iHsE, iHsD, iHsM, iHsS, iExE, iExA, iExF, iBoG, iBoA, iEoG, iEoA, iToG, iToA, iCoG, iCoA, iRoG, iRoA, iGtE, iGtT, iGtA, iGtR, iGtG, iDsE, iDsF, iDsA, iLdE, iLdA, iBhH, iBhB, iBhS, iBhC, iFtE, iFtT, iFtF, iFtQ, iFvE, iFvD, iFvDa, iFvW, iFvDr, iCvM, iDdE, iDdR, iCpE, iCpT, iCpG, iCpR, iArbE, iArbR, iArbN]) {
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
            // 字符串镜像 + VB 桥同路由（成功才记；桥内镜像应对 CHANGE 重建）。
            if (rc == Status.ok) {
              paramStrMirror[m['id'] as String] = m['text'] as String;
            }
            if (vbActive && vb != null) {
              final brc =
                  vb!.setParamStr(m['id'] as String, m['text'] as String);
              // 桥 handle 为空（如 CHANGE 重建间隙）会返回 0：记一笔备查。
              if (brc == 0) {
                dbgLog('vbmode: setParamStr ${m['id']} applied 0');
              }
            }
            if (asioActive && ab != null) {
              // ASIO 约定与 VB 不同：0=ok，<0=失败（桥内无镜像，重建一律走
              // Dart 侧 stop+start + paramStrMirror 回放）。
              final arc =
                  ab!.setParamStr(m['id'] as String, m['text'] as String);
              if (arc != 0) {
                dbgLog('asiomode: setParamStr ${m['id']} rc=$arc');
              }
            }
            if (vaioActive && vaio != null) {
              final vrc = vaio!.setParamStr(m['id'] as String, m['text'] as String);
              if (vrc < 0) {
                dbgLog('vaiomode: setParamStr ${m['id']} rc=$vrc');
              }
            }
            final tookMs = DateTime.now().difference(t0).inMilliseconds;
            logSetParamStr.admit('${m['id']} (${(m['text'] as String).length}B) '
                'rc=$rc took=${tookMs}ms');
            String? err;
            if (rc != Status.ok) {
              final e = lib.lastError(handle);
              err = e == nullptr ? null : e.toDartString();
            }
            send({'evt': 'paramResult', 'id': m['id'], 'rc': rc, 'msg': err, 'tookMs': tookMs});
            if (rc == Status.ok && m['id'] == 'liveprog.code') {
              // 桥下读桥 handle 的编译状态（进程内 handle 只是影子，不跑音频）。
              int? bst;
              if (vbActive && vb != null) {
                bst = vb!.getIntParam('liveprog.status');
              } else if (asioActive && ab != null) {
                bst = ab!.getIntParam('liveprog.status');
              } else if (vaioActive && vaio != null) {
                bst = vaio!.getIntParam('liveprog.status');
              }
              final st = bst ??
                  AuraDspLib.getInt(lib, handle, 'liveprog.status');
              send({'evt': 'liveprog', 'status': st});
            }
            if (rc == Status.ok && m['id'] == 'arbmag.string') {
              int? bNodes, bReady;
              if (vbActive && vb != null) {
                bNodes = vb!.getIntParam('arbmag.nodeCount');
                bReady = vb!.getIntParam('arbmag.ready');
              } else if (asioActive && ab != null) {
                bNodes = ab!.getIntParam('arbmag.nodeCount');
                bReady = ab!.getIntParam('arbmag.ready');
              } else if (vaioActive && vaio != null) {
                bNodes = vaio!.getIntParam('arbmag.nodeCount');
                bReady = vaio!.getIntParam('arbmag.ready');
              }
              final nodes = bNodes ??
                  AuraDspLib.getInt(lib, handle, 'arbmag.nodeCount');
              final ready = bReady ??
                  AuraDspLib.getInt(lib, handle, 'arbmag.ready');
              send({'evt': 'arbmag', 'nodes': nodes, 'ready': ready});
            }
            break;
          }
        case 'source':
          final kind = m['kind'] as String;
          // VB 模式：测试源走桥注入（自动静音主通道 VB 输入），isolate 本地 source 保持空。
          if (vbActive && vb != null && kind != 'stop') {
            final tk = kind == 'tone'
                ? 1
                : kind == 'pink'
                    ? 2
                    : kind == 'file'
                        ? 3
                        : 0;
            if (tk == 3) {
              final fpath = m['path'] as String;
              final lb = lib;
              final decoded = fpath.toLowerCase().endsWith('.mp3')
                  ? (lb == null ? null : decodeMp3File(lb, fpath))
                  : decodeWavFile(fpath);
              if (decoded == null) {
                send({'evt': 'error', 'msg': 'VB模式文件解析失败'});
              } else {
                final n = decoded.data.length ~/ 2;
                final ptr = malloc<Float>(decoded.data.length);
                try {
                  ptr.asTypedList(decoded.data.length).setAll(0, decoded.data);
                  vb!.testStart(3,
                      pcm: ptr, frames: n, ch: 2, rate: decoded.sampleRate);
                } finally {
                  malloc.free(ptr);
                }
              }
            } else if (tk != 0) {
              vb!.testStart(tk);
            }
            send({'evt': 'playing', 'playing': true});
            break;
          }
          if (vbActive && vb != null && kind == 'stop') {
            vb!.testStop();
          }
          // ASIO 模式：测试源走桥注入（自动静音驱动输入），isolate 本地 source
          // 保持空——此前缺这支，ASIO 下点试音只有 playing 显示没有声。
          if (asioActive && ab != null && kind != 'stop') {
            final tk = kind == 'tone'
                ? 1
                : kind == 'pink'
                    ? 2
                    : kind == 'file'
                        ? 3
                        : 0;
            if (tk == 3) {
              final fpath = m['path'] as String;
              final lb = lib;
              final decoded = fpath.toLowerCase().endsWith('.mp3')
                  ? (lb == null ? null : decodeMp3File(lb, fpath))
                  : decodeWavFile(fpath);
              if (decoded == null) {
                send({'evt': 'error', 'msg': 'ASIO模式文件解析失败'});
              } else {
                final n = decoded.data.length ~/ 2;
                final ptr = malloc<Float>(decoded.data.length);
                try {
                  ptr.asTypedList(decoded.data.length).setAll(0, decoded.data);
                  ab!.testStart(3,
                      pcm: ptr, frames: n, ch: 2, rate: decoded.sampleRate);
                } finally {
                  malloc.free(ptr);
                }
              }
            } else if (tk != 0) {
              ab!.testStart(tk);
            }
            send({'evt': 'playing', 'playing': true});
            break;
          }
          if (asioActive && ab != null && kind == 'stop') {
            ab!.testStop();
          }
          // AuraVAIO 模式：测试源走桥注入
          if (vaioActive && vaio != null && kind != 'stop') {
            final tk = kind == 'tone'
                ? 1
                : kind == 'pink'
                    ? 2
                    : kind == 'file'
                        ? 3
                        : 0;
            if (tk == 3) {
              final fpath = m['path'] as String;
              final lb = lib;
              final decoded = fpath.toLowerCase().endsWith('.mp3')
                  ? (lb == null ? null : decodeMp3File(lb, fpath))
                  : decodeWavFile(fpath);
              if (decoded == null) {
                send({'evt': 'error', 'msg': 'VAIO模式文件解析失败'});
              } else {
                final n = decoded.data.length ~/ 2;
                final ptr = malloc<Float>(decoded.data.length);
                try {
                  ptr.asTypedList(decoded.data.length).setAll(0, decoded.data);
                  vaio!.testStart(3,
                      pcm: ptr, frames: n, ch: 2, rate: decoded.sampleRate);
                } finally {
                  malloc.free(ptr);
                }
              }
            } else if (tk != 0) {
              vaio!.testStart(tk);
            }
            send({'evt': 'playing', 'playing': true});
            break;
          }
          if (vaioActive && vaio != null && kind == 'stop') {
            vaio!.testStop();
          }
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
              final fpath = m['path'] as String;
              if (fpath.toLowerCase().endsWith('.mp3')) {
                if (lib == null) {
                  send({'evt': 'error', 'msg': 'MP3 解码需要引擎在线'});
                } else {
                  final mp = decodeMp3File(lib, fpath);
                  if (mp == null) {
                    send({'evt': 'error', 'msg': 'MP3 解析失败（文件损坏/不支持或超 64MB 上限）'});
                  } else {
                    source = FileSource(mp.data, mp.sampleRate);
                  }
                }
              } else {
                final w = decodeWavFile(fpath);
                if (w == null) {
                  send({'evt': 'error', 'msg': 'WAV 解析失败（仅支持 PCM 16/24/32 与 float32）'});
                } else {
                  source = FileSource(w.data, w.sampleRate);
                }
              }
              break;
          }
          send({'evt': 'playing', 'playing': source != null});
          break;
        case 'vbmode':
          if (m['on'] as bool) {
            if (asioActive) stopAsioBridge();
            if (vaioActive) stopVaioBridge();
            startVbBridge();
          } else {
            stopVbBridge();
          }
          break;
        case 'asiomode':
          if (m['on'] as bool) {
            // VB 与 ASIO 互斥：切 ASIO 前先停 VB（主 isolate 的 setAudioMode
            // 已保证一次只选一个模式，这里防御性再压一遍）。
            if (vbActive) stopVbBridge();
            if (vaioActive) stopVaioBridge();
            startAsioBridge(
              driver: (m['driver'] as String?) ?? '',
              bufSize: (m['bufSize'] as num?)?.toInt() ?? 0,
              outPair: (m['outPair'] as num?)?.toInt() ?? 0,
            );
          } else {
            stopAsioBridge();
          }
          break;
        case 'asiorestart':
          // 驱动/缓冲/声道对变更：热切换（stop → start 新参数）。
          if (!asioActive) break;
          stopAsioBridge();
          startAsioBridge(
            driver: (m['driver'] as String?) ?? '',
            bufSize: (m['bufSize'] as num?)?.toInt() ?? 0,
            outPair: (m['outPair'] as num?)?.toInt() ?? 0,
          );
          break;
        case 'asiodetect':
          detectAsioDrivers();
          break;
        case 'vaiomode':
          if (m['on'] as bool) {
            if (vbActive) stopVbBridge();
            if (asioActive) stopAsioBridge();
            startVaioBridge(
              outputEndpointSubstr: (m['outputEndpoint'] as String?) ?? '',
            );
          } else {
            stopVaioBridge();
          }
          break;
        case 'vaiorestart':
          if (!vaioActive) break;
          stopVaioBridge();
          startVaioBridge(
            outputEndpointSubstr: (m['outputEndpoint'] as String?) ?? '',
          );
          break;
        case 'vaiodetect':
          detectVaio();
          break;
        case 'bypass':
          bypass = m['value'] as bool;
          if (vbActive && vb != null) {
            vb!.setBypass(bypass);
          }
          if (asioActive && ab != null) {
            ab!.setBypass(bypass);
          }
          if (vaioActive && vaio != null) {
            vaio!.setBypass(bypass);
          }
          break;
        case 'setBusMask':
          vbBusMask = (m['mask'] as int) & 0xFF;
          if (vbActive && vb != null) {
            vb!.setBusMask(vbBusMask);
          }
          break;
        case 'pluginScan':
          {
            if (lib != null && handle != null) {
              final dirs = (m['dirs'] as List?)?.map((e) => e.toString()).toList();
              final dir = (m['dir'] as String?) ?? '';
              final deep = (m['deep'] as bool?) ?? false;
              final scanDir = (dirs != null && dirs.isNotEmpty) ? dirs.join(';') : dir;
              // C2：分块扫描是异步的——本 case 在同步消息循环里（不能 await），
              // 故以 fire-and-forget 启动，扫描在事件循环里与音频泵交替推进，
              // 进度与完成都以事件回传（对外契约与同步路径一致）。
              _scanChunked(
                lib: lib,
                handle: handle,
                dir: scanDir,
                deep: deep,
                send: send,
              );
            }
            break;
          }
        case 'pluginGetAll':
          {
            if (lib != null && handle != null) {
              final allJson = AuraDspLib.pluginGetAllJson(lib, handle);
              send({
                'evt': 'pluginList',
                'json': allJson,
              });
            }
            break;
          }
        case 'pluginLoad':
          {
            if (lib != null && handle != null) {
              final path = m['path'] as String;
              final id = (m['id'] as String?) ?? '';
              final rc = AuraDspLib.pluginLoadWrap(lib, handle, path, id: id);
              final statusJson = AuraDspLib.pluginGetStatusJson(lib, handle);
              send({
                'evt': 'pluginLoaded',
                'path': path,
                'rc': rc,
                'status': statusJson,
              });
            }
            break;
          }
        case 'pluginUnload':
          {
            if (lib != null && handle != null) {
              final rc = AuraDspLib.pluginUnloadWrap(lib, handle);
              final statusJson = AuraDspLib.pluginGetStatusJson(lib, handle);
              send({
                'evt': 'pluginUnloaded',
                'rc': rc,
                'status': statusJson,
              });
            }
            break;
          }
        case 'pluginSetBypass':
          {
            if (lib != null && handle != null) {
              final bypassVal = m['bypass'] as bool;
              final rc = AuraDspLib.pluginSetBypassWrap(lib, handle, bypassVal);
              final statusJson = AuraDspLib.pluginGetStatusJson(lib, handle);
              send({
                'evt': 'pluginBypass',
                'bypass': bypassVal,
                'rc': rc,
                'status': statusJson,
              });
            }
            break;
          }
        case 'pluginGetStatus':
          {
            if (lib != null && handle != null) {
              final statusJson = AuraDspLib.pluginGetStatusJson(lib, handle);
              send({
                'evt': 'pluginStatus',
                'status': statusJson,
              });
            }
            break;
          }
        case 'pluginSlotLoad':
          {
            if (lib != null && handle != null) {
              final slot = (m['slot'] as num?)?.toInt() ?? 0;
              _slotLoadAsync(lib, handle, slot, m['path'] as String,
                  (m['id'] as String?) ?? '', send);
            }
            break;
          }
        case 'pluginSlotUnload':
          {
            if (lib != null && handle != null) {
              final slot = (m['slot'] as num?)?.toInt() ?? 0;
              _slotUnloadAsync(lib, handle, slot, send);
            }
            break;
          }
        case 'pluginSlotSetBypass':
          {
            if (lib != null && handle != null) {
              final slot = (m['slot'] as num?)?.toInt() ?? 0;
              final bypassVal = m['bypass'] as bool;
              final rc = AuraDspLib.pluginSlotSetBypassWrap(lib, handle, slot, bypassVal);
              final statusJson = AuraDspLib.pluginSlotGetStatusJson(lib, handle, slot);
              send({
                'evt': 'pluginSlotBypass',
                'slot': slot,
                'bypass': bypassVal,
                'rc': rc,
                'status': statusJson,
              });
            }
            break;
          }
        case 'pluginSlotGetStatus':
          {
            if (lib != null && handle != null) {
              final slot = (m['slot'] as num?)?.toInt() ?? 0;
              final statusJson = AuraDspLib.pluginSlotGetStatusJson(lib, handle, slot);
              final stage = AuraDspLib.pluginSlotGetInsertStageWrap(lib, handle, slot);
              send({
                'evt': 'pluginSlotStatus',
                'slot': slot,
                'status': statusJson,
                'stage': stage,
              });
            }
            break;
          }
        case 'pluginSlotShowEditor':
          {
            if (lib != null && handle != null) {
              final slot = (m['slot'] as num?)?.toInt() ?? 0;
              final title = (m['title'] as String?) ?? '';
              final rc = AuraDspLib.pluginSlotShowEditorWrap(lib, handle, slot, title: title);
              send({
                'evt': 'pluginSlotEditorResult',
                'slot': slot,
                'action': 'show',
                'rc': rc,
              });
            }
            break;
          }
        case 'pluginSlotCloseEditor':
          {
            if (lib != null && handle != null) {
              final slot = (m['slot'] as num?)?.toInt() ?? 0;
              final rc = AuraDspLib.pluginSlotCloseEditorWrap(lib, handle, slot);
              send({
                'evt': 'pluginSlotEditorResult',
                'slot': slot,
                'action': 'close',
                'rc': rc,
              });
            }
            break;
          }
        case 'pluginSlotSavePreset':
          {
            if (lib != null && handle != null) {
              final slot = (m['slot'] as num?)?.toInt() ?? 0;
              final path = m['path'] as String;
              final rc = AuraDspLib.pluginSlotSavePresetWrap(lib, handle, slot, path);
              send({
                'evt': 'pluginSlotPresetSaved',
                'slot': slot,
                'path': path,
                'rc': rc,
              });
            }
            break;
          }
        case 'pluginSlotLoadPreset':
          {
            if (lib != null && handle != null) {
              final slot = (m['slot'] as num?)?.toInt() ?? 0;
              final path = m['path'] as String;
              final rc = AuraDspLib.pluginSlotLoadPresetWrap(lib, handle, slot, path);
              final statusJson = AuraDspLib.pluginSlotGetStatusJson(lib, handle, slot);
              send({
                'evt': 'pluginSlotPresetLoaded',
                'slot': slot,
                'path': path,
                'rc': rc,
                'status': statusJson,
              });
            }
            break;
          }
        case 'pluginSlotSetInsertStage':
          {
            if (lib != null && handle != null) {
              final slot = (m['slot'] as num?)?.toInt() ?? 0;
              final stage = (m['stage'] as num).toInt();
              final rc = AuraDspLib.pluginSlotSetInsertStageWrap(lib, handle, slot, stage);
              send({
                'evt': 'pluginSlotInsertStage',
                'slot': slot,
                'stage': stage,
                'rc': rc,
              });
            }
            break;
          }
        case 'pluginSlotGetInsertStage':
          {
            if (lib != null && handle != null) {
              final slot = (m['slot'] as num?)?.toInt() ?? 0;
              final stage = AuraDspLib.pluginSlotGetInsertStageWrap(lib, handle, slot);
              send({
                'evt': 'pluginSlotInsertStage',
                'slot': slot,
                'stage': stage,
                'rc': 1,
              });
            }
            break;
          }
        case 'shutdown':
          running = false;
          break;
        case 'probeComponentLatency':
          {
            // D11：真实脉冲响应测量。引擎侧自建一次性探针 handle，不触碰正在
            // 放音的 handle（两个 handle 可安全共存，见 tools/probe_concurrent.py）。
            // 代价：每次约数十毫秒，故只在用户显式点击时触发，绝不进音频路径。
            final comp = (m['comp'] as String?) ?? '';
            final l = lib;
            final rate = wasapi?.mix.sampleRate.toDouble() ?? 48000.0;
            if (l == null || comp.isEmpty) {
              send({
                'evt': 'componentLatency',
                'comp': comp,
                'rc': -2,
                'samples': 0,
              });
              break;
            }
            final out = malloc<Uint32>();
            final compPtr = comp.toNativeUtf8();
            int rc;
            try {
              out.value = 0;
              // convolver / ddc 需要外部资源才能在探针内就绪；有路径时走
              // 带资源探针，才是真正的「实测」而非「不可测」。
              final resPath = (m['resource'] as String?) ?? '';
              if (resPath.isEmpty) {
                rc = l.probeComponent(compPtr, rate, out);
              } else {
                final p = resPath.toNativeUtf8();
                try {
                  rc = l.probeComponentWithResource(compPtr, p, rate, out);
                } finally {
                  malloc.free(p);
                }
              }
              send({
                'evt': 'componentLatency',
                'comp': comp,
                'rc': rc,
                'samples': rc == 0 ? out.value.toInt() : 0,
              });
            } finally {
              malloc.free(compPtr);
              malloc.free(out);
            }
            break;
          }
      }
    } catch (e) {
      send({'evt': 'error', 'msg': e.toString()});
    }
  });
  send({'evt': 'isoReady', 'port': fromMain.sendPort});

  /* ---- 引擎 + WASAPI 初始化 ---- */
  // WASAPI 输出是"可选的"：默认端点被独占/幽灵时不再红屏，降级就绪——引擎照跑
  // （参数/viz/插件全活），VB/ASIO 桥完全不受影响；进程内试音在用户修好设备
  // 后点"重试"（= _restartIsolate）恢复。fatal 只留给 DLL 缺失/引擎建不出。
  try {
    lib = AuraDspLib.load();
    dbgLog('engine dll loaded');
    String? wasapiError;
    try {
      wasapi = WasapiOut()
        ..init(requestedSampleRate: requestedRate > 0 ? requestedRate : null);
    } catch (e) {
      wasapi = null;
      wasapiError = e.toString();
      dbgLog('WASAPI unavailable, degraded ready: $wasapiError');
    }
    // 无输出设备时按请求速率建引擎（有设备则跟设备协商值）。
    final engineRate = wasapi != null
        ? wasapi.mix.sampleRate.toDouble()
        : (requestedRate > 0
            ? requestedRate.toDouble()
            : kFallbackSampleRate.toDouble());
    handle = lib.create(engineRate, maxBlockFrames);
    dbgLog('auradsp_create rate=$engineRate '
        'maxBlock=$maxBlockFrames '
        'handle=${handle == nullptr ? "NULL" : "ok"}');
    if (handle == nullptr) throw StateError('auradsp_create returned null');
    // FileGate 资源上限来自 config（此前引擎写死 256MiB / 16M 帧）
    AuraDspLib.setValue(lib, handle, 'gate.maxIrSeconds',
        isFloat: true, value: maxIrSeconds);
    AuraDspLib.setValue(lib, handle, 'gate.maxFileMb',
        isFloat: true, value: maxFileMb);
    if (vizFftSize != kVizFftSizeDefault) {
      AuraDspLib.setValue(lib, handle, 'viz.fftSize',
          isFloat: false, value: vizFftSize.toDouble());
    }
    wasapi?.start();
    if (wasapi != null) {
      dbgLog('WASAPI started, latency=${lib.getLatencyMs(handle)}ms');
    }
    lastSentState = lib.getState(handle);
    lastSentLatency = lib.getLatencyMs(handle);
    send({
      'evt': 'ready',
      'abi': lib.abi(),
      'version': lib.version().toDartString(),
      // 无输出设备时 deviceRate=0，UI 据此展示降级态而非红屏。
      'deviceRate': wasapi?.mix.sampleRate ?? 0,
      'deviceCh': wasapi?.mix.channels ?? 0,
      'bufferFrames': wasapi?.bufferFrames ?? 0,
      'latencyMs': lib.getLatencyMs(handle),
    });
    if (wasapiError != null) {
      send({'evt': 'wasapiError', 'msg': wasapiError});
    }
    final initialPluginStatus = AuraDspLib.pluginGetStatusJson(lib, handle);
    send({'evt': 'pluginStatus', 'status': initialPluginStatus});
  } catch (e) {
    send({'evt': 'fatal', 'msg': e.toString()});
    return;
  }

  /* ---- 渲染循环（shared 轮询推） ---- */
  final maxBlock = maxBlockFrames; // 必须 ≤ auradsp_create 的 max_block_frames 契约
  final srcPtr = malloc<Float>(maxBlock * 2);
  final srcBuf = srcPtr.asTypedList(maxBlock * 2);
  final outPtrEng = malloc<Float>(maxBlock * 2);
  final engOut = outPtrEng.asTypedList(maxBlock * 2);
  final vizBuf = malloc<VizFrame>(8); // 持久化复用，零运行时堆分配
  String? lastPumpErr;
  var lastPumpErrAt = 0;
  // WASAPI 端点被占计数（0x8889000a = AUDCLNT_E_DEVICE_IN_USE：端点被独占，
  // 典型是 VB 以独占/KS 方式开着同一设备。旧 client 在独占释放前永好不了，
  // 必须等对端释放后重建链路）。
  // 连续 ~2s（400 轮）即上报一次（latch，不反复刷）；model 侧重启 isolate。
  var wasapiErrRounds = 0;
  var pumpRounds = 0;
  var procRounds = 0;
  // 桥 viz 断流守卫（VB/ASIO 共用口径，各自独立计时）：桥引擎停产（VB 退出/
  // 暂停无声/组 idle）时 vizRead 持续 null，之前是什么都不发，UI 永冻在最后一
  // 帧。超 1.5s 无新帧：补一帧全零让频谱/电平回落（只补一次，活数据即恢复）。
  int vbStaleSince = 0;
  bool vbStaleSent = false;
  int asioStaleSince = 0;
  bool asioStaleSent = false;
  int vaioStaleSince = 0;
  bool vaioStaleSent = false;
  void sendStaleViz(String backend, int now) {
    send({
      'evt': 'viz',
      'backend': backend,
      'spectrum': List<double>.filled(lastSpectrumLen, 0.0),
      'eqIn': List<double>.filled(lastSpectrumLen, 0.0),
      'l': -90.0,
      'r': -90.0,
      'stageL': List<double>.filled(lastStageLen, -90.0),
      'stageR': List<double>.filled(lastStageLen, -90.0),
      'ts': now,
      'seq': -2,
    });
  }
  Future<void> pump() async {
    dbgLog('pump loop start');
    while (running) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      pumpRounds++;
      // ASIO 模式：WASAPI 泵暂停（设备已 stop），可视化与状态走 04 桥。
      if (asioActive && ab != null) {
        try {
          final now = DateTime.now().millisecondsSinceEpoch;
          if (lastViz == null || now - lastViz! >= vizIntervalMs) {
            lastViz = now;
            final v = ab!.vizRead();
            if (v != null) {
              asioStaleSince = 0;
              asioStaleSent = false;
              v['backend'] = 'asio';
              send({'evt': 'viz', ...v});
              if (!vbVizOkLogged) {
                vbVizOkLogged = true;
                dbgLog('asiomode: viz flowing l=${v['l']} r=${v['r']}');
              }
            } else {
              if (!vbVizNullLogged) {
                vbVizNullLogged = true;
                dbgLog('asiomode: first null viz');
              }
              if (asioStaleSince == 0) asioStaleSince = now;
              if (!asioStaleSent && now - asioStaleSince > 1500) {
                asioStaleSent = true;
                sendStaleViz('asio', now);
              }
            }
            // 启动 5s 后仍无回调帧：驱动 RT 线程没在跑（对照 status 的 switches）。
            if (!vbNoCbLogged && now - vbStatusAt > 5000) {
              vbNoCbLogged = true;
              final st0 = ab!.status();
              dbgLog('asiomode: t+5s switches=${st0?['switches']} '
                  'sr=${st0?['sr']} nbs=${st0?['nbs']} '
                  'peakIn=${st0?['peakIn']} peakOut=${st0?['peakOut']} '
                  'bypass=${st0?['bypass']} note=${st0?['note']}');
            }
          }
          vbStatusTick++;
          if (vbStatusTick % 200 == 0) {
            final st = ab!.status();
            if (st != null) {
              send({
                'evt': 'asiostatus',
                ...st,
                'driverInUse': asioDriverInUse,
              });
            }
          }
        } catch (_) {}
        continue;
      }
      // VB 模式：WASAPI 泵暂停（设备已 stop），可视化与状态走桥。
      if (vbActive && vb != null) {
        try {
          final now = DateTime.now().millisecondsSinceEpoch;
          if (lastViz == null || now - lastViz! >= vizIntervalMs) {
            lastViz = now;
            final v = vb!.vizRead();
            if (v != null) {
              vbStaleSince = 0;
              vbStaleSent = false;
              v['backend'] = 'vb';
              send({'evt': 'viz', ...v});
              if (!vbVizOkLogged) {
                vbVizOkLogged = true;
                dbgLog('vbmode: viz flowing l=${v['l']} r=${v['r']}');
              }
            } else {
              if (!vbVizNullLogged) {
                // 首个空 viz 记一笔（桥 handle 未就绪或对端静默的早期信号）。
                vbVizNullLogged = true;
                dbgLog('vbmode: first null viz');
              }
              if (vbStaleSince == 0) vbStaleSince = now;
              if (!vbStaleSent && now - vbStaleSince > 1500) {
                vbStaleSent = true;
                sendStaleViz('vb', now);
              }
            }
            // 启动 5s 后仍无回调帧：路由/引擎二选一，看同周期 status 的 frames/handles。
            if (!vbNoCbLogged &&
                now - vbStatusAt > 5000) {
              vbNoCbLogged = true;
              final st0 = vb!.status();
              dbgLog('vbmode: t+5s handles=${st0?['handles']} '
                  'frames=${st0?['frames']} peakIn=${st0?['peakIn']} '
                  'vizGrp=${st0?['vizGrp']} '
                  'testKind=${st0?['testKind']} bypass=${st0?['bypass']} '
                  'note=${st0?['note']}');
            }
          }
          vbStatusTick++;
          if (vbStatusTick % 200 == 0) {
            final st = vb!.status();
            if (st != null) send({'evt': 'vbstatus', ...st});
          }
        } catch (_) {}
        continue;
      }
      // AuraVAIO 模式：WASAPI 泵暂停（设备已 stop），可视化与状态走 01 桥。
      if (vaioActive && vaio != null) {
        try {
          final now = DateTime.now().millisecondsSinceEpoch;
          if (lastViz == null || now - lastViz! >= vizIntervalMs) {
            lastViz = now;
            final v = vaio!.vizRead();
            if (v != null) {
              vaioStaleSince = 0;
              vaioStaleSent = false;
              v['backend'] = 'vaio';
              send({'evt': 'viz', ...v});
              if (!vaioVizOkLogged) {
                vaioVizOkLogged = true;
                dbgLog('vaiomode: viz flowing l=${v['l']} r=${v['r']}');
              }
            } else {
              if (!vaioVizNullLogged) {
                vaioVizNullLogged = true;
                dbgLog('vaiomode: first null viz');
              }
              if (vaioStaleSince == 0) vaioStaleSince = now;
              if (!vaioStaleSent && now - vaioStaleSince > 1500) {
                vaioStaleSent = true;
                sendStaleViz('vaio', now);
              }
            }
            if (!vaioNoCbLogged && now - vaioStatusAt > 5000) {
              vaioNoCbLogged = true;
              final st0 = vaio!.status();
              dbgLog('vaiomode: t+5s frames=${st0?['frames']} '
                  'sr=${st0?['sr']} peakIn=${st0?['peakIn']} '
                  'peakOut=${st0?['peakOut']} bypass=${st0?['bypass']} '
                  'note=${st0?['note']}');
            }
          }
          vaioStatusTick++;
          if (vaioStatusTick % 200 == 0) {
            final st = vaio!.status();
            if (st != null) {
              send({
                'evt': 'vaiostatus',
                ...st,
                'outputEndpoint': vaioOutputEndpointInUse,
              });
            }
          }
        } catch (_) {}
        continue;
      }
      try {
        final w = wasapi;
        if (w == null) {
          // 无输出设备（降级就绪）：引擎照跑、viz 照发，只是不渲染；
          // 界面由 wasapiError 事件展示原因 + 重试。
          idleRounds++;
          if (idleRounds >= idleVizRounds) sendIdleViz();
          continue;
        }
        final padding = w.getCurrentPaddingNow();
        final avail = w.bufferFrames - padding;
        if (avail <= 0 || source == null) {
          idleRounds++;
          if (idleRounds >= idleVizRounds) sendIdleViz();
          continue;
        }
        idleRounds = 0;
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
            final n = lib!.vizRead(handle!, vizBuf, 8);
            if (n > 0) {
              final fr = (vizBuf + (n - 1)).ref;
              vizCount++;
              idleVizSent = false;
              final sp = fr.spectrumToList();
              final eqIn = fr.eqInSpectrumToList();
              final stageL = fr.stageLevelsLToList();
              lastSpectrumLen = sp.length;
              lastStageLen = stageL.length;
              if (vizCount <= 5 || vizCount % 100 == 0) {
                dbgLog('viz#$vizCount n=$n seq=${fr.seq} '
                    'max=${sp.reduce(math.max).toStringAsFixed(3)} '
                    'l=${fr.levelLDbfs.toStringAsFixed(1)} '
                    'r=${fr.levelRDbfs.toStringAsFixed(1)}');
              }
              send({
                'evt': 'viz',
                'spectrum': sp,
                'eqIn': eqIn,
                'l': fr.levelLDbfs,
                'r': fr.levelRDbfs,
                'stageL': stageL,
                'stageR': fr.stageLevelsRToList(),
                'inputInL': fr.inputLevelInL,
                'inputInR': fr.inputLevelInR,
                'inputOutL': fr.inputLevelOutL,
                'inputOutR': fr.inputLevelOutR,
                'ts': fr.timestampMs,
                'seq': fr.seq,
              });
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
        // 端点死亡（只认 0x8889000a，其它错误走上面的常规上报，不触发重启）。
        if (msg.contains('0x8889000a')) {
          wasapiErrRounds++;
        } else {
          wasapiErrRounds = 0;
        }
        if (wasapiErrRounds >= 400) {
          wasapiErrRounds = -1000000; // latch：旧 client 已死，不可能自愈
          dbgLog('PUMP: device invalidated 2s+, reporting wasapiLost');
          send({'evt': 'wasapiLost'});
        }
      }
    }
    // 收尾
    try {
      if (vbActive) {
        try {
          vb?.testStop();
        } catch (_) {}
        try {
          vb?.stop();
        } catch (_) {}
        vbActive = false;
      }
      if (asioActive) {
        try {
          ab?.testStop();
        } catch (_) {}
        try {
          ab?.stop();
        } catch (_) {}
        asioActive = false;
      }
      if (vaioActive) {
        try {
          vaio?.testStop();
        } catch (_) {}
        try {
          vaio?.stop();
        } catch (_) {}
        vaioActive = false;
      }
      wasapi?.stop();
      if (handle != null) lib?.destroy(handle);
      malloc.free(srcPtr);
      malloc.free(outPtrEng);
      malloc.free(vizBuf);
    } catch (_) {}
  }

  unawaited(pump());
}

