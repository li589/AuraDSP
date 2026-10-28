// part of state.dart —— P2 按区拆分，extension 包装零逻辑改动。
part of '../state.dart';

/// 引擎命令原语 + 强类型参数访问 + 乐观镜像 + isolate 生命周期。
///
/// 方法体逐字保留自 AppModel 类体；extension 成员与类内成员同库作用域，
/// 原有调用点（实例调用、tear-off、跨 part 互调）解析不变。
extension StateCore on AppModel {
  void send(Map<String, dynamic> m) {
    // [PATCHED-AuraDSP P-032] testing 模式记录已下发的 setParam 载荷。
    // 此前"参数有没有真的发到引擎"无法在单测里断言（_toIso 为 null 时
    // send 静默丢弃）——P-032 的三处修复（bass.mode 下发、freeverb
    // roomsize/width 下发）正属此类"下发了才算数"的缺陷，需要可观测。
    if (_testing && m['cmd'] == 'setParam') {
      sentParamsForTesting.add(Map<String, dynamic>.from(m));
    }
    _toIso?.send(m);
  }

  // ---- 命令下发 ----

  void setInt(String id, int v) {
    if (id == 'channels.mode') {
      // X-8：引擎 channels.mode 仅接受 0..1，下发前先 clamp，防非法值下发与淤积
      v = v.clamp(0, 1);
    } else if (id == 'channels.countMode') {
      v = v.clamp(0, 1);
    }
    _mirror(id, v.toDouble());
    _markSent(id);
    _notifyUi();
    if (id == 'gate.enable' && v == 0) {
      if (deesserOn) {
        setDeesserEnabled(false);
      }
    }
    send({'cmd': 'setParam', 'id': id, 'value': v, 'isFloat': false});
    scheduleAutoSave();
  }

  void setFloat(String id, double v) {
    _mirror(id, v);
    _markSent(id);
    _notifyUi();
    send({'cmd': 'setParam', 'id': id, 'value': v, 'isFloat': true});
    scheduleAutoSave();
  }

  void setStringParam(String id, String text) {
    send({'cmd': 'setParamStr', 'id': id, 'text': text});
    scheduleAutoSave();
  }

  // ---- 强类型参数访问 ----

  /// 强类型通用参数读取
  ///
  /// 2026-10-19 修复：**getter（model 字段）是唯一真相**。旧实现先查
  /// `_paramValues` 自填充缓存——但会话恢复（PresetLibrary.postApply）、
  /// readback 对账、resetStereoBand 等路径全是**字段直写**，不经过缓存，
  /// 于是 UI（ParamSlider→getParam）在字段已更新后仍读到陈旧缓存值
  /// （用户实测：立体声分带滑块显示 0%，而"归位默认"按钮走 setParam
  /// 恰好同步刷缓存才显示正确——同一数值两条显示链路互相打架）。
  /// 缓存仅保留镜像写入（供 getParamById 未注册回退与诊断），不再参与读取。
  T getParam<T>(ParamSpec<T> spec) {
    final current = spec.read(this);
    _paramValues[spec.id] = current;
    return current;
  }

  /// 强类型通用参数设值
  void setParam<T>(ParamSpec<T> spec, T value, {bool notify = true}) {
    final clamped = spec.clamp(value);
    _paramValues[spec.id] = clamped;
    spec.write(this, clamped);
    if (notify) _notifyUi();
  }

  /// 按参数 ID 通用读取
  dynamic getParamById(String id) {
    final spec = ParamRegistry.byId[id];
    if (spec != null) return getParam(spec);
    return _paramValues[id];
  }

  /// B-3（B1）：未建模的镜像型参数读取（channels spec.getter 用）。
  /// 引擎为唯一真相；所有写路径（setInt/preset/session）都同步 _paramValues。
  int mirrorInt(String id, int fallback) {
    final v = _paramValues[id];
    if (v is int) return v;
    if (v is num) return v.toInt();
    return fallback;
  }

  /// 浮点镜像型参数读取（未在 ParamRegistry 单独建模的逐声道补偿等用）
  double mirrorFloat(String id, double fallback) {
    final v = _paramValues[id];
    if (v is double) return v;
    if (v is num) return v.toDouble();
    return fallback;
  }

  /// 按参数 ID 通用设值
  void setParamById(String id, dynamic value, {bool notify = true}) {
    final spec = ParamRegistry.byId[id];
    if (spec != null) {
      setParam(spec, spec.cast(value), notify: notify);
    } else {
      _paramValues[id] = value;
      if (value is num) {
        setFloat(id, value.toDouble());
      } else if (value is bool) {
        setInt(id, value ? 1 : 0);
      } else if (value is String) {
        send({'cmd': 'setParamStr', 'id': id, 'text': value});
      }
      if (notify) _notifyUi();
    }
  }

  /// 检查某处理节是否处于激活状态（用于自绑定组件 enabled 联动）
  bool isSectionEnabled(String section) {
    if (section == 'input' || section == 'routing') return true;
    if (section == 'post') return true;
    if (section == 'shelf') return shelfOn;
    if (section == 'bassmono') return bassmonoOn;
    if (section == 'bass_shaping') return bassShapingOn;
    return isStageEnabled(section);
  }

  void _markSent(String id) {
    _pendingSentAt[id] = DateTime.now().millisecondsSinceEpoch;
  }

  // ---- 乐观镜像 ----

  /// 乐观镜像；被守卫拒绝时由 EventBanner 明示，引擎 params/state 纠正
  void _mirror(String id, double v) {
    _paramValues[id] = v;
    switch (id) {
      case 'bass.enable':
        bassOn = v != 0;
        break;
      case 'bass.gain':
        bassGain = v;
        break;
      case 'reverb.preset':
        final p = v.toInt();
        reverbPreset = (p == 0) ? kReverbCuratedPresets.first : p;
        break;
      case 'reverb.predelay':
        reverbPredelay = v;
        break;
      case 'reverb.lfe':
        reverbLfe = v != 0;
        break;
      case 'reverb.engine':
        reverbEngine = v.toInt();
        break;
      case 'stereo.mix':
        // UI 刻度 0..1 → 存显示值；引擎侧收到 v * stereoWidenMax
        stereoMix = (v / stereoWidenMax).clamp(0.0, 1.0);
        // 总滑块语义 = 回统一模式（引擎侧同时清 vendor bandMixUsed），
        // UI 镜像必须同步清，否则会一直显示"分带生效中"而造成与主滑块冲突
        stereoBandUsed = false;
        break;
      case 'eq.enable':
        eqOn = v != 0;
        break;
      case 'post.gain':
        postGain = v;
        break;
      case 'input.gain':
        inputGain = v;
        break;
      case 'input.balance.1':
        inputBalanceL = v;
        break;
      case 'input.balance.2':
        inputBalanceR = v;
        break;
      case 'limiter.enable':
        limiterOn = v != 0;
        break;
      case 'channels.mode':
        // 引擎只接受 0=矩阵下混 / 1=离散逐声道（set_channels_mode 拒收其它值，
        // 且 setInt 的乐观镜像不回滚）。历史 UI 曾有非法的 2（"7.1"）档位，
        // 会淤积在镜像与自动保存里——此处 clamp 保证镜像即引擎真相。
        channelsMode = v.toInt().clamp(0, 1);
        break;
      case 'channels.countMode':
        channelsCountMode = v.toInt().clamp(0, 1);
        break;
      case 'channels.count':
        final c = v.toInt();
        if (c == 2 || c == 4 || c == 6 || c == 8) {
          channelsCount = c;
        }
        break;
      case 'tube.enable':
        tubeOn = v != 0;
        break;
      case 'tube.style':
        tubeStyle = v.toInt().clamp(0, 2);
        break;
      case 'tube.mix':
        tubeMix = v.clamp(0.0, 1.0);
        break;
      case 'tube.compensation':
        tubeCompensation = v.clamp(-12.0, 12.0);
        break;
      case 'crossfeed.enable':
        xfeedOn = v != 0;
        break;
      case 'crossfeed.mode':
        xfeedMode = v.toInt();
        if (xfeedMode == 0) {
          xfeedFcut = 700.0;
          xfeedFeed = 4.5;
        } else if (xfeedMode == 1) {
          xfeedFcut = 700.0;
          xfeedFeed = 6.0;
        } else if (xfeedMode == 2) {
          xfeedFcut = 650.0;
          xfeedFeed = 9.5;
        }
        break;
      case 'crossfeed.fcut':
        xfeedFcut = v;
        break;
      case 'crossfeed.feed':
        xfeedFeed = v;
        break;
      default:
        // 注意：这里必须用 raw string 里的裸 $ 收尾。写成 r'...\$' 是
        // 反斜杠+美元，在 ECMAScript 正则里是 IdentityEscape，匹配**字面 $ 字符**，
        // 于是 'stereo.band1' 永远不匹配 → 分带镜像与 stereoBandUsed 全程失效
        // （下方 liveprog.param 同类写法即为正确示范）。
        final mb = RegExp(r'^stereo\.band([1-5])$').firstMatch(id);
        if (mb != null) {
          stereoBands[int.parse(mb.group(1)!) - 1] = v.clamp(0.0, 1.0);
          stereoBandUsed = true;
          break;
        }
        if (id == ParamId.convMix) {
          convMix = v;
          break;
        }
        if (id == ParamId.ddcEnable) {
          ddcOn = v != 0;
          break;
        }
        if (id == ParamId.ddcReady) {
          ddcReady = v != 0;
          break;
        }
        if (id == ParamId.shelfEnable) {
          shelfOn = v != 0;
          break;
        }
        if (id == ParamId.shelfFreq) {
          shelfFreq = v.clamp(40.0, 400.0);
          break;
        }
        if (id == ParamId.shelfGain) {
          shelfGain = v;
          break;
        }
        if (id == ParamId.bassmonoEnable) {
          bassmonoOn = v != 0;
          break;
        }
        if (id == ParamId.bassmonoFreq) {
          bassmonoFreq = v;
          break;
        }
        if (id == ParamId.bassmonoPairs) {
          bassmonoPairs = v.toInt().clamp(0, 15);
          break;
        }
        if (id == ParamId.bassmonoMerge) {
          bassmonoMerge = v.toInt().clamp(0, 1);
          break;
        }
        if (id == ParamId.haasEnable) {
          haasOn = v != 0;
          break;
        }
        if (id == ParamId.haasDelay) {
          haasDelayMs = v;
          break;
        }
        if (id == ParamId.haasMix) {
          haasMix = v;
          break;
        }
        if (id == ParamId.haasSide) {
          haasSide = v != 0 ? 1 : 0;
          break;
        }
        if (id == ParamId.spatialEnable) {
          spatialOn = v != 0;
          break;
        }
        if (id == ParamId.spatialStyle) {
          spatialStyle = v.toInt().clamp(0, 3);
          break;
        }
        if (id == ParamId.spatialRoom) {
          spatialRoom = (v * 10000.0).round() / 10000.0;
          break;
        }
        if (id == ParamId.spatialWidth) {
          spatialWidth = (v * 10000.0).round() / 10000.0;
          break;
        }
        if (id == ParamId.spatialCenter) {
          spatialCenter = (v * 10000.0).round() / 10000.0;
          break;
        }
        if (id == ParamId.spatialOutGain) {
          spatialOutGain = v;
          break;
        }
        if (id == ParamId.spatialAutoGain) {
          spatialAutoGain = v != 0;
          break;
        }
        if (id == ParamId.spatialMix) {
          spatialMix = v;
          break;
        }
        if (id == ParamId.spatialElevation) {
          spatialElevation = v;
          break;
        }
        if (id == ParamId.spatialBinaural) {
          spatialBinaural = v != 0;
          break;
        }
        if (id == ParamId.spatialHeadAzim) {
          spatialHeadAzim = v;
          break;
        }
        if (id == ParamId.spatialHeadTrack) {
          spatialHeadTrack = v != 0;
          break;
        }
        if (id == ParamId.exciterEnable) {
          exciterOn = v != 0;
          break;
        }
        if (id == ParamId.exciterAmount) {
          exciterAmount = v;
          break;
        }
        if (id == ParamId.exciterHifreq) {
          exciterHifreq = v;
          break;
        }
        if (id == ParamId.bassOutGain) {
          bassOutputGain = v;
          break;
        }
        if (id == ParamId.bassAutoGain) {
          bassAutoGain = v != 0;
          break;
        }
        if (id == ParamId.eqOutGain) {
          eqOutputGain = v;
          break;
        }
        if (id == ParamId.eqAutoGain) {
          eqAutoGain = v != 0;
          break;
        }
        if (id == ParamId.tubeOutGain) {
          tubeOutputGain = v;
          break;
        }
        if (id == ParamId.tubeAutoGain) {
          tubeAutoGain = v != 0;
          break;
        }
        if (id == ParamId.compOutGain) {
          compOutputGain = v;
          break;
        }
        if (id == ParamId.compAutoGain) {
          compAutoGain = v != 0;
          break;
        }
        if (id == ParamId.compMode) {
          compMode = v.toInt();
          break;
        }
        if (id == ParamId.reverbOutGain) {
          reverbOutputGain = v;
          break;
        }
        if (id == ParamId.reverbAutoGain) {
          reverbAutoGain = v != 0;
          break;
        }
        if (id == ParamId.gateEnable) {
          gateOn = v != 0;
          break;
        }
        if (id == ParamId.gateThreshold) {
          gateThreshold = v;
          break;
        }
        if (id == ParamId.gateAttack) {
          gateAttackMs = v;
          break;
        }
        if (id == ParamId.gateRelease) {
          gateReleaseMs = v;
          break;
        }
        if (id == ParamId.gateAutoGain) {
          gateAutoGain = v != 0;
          break;
        }
        if (id == ParamId.deesserEnable) {
          deesserOn = v != 0;
          break;
        }
        if (id == ParamId.deesserFreq) {
          deesserFreq = v;
          break;
        }
        if (id == ParamId.loudnessEnable) {
          loudnessOn = v != 0;
          break;
        }
        if (id == ParamId.loudnessAmount) {
          loudnessAmount = v;
          break;
        }
        if (id == ParamId.bassHarmonics) {
          bassHarmonics = v;
          break;
        }
        if (id == ParamId.bassHarmonicBlend) {
          bassHarmonicBlend = v;
          break;
        }
        if (id == ParamId.bassSubFreq) {
          bassSubFloor = v;
          break;
        }
        if (id == ParamId.bassCutoffF) {
          bassCutoff = v;
          break;
        }
        if (id == ParamId.filterEnable) {
          filterOn = v != 0;
          break;
        }
        if (id == ParamId.filterType) {
          filterType = v.toInt().clamp(0, 2);
          break;
        }
        if (id == ParamId.filterFreq) {
          filterFreq = v;
          break;
        }
        if (id == ParamId.filterQ) {
          filterQ = v;
          break;
        }
        if (id == ParamId.deesserAmount) {
          deesserAmount = v;
          break;
        }
        if (id == ParamId.dyneqEnable) {
          dyneqOn = v != 0;
          break;
        }
        if (id == ParamId.dyneqAttack) {
          dyneqAttackMs = v;
          break;
        }
        if (id == ParamId.dyneqRelease) {
          dyneqReleaseMs = v;
          break;
        }
        if (id == ParamId.dyneqLowEnable) {
          dyneqLowOn = v != 0;
          break;
        }
        if (id == ParamId.dyneqLowFreq) {
          dyneqLowFreq = v;
          break;
        }
        if (id == ParamId.dyneqLowQ) {
          dyneqLowQ = v;
          break;
        }
        if (id == ParamId.dyneqLowGain) {
          dyneqLowGain = v;
          break;
        }
        if (id == ParamId.dyneqLowRange) {
          dyneqLowRange = v;
          break;
        }
        if (id == ParamId.dyneqLowThreshold) {
          dyneqLowThreshold = v;
          break;
        }
        if (id == ParamId.dyneqMidEnable) {
          dyneqMidOn = v != 0;
          break;
        }
        if (id == ParamId.dyneqMidFreq) {
          dyneqMidFreq = v;
          break;
        }
        if (id == ParamId.dyneqMidQ) {
          dyneqMidQ = v;
          break;
        }
        if (id == ParamId.dyneqMidGain) {
          dyneqMidGain = v;
          break;
        }
        if (id == ParamId.dyneqMidRange) {
          dyneqMidRange = v;
          break;
        }
        if (id == ParamId.dyneqMidThreshold) {
          dyneqMidThreshold = v;
          break;
        }
        if (id == ParamId.dyneqHighEnable) {
          dyneqHighOn = v != 0;
          break;
        }
        if (id == ParamId.dyneqHighFreq) {
          dyneqHighFreq = v;
          break;
        }
        if (id == ParamId.dyneqHighQ) {
          dyneqHighQ = v;
          break;
        }
        if (id == ParamId.dyneqHighGain) {
          dyneqHighGain = v;
          break;
        }
        if (id == ParamId.dyneqHighRange) {
          dyneqHighRange = v;
          break;
        }
        if (id == ParamId.gateHysteresis) {
          gateHysteresis = v;
          break;
        }
        if (id == ParamId.gateRange) {
          gateRange = v;
          break;
        }
        if (id == ParamId.gateHoldMs) {
          gateHoldMs = v;
          break;
        }
        if (id == ParamId.exciterOversample) {
          exciterOversample = v != 0;
          break;
        }
        if (id == ParamId.tubeOversample) {
          tubeOversample = v != 0;
          break;
        }
        if (id == ParamId.limiterRelease) {
          limiterReleaseMs = v;
          break;
        }
        if (id == ParamId.limiterThreshold) {
          limiterThreshold = v;
          break;
        }
        if (id == ParamId.limiterLink) {
          limiterLink = v != 0;
          break;
        }
        if (id == ParamId.limiterLookahead) {
          limiterLookahead = v != 0;
          break;
        }
        if (id == ParamId.dyneqB1Attack) {
          dyneqB1Attack = v;
          break;
        }
        if (id == ParamId.dyneqB1Release) {
          dyneqB1Release = v;
          break;
        }
        if (id == ParamId.dyneqB2Attack) {
          dyneqB2Attack = v;
          break;
        }
        if (id == ParamId.dyneqB2Release) {
          dyneqB2Release = v;
          break;
        }
        if (id == ParamId.dyneqB3Attack) {
          dyneqB3Attack = v;
          break;
        }
        if (id == ParamId.dyneqB3Release) {
          dyneqB3Release = v;
          break;
        }
        if (id == ParamId.fvDecay) {
          fvDecay = v;
          break;
        }
        if (id == ParamId.fvDamp) {
          fvDamp = v;
          break;
        }
        if (id == ParamId.fvWet) {
          fvWet = v;
          break;
        }
        if (id == ParamId.fvDry) {
          fvDry = v;
          break;
        }
        // [PATCHED-AuraDSP P-032] 补 freeverb.roomsize / width 的镜像：
        // 这两个参数此前既没在 _mirror 里登记、也没在 selectReverbPreset
        // 里下发 → 模型字段与 _paramValues 缓存、引擎真值三者脱节。
        if (id == 'freeverb.roomsize') {
          fvRoomSize = v;
          break;
        }
        if (id == 'freeverb.width') {
          fvWidth = v;
          break;
        }
        // [PATCHED-AuraDSP P-032] bass.mode 的镜像登记（纯 UI 模式状态）。
        if (id == 'bass.mode') {
          bassMode = v.round();
          break;
        }
        if (id == ParamId.compEnable) {
          compOn = v != 0;
          break;
        }
        if (id == ParamId.compTimeconstant) {
          compTimeconstant = v;
          break;
        }
        if (id == ParamId.compGranularity) {
          compGranularity = v.toInt();
          break;
        }
        if (id == ParamId.compTfresolution) {
          compTfresolution = v.toInt();
          break;
        }
        if (id.startsWith('comp.freq')) {
          final idx = int.tryParse(id.replaceFirst('comp.freq', ''));
          if (idx != null && idx >= 1 && idx <= 7) {
            compFreqs[idx - 1] = v;
            break;
          }
        }
        if (id.startsWith('comp.gain')) {
          final idx = int.tryParse(id.replaceFirst('comp.gain', ''));
          if (idx != null && idx >= 1 && idx <= 7) {
            compGains[idx - 1] = v;
            break;
          }
        }
        if (id == ParamId.arbmagEnable) {
          arbmagOn = v != 0;
          break;
        }
        if (id == ParamId.arbmagReady) {
          arbmagReady = v != 0;
          break;
        }
        if (id == ParamId.arbmagOutGain) {
          arbmagOutputGain = v;
          break;
        }
        if (id == ParamId.arbmagAutoGain) {
          arbmagAutoGain = v != 0;
          break;
        }
        final m = RegExp(r'^liveprog\.param([1-8])$').firstMatch(id);
        if (m != null) lpParams[int.parse(m.group(1)!) - 1] = v;
    }
  }

  // ---- isolate 生命周期 ----

  void _spawn() {
    conn = EngineConn.connecting;
    _notifyUi();
    final port = ReceivePort();
    _fromIso = port;
    // 把 config 里真正被引擎消费的字段随 isolate 一起传下去。
    // 此前这些字段只被序列化到 config.json，生产代码从不读取（改配置零效果）。
    Isolate.spawn(audioIsolateMain, {
      'toMain': port.sendPort,
      'maxBlockFrames': config.maxBlockFrames,
      'vizFps': config.vizFps,
      'sampleRate': config.sampleRate,
      'vizFftSize': config.vizFftSize,
      'maxIrDurationSeconds': config.maxIrDurationSeconds,
      'maxFileSizeMb': config.maxFileSizeMb,
    }).then((iso) {
      _iso = iso;
    });
    port.listen(_onMessage);
    TrayService.instance.isWindowVisible.addListener(
      _onWindowVisibilityChanged,
    );
  }

  void _onWindowVisibilityChanged() {
    send({
      'cmd': 'setVizSuspended',
      'value': !TrayService.instance.isWindowVisible.value,
    });
  }

  @visibleForTesting
  void handleMessageForTesting(dynamic raw) => _onMessage(raw);

  void _restartIsolate() {
    final token = ++_restartToken;
    unawaited(_restartIsolateAsync(token));
  }

  Future<void> _restartIsolateAsync(int token) async {
    final oldIso = _iso;
    final oldPort = _toIso;
    final oldFrom = _fromIso;
    _iso = null;
    _toIso = null;
    _fromIso = null;
    try {
      oldFrom?.close();
    } catch (e, st) { swallow(e, st); }
    if (oldIso != null) {
      await _stopAudioIsolate(oldIso, oldPort);
    }
    if (token != _restartToken) return;
    conn = EngineConn.connecting;
    playing = false; // 就绪前不画频谱；重推音源后由 setSource 恢复
    _spawn();
  }

  Future<void> _stopAudioIsolate(Isolate iso, SendPort? port) async {
    final done = Completer<void>();
    final exitPort = ReceivePort();
    exitPort.listen((_) {
      if (!done.isCompleted) done.complete();
    });
    try {
      iso.addOnExitListener(exitPort.sendPort);
    } catch (e, st) { swallow(e, st); }
    try {
      port?.send({'cmd': 'shutdown'});
    } catch (e, st) { swallow(e, st); }
    try {
      await done.future.timeout(const Duration(milliseconds: 800));
    } catch (e, st) {
      swallow(e, st);
      try {
        iso.kill(priority: Isolate.immediate);
      } catch (e, st) { swallow(e, st); }
    } finally {
      try {
        iso.removeOnExitListener(exitPort.sendPort);
      } catch (e, st) { swallow(e, st); }
      exitPort.close();
    }
  }

  /// fatal 屏退避重启：对端独占释放前重起多少次都没用，但 VB 侧切设备/重启引擎
  /// 会顺手释放，2s 间隔探 5 次能覆盖大多数窗口；10s 还不行就留屏（用户改对端）。
  void _scheduleFatalRetry() {
    if (_fatalRetries >= 5) return;
    _fatalRetries++;
    Future.delayed(const Duration(seconds: 2), () {
      if (conn != EngineConn.ready &&
          audioMode != 'vbcallback' &&
          audioMode != 'asio') {
        _restartIsolate();
        _notifyUi();
      }
    });
  }

  /// WASAPI 输出重试（降级态用户手动触发）：本质是重启 isolate 再协商一次。
  void retryWasapi() {
    wasapiError = '';
    _fatalRetries = 0;
    _restartIsolate();
    _notifyUi();
  }

  // ---- 测试钩子 / 音源 ----

  void setSource(String kind, {String? path}) {
    sourceKind = kind == 'stop' ? '' : kind;
    sourcePath = (kind == 'file' && path != null) ? path : '';
    // 文件源记住扩展名（mp3/wav 芯片各自高亮；isolate 侧按扩展名选解码器）。
    sourceExt = '';
    if (kind == 'file' && path != null) {
      final dot = path.lastIndexOf('.');
      if (dot >= 0 && dot < path.length - 1) {
        sourceExt = path.substring(dot + 1).toLowerCase();
      }
    }
    playing = kind != 'stop';
    _notifyUi();
    send({'cmd': 'source', 'kind': kind, 'path': path});
  }

  /// 设置工作声道模式（0=自动, 1=手动）
  void setChannelsCountMode(int mode) {
    final m = mode.clamp(0, 1);
    channelsCountMode = m;
    config.channelsCountMode = m;
    ConfigManager.save(config);
    setInt('channels.countMode', m);
  }

  /// 设置手动工作声道数（2, 4, 6, 8）
  void setChannelsCount(int count) {
    if (count == 2 || count == 4 || count == 6 || count == 8) {
      channelsCount = count;
      config.channelsCount = count;
      ConfigManager.save(config);
      setInt('channels.count', count);
    }
  }
}
