// part of state.dart —— P5 按区拆分，extension 包装零逻辑改动。
part of '../state.dart';

/// spatial.style 0/1/2 的规范预设值（与引擎 hook_spatial_style 同源）。
/// 3 = 自定义，不套用任何预设。
({double room, double width, double center}) _spatialPresetFor(int style) {
  if (style == 0) return (room: 0.7, width: 1.0, center: 0.8);
  if (style == 1) return (room: 0.25, width: 1.1, center: 0.5);
  return (room: 0.0, width: 1.0, center: 0.5);
}

/// 三个自定义参数是否仍与 style 0..2 的规范预设一致。
bool _spatialMatchesPreset(
    int style, double room, double width, double center) {
  if (style < 0 || style > 2) return false;
  final preset = _spatialPresetFor(style);
  return (room - preset.room).abs() < 1e-6 &&
      (width - preset.width).abs() < 1e-6 &&
      (center - preset.center).abs() < 1e-6;
}

/// 全部效果 setter（同构块）：comp/bass/spatial/reverb/gate/deesser/
/// dyneq/loudness/arbmag/filter/shelf/tube/exciter/haas/crossfeed/
/// bassmono/limiter/inputGain 各组 + autoGain/outputGain 对 + 头追/
/// 音源/分类 UI 状态。
///
/// 方法体逐字保留自 AppModel 类体（notifyListeners() 按 P2 约定改调
/// _notifyUi()）。本块为历史层叠顺序（非按效果分组），与搬迁前一致；
/// IDE outline 可按方法名跳读。
extension StateEffects on AppModel {
  /// 混响预设：废除品质档拦截限制，无条件自由放行。
  /// `reverb.preset` 是唯一开关（-1 关 / -2 自定义 / 0..18 预设）。
  void setReverbPreset(int v, {String? autoQualityMsg}) {
    if (v != -1) _lastReverbPreset = v;
    setInt('reverb.preset', v);
  }

  void setTubeEnabled(bool on) {
    setInt(ParamId.tubeEnable, on ? 1 : 0);
  }

  void setCrossfeedEnabled(bool on) {
    xfeedOn = on;
    setInt(ParamId.xfeedEnable, on ? 1 : 0);
    _notifyUi();
    scheduleAutoSave();
  }

  void setCrossfeedMode(int mode) {
    xfeedMode = mode.clamp(0, 3);
    if (xfeedMode == 0) {
      xfeedFcut = 700.0;
      xfeedFeed = 4.5;
      setFloat(ParamId.xfeedFcut, xfeedFcut);
      setFloat(ParamId.xfeedFeed, xfeedFeed);
    } else if (xfeedMode == 1) {
      xfeedFcut = 700.0;
      xfeedFeed = 6.0;
      setFloat(ParamId.xfeedFcut, xfeedFcut);
      setFloat(ParamId.xfeedFeed, xfeedFeed);
    } else if (xfeedMode == 2) {
      xfeedFcut = 650.0;
      xfeedFeed = 9.5;
      setFloat(ParamId.xfeedFcut, xfeedFcut);
      setFloat(ParamId.xfeedFeed, xfeedFeed);
    }
    setInt(ParamId.xfeedMode, xfeedMode);
    _notifyUi();
    scheduleAutoSave();
  }

  void setCrossfeedFcut(double v) {
    xfeedFcut = v.clamp(300.0, 2000.0);
    xfeedMode = 3; // 联动切为自定义模式
    setInt(ParamId.xfeedMode, 3);
    setFloat(ParamId.xfeedFcut, xfeedFcut);
    _notifyUi();
    scheduleAutoSave();
  }

  void setCrossfeedFeed(double v) {
    xfeedFeed = v.clamp(1.0, 15.0);
    xfeedMode = 3; // 联动切为自定义模式
    setInt(ParamId.xfeedMode, 3);
    setFloat(ParamId.xfeedFeed, xfeedFeed);
    _notifyUi();
    scheduleAutoSave();
  }

  /// 低频单声道化（BassMono）：开关与分频点（stereo 解耦教训：独立开关位，
  /// 频率滑块到下限不关开关）。
  void setBassmonoEnabled(bool on) {
    bassmonoOn = on;
    if (on) _wantedBassmono = true;
    setInt(ParamId.bassmonoEnable, on ? 1 : 0);
    _notifyUi();
    scheduleAutoSave();
  }

  void setBassmonoFreq(double v) {
    bassmonoFreq = v.clamp(20.0, 300.0);
    setFloat(ParamId.bassmonoFreq, bassmonoFreq);
    _notifyUi();
    scheduleAutoSave();
  }

  void setBassmonoPairs(int pairs) {
    bassmonoPairs = pairs.clamp(0, 15);
    setInt(ParamId.bassmonoPairs, bassmonoPairs);
    _notifyUi();
    scheduleAutoSave();
  }

  void setBassmonoMerge(int merge) {
    bassmonoMerge = merge.clamp(0, 1);
    setInt(ParamId.bassmonoMerge, bassmonoMerge);
    _notifyUi();
    scheduleAutoSave();
  }

  /// Haas 差分环绕：右声道延迟 + 干湿混合（左声道恒直通，保单声道兼容）。
  void setHaasEnabled(bool on) {
    haasOn = on;
    setInt(ParamId.haasEnable, on ? 1 : 0);
    _notifyUi();
    scheduleAutoSave();
  }

  void setHaasDelay(double v) {
    haasDelayMs = v.clamp(0.0, 25.0);
    setFloat(ParamId.haasDelay, haasDelayMs);
    // haas 延迟即滑块值（纯延迟线，componentLatency 动态返回估算）；
    // 旧实现曾在此把它写进 _measuredLatencyMs 冒充实测，已随假测量分支
    // 一并移除（2026-10-18/19）。
    _notifyUi();
    scheduleAutoSave();
  }

  void setHaasMix(double v) {
    haasMix = v.clamp(0.0, 1.0);
    setFloat(ParamId.haasMix, haasMix);
    _notifyUi();
    scheduleAutoSave();
  }

  /// 差分延迟侧：0=延迟右声道，1=延迟左声道（另一侧恒直通）。
  void setHaasSide(int side) {
    haasSide = side.clamp(0, 1);
    setInt(ParamId.haasSide, haasSide);
    _notifyUi();
    scheduleAutoSave();
  }

  /// 空间音效 L1：总开关 + 风格（三预设即整组联动，引擎+界面同步覆盖）。
  void setSpatialEnabled(bool on) {
    spatialOn = on;
    setInt(ParamId.spatialEnable, on ? 1 : 0);
    _notifyUi();
    scheduleAutoSave();
  }

  /// 风格：0=影院 / 1=定位 / 2=中性 / 3=自定义。
  ///
  /// 预设档只下发 `spatial.style`：引擎 hook_spatial_style 会同步写入
  /// room/width/center。若随后再下发这三个参数，引擎的
  /// hook_spatial_custom_param 会把 style 自动改成 3——选中预设却变成
  /// “自定义”。自定义档（3）保留当前值，不套用任何预设。
  void setSpatialStyle(int style) {
    spatialStyle = style.clamp(0, 3);
    if (spatialStyle != 3) {
      final preset = _spatialPresetFor(spatialStyle);
      spatialRoom = preset.room;
      spatialWidth = preset.width;
      spatialCenter = preset.center;
    }
    setInt(ParamId.spatialStyle, spatialStyle);
    _notifyUi();
    scheduleAutoSave();
  }

  void setSpatialRoom(double v) {
    spatialRoom = v.clamp(0.0, 1.0);
    if (spatialStyle >= 0 &&
        spatialStyle <= 2 &&
        (spatialRoom - _spatialPresetFor(spatialStyle).room).abs() < 1e-6) {
      // 预设规范值：引擎 style hook 已写入，重复下发会误触自定义态。
      _notifyUi();
      scheduleAutoSave();
      return;
    }
    _enterSpatialCustom();
    setFloat(ParamId.spatialRoom, spatialRoom);
    _notifyUi();
    scheduleAutoSave();
  }

  void setSpatialWidth(double v) {
    spatialWidth = v.clamp(0.5, 1.5);
    if (spatialStyle >= 0 &&
        spatialStyle <= 2 &&
        (spatialWidth - _spatialPresetFor(spatialStyle).width).abs() < 1e-6) {
      _notifyUi();
      scheduleAutoSave();
      return;
    }
    _enterSpatialCustom();
    setFloat(ParamId.spatialWidth, spatialWidth);
    _notifyUi();
    scheduleAutoSave();
  }

  void setSpatialCenter(double v) {
    spatialCenter = v.clamp(0.0, 1.0);
    if (spatialStyle >= 0 &&
        spatialStyle <= 2 &&
        (spatialCenter - _spatialPresetFor(spatialStyle).center).abs() < 1e-6) {
      _notifyUi();
      scheduleAutoSave();
      return;
    }
    _enterSpatialCustom();
    setFloat(ParamId.spatialCenter, spatialCenter);
    _notifyUi();
    scheduleAutoSave();
  }

  /// 手动改 room/width/center 时切入自定义态（对齐引擎 set hook）。
  void _enterSpatialCustom() {
    if (spatialStyle == 3) return;
    setInt(ParamId.spatialStyle, 3);
  }

  void setSpatialOutGain(double v) {
    spatialOutGain = v.clamp(-12.0, 6.0);
    setFloat(ParamId.spatialOutGain, spatialOutGain);
    _notifyUi();
    scheduleAutoSave();
  }

  void setSpatialAutoGain(bool on) {
    spatialAutoGain = on;
    setInt(ParamId.spatialAutoGain, on ? 1 : 0);
    _notifyUi();
    scheduleAutoSave();
  }

  void setSpatialMix(double v) {
    spatialMix = v.clamp(0.0, 1.0);
    setFloat(ParamId.spatialMix, spatialMix);
    _notifyUi();
    scheduleAutoSave();
  }

  void setSpatialElevation(double v) {
    spatialElevation = v.clamp(-30.0, 30.0);
    setFloat(ParamId.spatialElevation, spatialElevation);
    _notifyUi();
    scheduleAutoSave();
  }

  void setSpatialBinaural(bool on) {
    spatialBinaural = on;
    setInt(ParamId.spatialBinaural, on ? 1 : 0);
    _notifyUi();
    scheduleAutoSave();
  }

  /// 头部朝向（手动或 OpenTrack 外部数据；引擎按块级 15ms 平滑消费）。
  void setSpatialHeadAzim(double v, {bool persist = true}) {
    final next = v.clamp(-180.0, 180.0);
    if ((next - spatialHeadAzim).abs() < 0.25) return;
    spatialHeadAzim = next;
    setFloat(ParamId.spatialHeadAzim, spatialHeadAzim);
    _notifyUi();
    if (persist) scheduleAutoSave();
  }

  void setSpatialHeadTrack(bool on) {
    spatialHeadTrack = on;
    setInt(ParamId.spatialHeadTrack, on ? 1 : 0);
    _syncHeadTracker();
    _notifyUi();
    scheduleAutoSave();
  }

  void _syncHeadTracker() {
    if (spatialHeadTrack) {
      if (!_headTracker.isRunning) _startHeadTracker();
    } else {
      _headTracker.stop();
    }
  }

  void _startHeadTracker() {
    _headTracker
        .start(
          onYaw: (yaw) {
            setSpatialHeadAzim(yaw, persist: false);
          },
        )
        .then((ok) {
          if (!ok && spatialHeadTrack) {
            spatialHeadTrack = false;
            setInt(ParamId.spatialHeadTrack, 0);
            _notifyUi();
          }
        });
  }

  /// 5.1 源模式切换（直通只在本地渲染 + raw 就绪 + 设备声道足够时生效，
  /// 否则自动回落混缩；桥注入试音恒走 fold，不受此开关影响）。
  void setSource51Mode(int mode) {
    source51Mode = mode.clamp(0, 1);
    send({'cmd': 'source51', 'value': source51Mode});
    _notifyUi();
    scheduleAutoSave();
  }

  /// 效果页分类切换（纯视图过滤，不动引擎；会话内有效）。
  void setEffectsCategory(String c) {
    effectsCategory = c;
    _notifyUi();
  }

  /// 激励器：只暴露 amount/hifreq，drive 固定 2.0（防调出刺耳）。
  void setExciterEnabled(bool on) {
    exciterOn = on;
    setInt(ParamId.exciterEnable, on ? 1 : 0);
    _notifyUi();
    scheduleAutoSave();
  }

  void setExciterAmount(double v) {
    exciterAmount = v.clamp(0.0, 1.0);
    setFloat(ParamId.exciterAmount, exciterAmount);
    _notifyUi();
    scheduleAutoSave();
  }

  void setExciterHifreq(double v) {
    exciterHifreq = v.clamp(3000.0, 10000.0);
    setFloat(ParamId.exciterHifreq, exciterHifreq);
    _notifyUi();
    scheduleAutoSave();
  }

  void setInputGain(double v) {
    inputGain = v;
    setFloat(ParamId.inputGain, v);
    _notifyUi();
  }

  void setInputBalanceL(double v) {
    inputBalanceL = v;
    setFloat(ParamId.inputBalance(1), v);
    _notifyUi();
  }

  void setInputBalanceR(double v) {
    inputBalanceR = v;
    setFloat(ParamId.inputBalance(2), v);
    _notifyUi();
  }

  /// 兼容旧调用点：`freeverb.enable` 已退役，转发到唯一开关。
  /// 旧调用点仍可工作，但不再向引擎发送 freeverb.enable。
  void setFreeverbEnabled(bool on, {String? autoQualityMsg}) {
    setSpatialReverbEnabled(on);
  }

  /// 预设对应的 3D 可视化参数（仅本地；引擎按路径使用预设表或 vendor
  /// 原生参数，不再把预设值写进 freeverb.*）。
  (double, double, double, double, double, double) _reverbVizFor(int id) {
    return switch (id) {
      5 => (0.85, 0.25, 0.45, 1.0, 1.5, 1.0), // 大音乐厅
      3 => (0.75, 0.30, 0.40, 1.0, 1.3, 1.0), // 音乐厅
      1 => (0.65, 0.35, 0.35, 1.0, 1.1, 0.9), // 中音乐厅
      2 => (0.55, 0.40, 0.30, 1.0, 0.9, 0.85), // 小音乐厅
      9 => (0.45, 0.45, 0.28, 1.0, 0.8, 0.8), // 录音棚
      7 => (0.35, 0.50, 0.25, 1.0, 0.65, 0.75), // 房间
      11 => (0.30, 0.50, 0.30, 1.0, 1.2, 0.9), // 大礼堂
      15 => (0.70, 0.15, 0.35, 1.0, 1.0, 1.0), // 板式混响
      _ => (0.70, 0.15, 0.35, 1.0, 1.0, 1.0), // 非 curated 旧预设
    };
  }

  void selectReverbPreset(int id) {
    if (id < -2 || id > 18) return;
    // 禁止显示与使用旧版预设 0，统一规整到精选第一档（5 大音乐厅）
    final targetId = (id == 0) ? kReverbCuratedPresets.first : id;
    if (targetId == -1) {
      // 记住关闭前的预设（含 -2 自定义），重新开启时恢复。
      if (reverbPreset != -1) {
        _lastReverbPreset = (reverbPreset <= 0 && reverbPreset != -2)
            ? kReverbCuratedPresets.first
            : reverbPreset;
      }
      reverbPreset = -1;
      setReverbPreset(-1);
      return;
    }
    if (targetId == -2) {
      reverbPreset = -2;
      _lastReverbPreset = -2;
      setReverbPreset(-2);
      // 进入自定义态时把 UI 侧全部自定义参数下发给引擎，保证预设→自定义
      // 切换后两引擎拿到的系数与滑块一致。
      _pushAllReverbCustomParams();
      return;
    }
    reverbPreset = targetId;
    _lastReverbPreset = targetId;
    final (decay, damp, wet, dry, roomSize, width) = _reverbVizFor(targetId);
    fvDecay = decay;
    fvDamp = damp;
    fvWet = wet;
    fvDry = dry;
    fvRoomSize = roomSize;
    fvWidth = width;
    setReverbPreset(targetId);
  }

  void setSpatialReverbEnabled(bool on) {
    if (on) {
      if (reverbPreset != -1) return;
      final target = (_lastReverbPreset <= 0 && _lastReverbPreset != -2)
          ? kReverbCuratedPresets.first
          : _lastReverbPreset;
      selectReverbPreset(target);
    } else {
      selectReverbPreset(-1);
    }
  }

  void setReverbPredelay(double v) {
    reverbPredelay = v.clamp(0.0, 100.0);
    setFloat(ParamId.reverbPredelay, reverbPredelay);
    _notifyUi();
    scheduleAutoSave();
  }

  void setReverbLfe(bool on) {
    reverbLfe = on;
    setInt(ParamId.reverbLfe, on ? 1 : 0);
    _notifyUi();
    scheduleAutoSave();
  }

  void setReverbCustomParam(String param, double value) {
    applyReverbCustomParams(
      decay: param == 'decay' ? value : null,
      damp: param == 'damp' ? value : null,
      wet: param == 'wet' ? value : null,
      dry: param == 'dry' ? value : null,
      roomSize: param == 'roomSize' ? value : null,
      width: param == 'width' ? value : null,
      activate: true,
    );
  }

  /// 批量更新混响自定义参数（预设应用/旧会话迁移用）。
  /// [activate] 为 true 时进入自定义态（-2）；false 只更新字段与引擎参数，
  /// 不改变开关状态（旧预设 preset=-1 仍保持关闭）。
  void applyReverbCustomParams({
    double? decay,
    double? damp,
    double? wet,
    double? dry,
    double? roomSize,
    double? width,
    bool activate = true,
  }) {
    if (decay != null) fvDecay = decay.clamp(0.0, 1.0);
    if (damp != null) fvDamp = damp.clamp(0.0, 1.0);
    if (wet != null) fvWet = wet.clamp(0.0, 1.0);
    if (dry != null) fvDry = dry.clamp(0.0, 1.0);
    // 引擎表 0.5..2.5；旧预设/session 里的越界值必须钳住，否则必被拒收。
    if (roomSize != null) fvRoomSize = roomSize.clamp(0.5, 2.5);
    // 引擎表 0.2..2.0（MC FDN 宽度上限；立体声路径 UI 另行限制到 1.0）。
    if (width != null) fvWidth = width.clamp(0.2, 2.0);
    if (activate) {
      reverbPreset = -2;
      _lastReverbPreset = -2;
      setReverbPreset(-2);
    }
    _pushAllReverbCustomParams();
  }

  void _pushAllReverbCustomParams() {
    setFloat('freeverb.decay', fvDecay);
    setFloat('freeverb.damp', fvDamp);
    setFloat('freeverb.wet', fvWet);
    setFloat('freeverb.dry', fvDry);
    setFloat('freeverb.roomsize', fvRoomSize);
    setFloat('freeverb.width', fvWidth);
  }

  void setCompEnabled(bool on) {
    compOn = on;
    setInt(ParamId.compEnable, on ? 1 : 0);
    _notifyUi();
    scheduleAutoSave();
  }

  void setCompTimeconstant(double v) {
    // 引擎表 0.02..0.5s；旧实现无 clamp，UI/预设给 0.01 或 1.0 会被引擎
    // 拒收再回读回弹（块自己变 + 通知弹窗）。2026-10-18 补钳。
    compTimeconstant = v.clamp(0.02, 0.5);
    setFloat(ParamId.compTimeconstant, compTimeconstant);
    _notifyUi();
    scheduleAutoSave();
  }

  void setCompGranularity(int v) {
    compGranularity = v;
    setInt(ParamId.compGranularity, v);
    _notifyUi();
    scheduleAutoSave();
  }

  void setCompTfresolution(int v) {
    compTfresolution = v;
    setInt(ParamId.compTfresolution, v);
    _notifyUi();
    scheduleAutoSave();
  }

  void setCompThreshold(double v, {bool forceFlush = false}) {
    compThreshold = v;
    // 宏观阈值联动压缩强度：阈值越深(-dB)，压限系数越负
    final strength = ((-v) / 48.0).clamp(0.0, 1.0);
    for (var i = 0; i < 7; i++) {
      compGains[i] = (-strength * 0.9).clamp(-1.2, 1.2);
      _mirror('comp.gain${i + 1}', compGains[i]);
    }
    _notifyUi();
    scheduleAutoSave();

    final diff = (v - _lastDispatchedCompThreshold).abs();
    if (_testing || forceFlush || diff >= 0.4) {
      _compThresholdThrottleTimer?.cancel();
      _compThresholdThrottleTimer = null;
      _dispatchCompGainsToEngine();
    } else {
      _compThresholdThrottleTimer ??= Timer(const Duration(milliseconds: 30), () {
        _compThresholdThrottleTimer = null;
        _dispatchCompGainsToEngine();
      });
    }
  }

  void _dispatchCompGainsToEngine() {
    _lastDispatchedCompThreshold = compThreshold;
    for (var i = 0; i < 7; i++) {
      _markSent('comp.gain${i + 1}');
      send({'cmd': 'setParam', 'id': 'comp.gain${i + 1}', 'value': compGains[i], 'isFloat': true});
    }
  }

  void setCompRatio(double v) {
    compRatio = v;
    _notifyUi();
    scheduleAutoSave();
  }

  void setCompFreq(int band, double freq) {
    if (band < 0 || band >= 7) return;
    compFreqs[band] = freq;
    setFloat('comp.freq${band + 1}', freq);
    _notifyUi();
    scheduleAutoSave();
  }

  void setCompGain(int band, double gain) {
    if (band < 0 || band >= 7) return;
    compGains[band] = gain;
    setFloat('comp.gain${band + 1}', gain);
    _notifyUi();
    scheduleAutoSave();
  }

  /* ---- 低音增强重构（Phase 4） ---- */

  void setBassAutoGain(bool v) {
    bassAutoGain = v;
    setInt(ParamId.bassAutoGain, v ? 1 : 0);
    _notifyUi();
  }

  void setBassOutputGain(double v) {
    bassOutputGain = v.clamp(-12.0, 6.0);
    setFloat(ParamId.bassOutGain, bassOutputGain);
    _notifyUi();
  }

  void setEqAutoGain(bool v) {
    eqAutoGain = v;
    setInt(ParamId.eqAutoGain, v ? 1 : 0);
    _notifyUi();
  }

  void setEqOutputGain(double v) {
    eqOutputGain = v.clamp(-12.0, 6.0);
    setFloat(ParamId.eqOutGain, eqOutputGain);
    _notifyUi();
  }

  void setReverbAutoGain(bool v) {
    reverbAutoGain = v;
    setInt(ParamId.reverbAutoGain, v ? 1 : 0);
    _notifyUi();
  }

  void setReverbOutputGain(double v) {
    reverbOutputGain = v.clamp(-12.0, 6.0);
    setFloat(ParamId.reverbOutGain, reverbOutputGain);
    _notifyUi();
  }

  void setTubeAutoGain(bool v) {
    tubeAutoGain = v;
    setInt(ParamId.tubeAutoGain, v ? 1 : 0);
    _notifyUi();
  }

  void setTubeOutputGain(double v) {
    tubeOutputGain = v.clamp(-12.0, 6.0);
    setFloat(ParamId.tubeOutGain, tubeOutputGain);
    _notifyUi();
  }

  void setCompAutoGain(bool v) {
    compAutoGain = v;
    setInt(ParamId.compAutoGain, v ? 1 : 0);
    _notifyUi();
  }

  void setCompOutputGain(double v) {
    compOutputGain = v.clamp(-12.0, 6.0);
    setFloat(ParamId.compOutGain, compOutputGain);
    _notifyUi();
  }

  void setCompMode(int v) {
    compMode = v.clamp(0, 1);
    setInt(ParamId.compMode, compMode);
    _notifyUi();
  }

  /// 噪声门（链头第一道）：阈值/attack/release 全下发；自动增益补偿独立开关。
  void setGateEnabled(bool on) {
    gateOn = on;
    if (!on) {
      setDeesserEnabled(false);
    }
    setInt(ParamId.gateEnable, on ? 1 : 0);
    _notifyUi();
  }

  void setGateThreshold(double v) {
    gateThreshold = v.clamp(-60.0, 0.0);
    setFloat(ParamId.gateThreshold, gateThreshold);
    _notifyUi();
  }

  void setGateAttack(double v) {
    gateAttackMs = v.clamp(1.0, 100.0);
    setFloat(ParamId.gateAttack, gateAttackMs);
    _notifyUi();
  }

  void setGateRelease(double v) {
    gateReleaseMs = v.clamp(10.0, 500.0);
    setFloat(ParamId.gateRelease, gateReleaseMs);
    _notifyUi();
  }

  void setGateHysteresis(double v) {
    gateHysteresis = v.clamp(0.0, 12.0);
    setFloat(ParamId.gateHysteresis, gateHysteresis);
    _notifyUi();
  }

  void setGateRange(double v) {
    gateRange = v.clamp(-80.0, 0.0);
    setFloat(ParamId.gateRange, gateRange);
    _notifyUi();
  }

  void setGateHoldMs(double v) {
    gateHoldMs = v.clamp(0.0, 500.0);
    setFloat(ParamId.gateHoldMs, gateHoldMs);
    _notifyUi();
  }

  void setExciterOversample(bool on) {
    exciterOversample = on;
    setInt(ParamId.exciterOversample, on ? 1 : 0);
    _notifyUi();
  }

  void setTubeOversample(bool on) {
    tubeOversample = on;
    setInt(ParamId.tubeOversample, on ? 1 : 0);
    _notifyUi();
  }

  void setLimiterRelease(double v) {
    limiterReleaseMs = v.clamp(10.0, 500.0);
    setFloat(ParamId.limiterRelease, limiterReleaseMs);
    _notifyUi();
  }

  void setLimiterThreshold(double v) {
    limiterThreshold = v.clamp(-24.0, 0.0);
    setFloat(ParamId.limiterThreshold, limiterThreshold);
    _notifyUi();
  }

  void setLimiterLink(bool on) {
    limiterLink = on;
    setInt(ParamId.limiterLink, on ? 1 : 0);
    _notifyUi();
  }

  void setLimiterLookahead(bool on) {
    limiterLookahead = on;
    setInt(ParamId.limiterLookahead, on ? 1 : 0);
    _notifyUi();
  }

  void setGateAutoGain(bool v) {
    gateAutoGain = v;
    setInt(ParamId.gateAutoGain, v ? 1 : 0);
    _notifyUi();
  }

  /// Deesser（高级区）：开关 + 侧链频率 + 强度。
  void setDeesserEnabled(bool on) {
    deesserOn = on;
    setInt(ParamId.deesserEnable, on ? 1 : 0);
    _notifyUi();
  }

  void setDeesserFreq(double v) {
    deesserFreq = v.clamp(2000.0, 10000.0);
    setFloat(ParamId.deesserFreq, deesserFreq);
    _notifyUi();
  }

  void setDeesserAmount(double v) {
    deesserAmount = v.clamp(0.0, 1.0);
    setFloat(ParamId.deesserAmount, deesserAmount);
    _notifyUi();
  }

  /// 全参数动态EQ：总开关 + 包络时间 + 3 段 ×（开关/频率/Q/静态增益/动态量/阈值）。
  void setDyneqEnabled(bool on) {
    dyneqOn = on;
    setInt(ParamId.dyneqEnable, on ? 1 : 0);
    _notifyUi();
  }

  void setDyneqAttack(double v) {
    dyneqAttackMs = v.clamp(0.1, 100.0);
    dyneqB1Attack = dyneqAttackMs;
    dyneqB2Attack = dyneqAttackMs;
    dyneqB3Attack = dyneqAttackMs;
    setFloat(ParamId.dyneqAttack, dyneqAttackMs);
    _notifyUi();
  }

  void setDyneqRelease(double v) {
    dyneqReleaseMs = v.clamp(10.0, 1000.0);
    dyneqB1Release = dyneqReleaseMs;
    dyneqB2Release = dyneqReleaseMs;
    dyneqB3Release = dyneqReleaseMs;
    setFloat(ParamId.dyneqRelease, dyneqReleaseMs);
    _notifyUi();
  }

  void setDyneqB1Attack(double v) {
    dyneqB1Attack = v.clamp(0.1, 100.0);
    setFloat(ParamId.dyneqB1Attack, dyneqB1Attack);
    _notifyUi();
  }

  void setDyneqB1Release(double v) {
    dyneqB1Release = v.clamp(10.0, 1000.0);
    setFloat(ParamId.dyneqB1Release, dyneqB1Release);
    _notifyUi();
  }

  void setDyneqB2Attack(double v) {
    dyneqB2Attack = v.clamp(0.1, 100.0);
    setFloat(ParamId.dyneqB2Attack, dyneqB2Attack);
    _notifyUi();
  }

  void setDyneqB2Release(double v) {
    dyneqB2Release = v.clamp(10.0, 1000.0);
    setFloat(ParamId.dyneqB2Release, dyneqB2Release);
    _notifyUi();
  }

  void setDyneqB3Attack(double v) {
    dyneqB3Attack = v.clamp(0.1, 100.0);
    setFloat(ParamId.dyneqB3Attack, dyneqB3Attack);
    _notifyUi();
  }

  void setDyneqB3Release(double v) {
    dyneqB3Release = v.clamp(10.0, 1000.0);
    setFloat(ParamId.dyneqB3Release, dyneqB3Release);
    _notifyUi();
  }

  void setDyneqLowEnabled(bool on) {
    dyneqLowOn = on;
    setInt(ParamId.dyneqLowEnable, on ? 1 : 0);
    _notifyUi();
  }

  void setDyneqLowFreq(double v) {
    dyneqLowFreq = v.clamp(20.0, 500.0);
    setFloat(ParamId.dyneqLowFreq, dyneqLowFreq);
    _notifyUi();
  }

  void setDyneqLowQ(double v) {
    dyneqLowQ = v.clamp(0.5, 2.0);
    setFloat(ParamId.dyneqLowQ, dyneqLowQ);
    _notifyUi();
  }

  void setDyneqLowGain(double v) {
    dyneqLowGain = v.clamp(-12.0, 12.0);
    setFloat(ParamId.dyneqLowGain, dyneqLowGain);
    _notifyUi();
  }

  void setDyneqLowRange(double v) {
    dyneqLowRange = v.clamp(0.0, 24.0);
    setFloat(ParamId.dyneqLowRange, dyneqLowRange);
    _notifyUi();
  }

  void setDyneqLowThreshold(double v) {
    dyneqLowThreshold = v.clamp(-60.0, 0.0);
    setFloat(ParamId.dyneqLowThreshold, dyneqLowThreshold);
    _notifyUi();
  }

  void setDyneqMidEnabled(bool on) {
    dyneqMidOn = on;
    setInt(ParamId.dyneqMidEnable, on ? 1 : 0);
    _notifyUi();
  }

  void setDyneqMidFreq(double v) {
    dyneqMidFreq = v.clamp(200.0, 8000.0);
    setFloat(ParamId.dyneqMidFreq, dyneqMidFreq);
    _notifyUi();
  }

  void setDyneqMidQ(double v) {
    dyneqMidQ = v.clamp(0.3, 10.0);
    setFloat(ParamId.dyneqMidQ, dyneqMidQ);
    _notifyUi();
  }

  void setDyneqMidGain(double v) {
    dyneqMidGain = v.clamp(-12.0, 12.0);
    setFloat(ParamId.dyneqMidGain, dyneqMidGain);
    _notifyUi();
  }

  void setDyneqMidRange(double v) {
    dyneqMidRange = v.clamp(0.0, 24.0);
    setFloat(ParamId.dyneqMidRange, dyneqMidRange);
    _notifyUi();
  }

  void setDyneqMidThreshold(double v) {
    dyneqMidThreshold = v.clamp(-60.0, 0.0);
    setFloat(ParamId.dyneqMidThreshold, dyneqMidThreshold);
    _notifyUi();
  }

  void setDyneqHighEnabled(bool on) {
    dyneqHighOn = on;
    setInt(ParamId.dyneqHighEnable, on ? 1 : 0);
    _notifyUi();
  }

  void setDyneqHighFreq(double v) {
    dyneqHighFreq = v.clamp(2000.0, 20000.0);
    setFloat(ParamId.dyneqHighFreq, dyneqHighFreq);
    _notifyUi();
  }

  void setDyneqHighQ(double v) {
    dyneqHighQ = v.clamp(0.5, 2.0);
    setFloat(ParamId.dyneqHighQ, dyneqHighQ);
    _notifyUi();
  }

  void setDyneqHighGain(double v) {
    dyneqHighGain = v.clamp(-12.0, 12.0);
    setFloat(ParamId.dyneqHighGain, dyneqHighGain);
    _notifyUi();
  }

  void setDyneqHighRange(double v) {
    dyneqHighRange = v.clamp(0.0, 24.0);
    setFloat(ParamId.dyneqHighRange, dyneqHighRange);
    _notifyUi();
  }

  void setDyneqHighThreshold(double v) {
    dyneqHighThreshold = v.clamp(-60.0, 0.0);
    setFloat(ParamId.dyneqHighThreshold, dyneqHighThreshold);
    _notifyUi();
  }

  /// 响度补偿：信号越静，低频 + 高频补得越多（简化等响曲线）。
  void setLoudnessEnabled(bool on) {
    loudnessOn = on;
    setInt(ParamId.loudnessEnable, on ? 1 : 0);
    _notifyUi();
  }

  void setLoudnessAmount(double v) {
    loudnessAmount = v.clamp(0.0, 1.0);
    setFloat(ParamId.loudnessAmount, loudnessAmount);
    _notifyUi();
  }

  /* ---- 任意响应 EQ（ArbMag / AutoEq GraphicEQ） ---- */

  void setArbmagEnabled(bool on) {
    arbmagOn = on;
    _markSent(ParamId.arbmagEnable);
    send({
      'cmd': 'setParam',
      'id': ParamId.arbmagEnable,
      'value': (on && arbmagReady) ? 1 : 0,
      'isFloat': false,
    });
    _notifyUi();
    scheduleAutoSave();
  }

  void setArbmagString(String s) {
    arbmagString = s;
    send({'cmd': 'setParamStr', 'id': ParamId.arbmagString, 'text': s});
    _toIso?.send({'cmd': 'getParams'});
    _notifyUi();
    scheduleAutoSave();
  }

  void clearArbmag() {
    arbmagReady = false;
    arbmagNodeCount = 0;
    arbmagString = '';
    _markSent(ParamId.arbmagEnable);
    send({
      'cmd': 'setParam',
      'id': ParamId.arbmagEnable,
      'value': 0,
      'isFloat': false,
    });
    send({'cmd': 'setParamStr', 'id': ParamId.arbmagString, 'text': ''});
    _notifyUi();
    scheduleAutoSave();
  }

  void setArbmagAutoGain(bool v) {
    arbmagAutoGain = v;
    setInt(ParamId.arbmagAutoGain, v ? 1 : 0);
    _notifyUi();
    scheduleAutoSave();
  }

  void setArbmagOutputGain(double v) {
    arbmagOutputGain = v.clamp(-12.0, 6.0);
    setFloat(ParamId.arbmagOutGain, arbmagOutputGain);
    _notifyUi();
    scheduleAutoSave();
  }

  void setBassIntensity(double v) {
    bassIntensity = v.clamp(0.0, 1.0);
    final gain = (bassIntensity * 15.0).clamp(0.0, 15.0);
    bassGain = gain;
    // v3.1 重构：强度只驱动 vendor bass，不再碰 shelf 引擎。
    // shelf 由自己的卡/预设节独立管理（老快照的 shelf 态走 shelf 节恢复）。
    setFloat('bass.gain', gain);
    _notifyUi();
  }

  /// ViPER 三模式 = 谐波配方宏（0=自然低音 / 1=纯净低音 / 2=超重低音）。
  /// 不再碰 shelf 引擎；配方写入谐波三滑块（随后的 slider 恢复会覆盖为快照真值）。
  void setBassMode(int mode) {
    bassMode = mode;
    // [PATCHED-AuraDSP P-032] 必须把模式本身下发引擎：此前只写本地字段，
    // 引擎侧没有 bass.mode 参数 → 回读 getIntNullable 恒 null → isolate
    // 兜底 0 → params 回读把 UI 无条件覆盖成 0 → 用户选任何模式都被弹回
    // 「自然低音」（滑块会动、模式却跳回，即用户报告的现象）。
    // 引擎侧 bass.mode 是纯状态载体（不参与 DSP 计算），见 PATCHES.md。
    setInt('bass.mode', mode);
    if (mode == 1) {
      setBassHarmonics(0.35);
      setBassHarmonicBlend(0.5);
    } else if (mode == 2) {
      setBassHarmonics(0.7);
      setBassHarmonicBlend(0.7);
    } else {
      setBassHarmonics(0.0);
    }
    _notifyUi();
  }

  void setBassCutoff(double f) {
    bassCutoff = f;
    // v3.1：cutoff 改驱心理声学 LP，不再写 shelf.freq。
    setFloat(ParamId.bassCutoffF, bassCutoff);
    _notifyUi();
  }

  void setBassHarmonics(double h) {
    bassHarmonics = h.clamp(0.0, 1.0);
    setFloat(ParamId.bassHarmonics, bassHarmonics);
    _notifyUi();
  }

  void setBassHarmonicBlend(double b) {
    bassHarmonicBlend = b.clamp(0.0, 1.0);
    setFloat(ParamId.bassHarmonicBlend, bassHarmonicBlend);
    _notifyUi();
  }

  void setBassSubFloor(double s) {
    // 引擎表 10..40Hz；旧实现无 clamp，超界值引擎拒收 + 回读回弹。
    bassSubFloor = s.clamp(10.0, 40.0);
    setFloat(ParamId.bassSubFreq, bassSubFloor);
    _notifyUi();
  }

  /// 独立滤波器（RBJ HP/LP/BP，gate 后 / bassmono 前）。
  void setFilterEnabled(bool on) {
    filterOn = on;
    setInt(ParamId.filterEnable, on ? 1 : 0);
    _notifyUi();
  }

  void setFilterType(int t) {
    filterType = t.clamp(0, 2);
    setInt(ParamId.filterType, filterType);
    _notifyUi();
  }

  void setFilterFreq(double f) {
    filterFreq = f.clamp(20.0, 20000.0);
    setFloat(ParamId.filterFreq, filterFreq);
    _notifyUi();
  }

  void setFilterQ(double q) {
    filterQ = q.clamp(0.3, 10.0);
    setFloat(ParamId.filterQ, filterQ);
    _notifyUi();
  }

  /* ---- 低音塑形（Bass Shaping：合并低频搁架与单声道化） ---- */

  void setBassShapingEnabled(bool on) {
    if (on) {
      if (!_wantedShelf && !_wantedBassmono) {
        _wantedShelf = true;
        _wantedBassmono = true;
      }
      shelfOn = _wantedShelf;
      bassmonoOn = _wantedBassmono;
    } else {
      _wantedShelf = shelfOn;
      _wantedBassmono = bassmonoOn;
      shelfOn = false;
      bassmonoOn = false;
    }
    setInt(ParamId.shelfEnable, shelfOn ? 1 : 0);
    setInt(ParamId.bassmonoEnable, bassmonoOn ? 1 : 0);
    _notifyUi();
    scheduleAutoSave();
  }

  /* ---- 低频搁架（M5-b，自研 RBJ low-shelf；此前有引擎/回放无 UI） ---- */

  void setShelfEnabled(bool on) {
    shelfOn = on;
    if (on) _wantedShelf = true;
    setInt(ParamId.shelfEnable, on ? 1 : 0);
    _notifyUi();
    scheduleAutoSave();
  }

  void setShelfFreq(double f) {
    shelfFreq = f.clamp(40.0, 400.0);
    setFloat(ParamId.shelfFreq, shelfFreq);
    _notifyUi();
  }

  void setShelfGain(double db) {
    shelfGain = db.clamp(-15.0, 15.0);
    setFloat(ParamId.shelfGain, shelfGain);
    _notifyUi();
  }

  /* ---- 电子管模拟器（Phase 4） ---- */

  void setTubeGain(double db) {
    tubeGain = db.clamp(-3.0, 12.0);
    setFloat('tube.gain', tubeGain);
    _notifyUi();
  }

  void setTubeStyle(int style) {
    // P-011：引擎 tube.style 已接线（vendor character 开关，RT 安全）。
    tubeStyle = style.clamp(0, 2);
    setInt(ParamId.tubeStyle, tubeStyle);
    _notifyUi();
  }

  void setTubeCompensation(double comp) {
    // P-011：引擎 tube.compensation 已接线（vendor 湿信号补偿）。
    tubeCompensation = comp.clamp(-12.0, 12.0);
    setFloat(ParamId.tubeCompensation, tubeCompensation);
    _notifyUi();
  }

  void setTubeMix(double mix) {
    // P-011：引擎 tube.mix 已接线（vendor 干湿混合）。
    tubeMix = mix.clamp(0.0, 1.0);
    setFloat(ParamId.tubeMix, tubeMix);
    _notifyUi();
  }
}
