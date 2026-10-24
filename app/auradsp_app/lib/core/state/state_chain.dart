// part of state.dart —— P4 按区拆分，extension 包装零逻辑改动。
part of '../state.dart';

/// 处理链 stage/组/顺序 + 立体声链 + Liveprog + 卷积/DDC + 低音斜坡。
///
/// 方法体逐字保留自 AppModel 类体（notifyListeners() 按 P2 约定改调
/// _notifyUi()；setGraphOrder 内对留类 static filterVendorOrder 的调用加
/// AppModel. 限定——extension 作用域不含被扩展类型的 static 成员）。

/// 链组成员（Phase 2；与 chain_page.dart kChainGroups 同构，core 不得 import
/// features，故此处镜像一份，改动时两边同步）。
/// 原为 AppModel 类 static const，随 setChainGroup 迁入本文件顶层——
/// extension 方法体不能非限定引用类 static；无外部调用者。
const _chainGroupMembers = {
  'chInput': ['gate', 'filter'],
  'chTone': ['dyneq', 'bassmono', 'tube', 'comp', 'bass'],
  'chEq': ['eq', 'arbmag', 'convolver', 'ddc', 'liveprog'],
  'chSound': ['crossfeed', 'stereo', 'haas'],
  'chSpatial': ['spatial'],
  'chOut': ['exciter', 'reverb', 'loudness', 'output'],
};

/// 低音斜坡步进参数。原为 AppModel 类 static const，随四个斜坡方法
/// （_sendBassGain/_stepBassRamp/_kickBassRamp/_disableBassRamped）迁入
/// 本文件顶层——extension 方法体不能非限定引用类 static；无外部调用者。
const int _bassGainMinIntervalMs = 50; // 20 Hz
const double _bassGainStepDb = 0.6; // 每步最多推进 0.6 dB

extension StateChain on AppModel {

  // ---- 低音增益斜坡（防爆音） ----

  void _sendBassGain(double v) {
    _markSent('bass.gain');
    send({'cmd': 'setParam', 'id': 'bass.gain', 'value': v, 'isFloat': true});
  }

  /// 推进一格并安排下一步；到达目标后收尾（含关闭时的延迟 disable）。
  void _stepBassRamp() {
    _bassGainTimer = null;
    final target = _bassRampTarget;
    if (target == null) return;
    final diff = target - _bassRampCur;
    if (diff > _bassGainStepDb) {
      _bassRampCur += _bassGainStepDb;
    } else if (diff < -_bassGainStepDb) {
      _bassRampCur -= _bassGainStepDb;
    } else {
      _bassRampCur = target;
    }
    _sendBassGain(_bassRampCur);
    _kickBassRamp();
  }

  void _kickBassRamp() {
    final target = _bassRampTarget;
    if (target == null) return;
    if ((target - _bassRampCur).abs() <= _bassGainStepDb) {
      if (_bassRampCur != target) {
        _bassRampCur = target;
        _sendBassGain(target);
      }
      _bassRampTarget = null;
      if (_bassDisableAfterRamp) {
        // 已渐变到 0，此时关开关才不会「哒」一声。
        _bassDisableAfterRamp = false;
        _markSent('bass.enable');
        send({
          'cmd': 'setParam',
          'id': 'bass.enable',
          'value': 0,
          'isFloat': false,
        });
      }
      _bassGainTimer?.cancel();
      _bassGainTimer = null;
      return;
    }
    _bassGainTimer ??= Timer(
      const Duration(milliseconds: _bassGainMinIntervalMs),
      _stepBassRamp,
    );
  }

  /// 关闭低音：先把增益渐变到 0，再下发 disable（无爆音的旁路）。
  void _disableBassRamped() {
    if (_bassRampCur <= 0.0) {
      _markSent('bass.enable');
      send({
        'cmd': 'setParam',
        'id': 'bass.enable',
        'value': 0,
        'isFloat': false,
      });
      return;
    }
    _bassRampTarget = 0.0;
    _bassDisableAfterRamp = true;
    _kickBassRamp();
  }

  // ---- 立体声链 ----

  /// 声场链统一推送：开关关闭时引擎侧一律收 0（静默），
  /// UI 滑块值不动。直发 bypass _mirror，避免回写冲掉 UI 位置。
  void _pushStereoChain() {
    final k = stereoOn ? 1.0 : 0.0;
    _markSent('stereo.enable');
    send({
      'cmd': 'setParam',
      'id': 'stereo.enable',
      'value': stereoOn ? 1 : 0,
      'isFloat': false,
    });
    _markSent('stereo.mix');
    send({
      'cmd': 'setParam',
      'id': 'stereo.mix',
      'value': stereoMix * stereoWidenMax * k,
      'isFloat': true,
    });
    final macroMultiplier = stereoMix * 2.0;
    for (var i = 0; i < 5; i++) {
      final id = 'stereo.band${i + 1}';
      final eff =
          (stereoBands[i] * macroMultiplier).clamp(0.0, 1.0) *
          stereoWidenMax *
          k;
      _markSent(id);
      send({'cmd': 'setParam', 'id': id, 'value': eff, 'isFloat': true});
    }
    scheduleAutoSave();
  }

  void setStereoMix(double v) {
    stereoMix = v.clamp(0.0, 1.0);
    // 保持旧 setFloat 路径的 _mirror 副作用：5 个分带推送曾把 bandUsed 置 true。
    stereoBandUsed = true;
    _pushStereoChain();
    _notifyUi();
  }

  void setStereoBand(int index, double baseVal) {
    if (index < 0 || index >= 5) return;
    stereoBands[index] = baseVal.clamp(0.0, 1.0);
    // 同上：旧 _mirror 分带分支置 bandUsed = true。
    stereoBandUsed = true;
    _pushStereoChain();
    _notifyUi();
  }

  void resetStereoBand(int index) {
    setStereoBand(index, ParamDefaults.stereoBand);
  }

  /// 双击主滑块时重置立体声扩展并恢复 5 个子带为 0.5 中性（不关闭开关）
  void resetStereoWiden() {
    stereoMix = ParamDefaults.stereoMix;
    for (var i = 0; i < 5; i++) {
      stereoBands[i] = ParamDefaults.stereoBand;
    }
    stereoBandUsed = false;
    _pushStereoChain();
    _notifyUi();
  }

  void resetStereoBandsToGlobal() {
    for (var i = 0; i < 5; i++) {
      stereoBands[i] = ParamDefaults.stereoBand;
    }
    stereoBandUsed = false;
    _pushStereoChain();
    _notifyUi();
  }

  void setStereoEnabled(bool on) {
    stereoOn = on;
    if (on && stereoMix <= 0.0) {
      stereoMix = _lastStereoMix > 0.0
          ? _lastStereoMix
          : ParamDefaults.stereoMix;
    }
    if (!on && stereoMix > 0.0) {
      _lastStereoMix = stereoMix;
    }
    _pushStereoChain();
    _notifyUi();
  }

  // ---- 处理链顺序 / stage 索引 / 组开关 ----

  void setGraphOrder(String order) {
    graphOrder = order;
    send({
      'cmd': 'setParamStr',
      'id': 'graph.order',
      'text': AppModel.filterVendorOrder(order),
    });
    // chainOrder 在 snapshot/会话 schema 内，必须持久化，
    // 否则处理链重排重启即丢（此前唯一漏掉的大类用户动作）。
    scheduleAutoSave();
  }

  /// chain 行电平表映射：返回该 stage 在 AURADSP_STAGE_MAX (32) 中的固定槽位索引。
  /// 引擎 stagePeak 按效果 id 落槽，不跟 graph.order 走——重排后
  /// 灯位不动才是对的；跟实时 order 走反而会在重排后全错位。
  /// 0..11: vendor 12 stages
  /// 12: gate in (内部前测点)
  /// 13: gate stage out
  /// 14: dyneq stage out
  /// 15: filter stage out
  /// 16: bassmono stage out
  /// 17: haas stage out
  /// 18: exciter stage out
  /// 19: loudness stage out
  /// 20: spatial stage out（Phase 2 接入链页）
  /// 21..31: 预留/扩展插件槽
  int stageMeterIndex(String id) => switch (id) {
    'tube' => 0,
    'comp' => 1,
    'bass' => 2,
    'eq' => 3,
    'arbmag' => 4,
    'convolver' => 5,
    'ddc' => 6,
    'liveprog' => 7,
    'crossfeed' => 8,
    'stereo' => 9,
    'reverb' => 10,
    'output' => 11,
    'gate' => 13,
    'dyneq' => 14,
    'filter' => 15,
    'bassmono' => 16,
    'haas' => 17,
    'exciter' => 18,
    'loudness' => 19,
    'spatial' => 20,
    _ => -1,
  };

  /// 整组旁路/启用：把组内成员逐个拨到目标态（复用 toggleStage，含 reverb
  /// 特殊语义）。output（限幅器）常驻，跳过——整组旁路不得静音整机。
  void setChainGroup(String group, bool on) {
    final members = _chainGroupMembers[group];
    if (members == null) return;
    for (final id in members) {
      if (id == 'output') continue;
      if (isStageEnabled(id) != on) toggleStage(id);
    }
  }

  /// 获取某个处理链 stage 的启用状态
  bool isStageEnabled(String stageId) {
    return switch (stageId) {
      'tube' => tubeOn,
      'comp' => compOn,
      'bassmono' || 'shelf' || 'bass_shaping' => bassShapingOn,
      'gate' => gateOn,
      'dyneq' => dyneqOn,
      'filter' => filterOn,
      'loudness' => loudnessOn,
      'haas' => haasOn,
      'spatial' => spatialOn,
      'exciter' => exciterOn,
      'bass' => bassOn,
      'eq' => eqOn,
      'arbmag' => arbmagOn,
      'convolver' => convEnabled,
      'ddc' => ddcOn,
      'liveprog' => lpEnabled,
      'crossfeed' => xfeedOn,
      'stereo' => stereoOn,
      'reverb' =>
        reverbPreset >= 0 ||
            // 自定义态 -2：fvOn 即开着，判关会让链视图与耳朵打架。
            (reverbPreset == -2 && fvOn),
      'output' => limiterOn,
      _ => false,
    };
  }

  /// 切换某个处理链 stage 的启用/旁路状态
  void toggleStage(String stageId) {
    switch (stageId) {
      case 'tube':
        setInt('tube.enable', tubeOn ? 0 : 1);
      case 'bass_shaping' || 'shelf' || 'bassmono':
        setBassShapingEnabled(!bassShapingOn);
      case 'gate':
        setGateEnabled(!gateOn);
      case 'dyneq':
        setDyneqEnabled(!dyneqOn);
      case 'filter':
        setFilterEnabled(!filterOn);
      case 'loudness':
        setLoudnessEnabled(!loudnessOn);
      case 'haas':
        setHaasEnabled(!haasOn);
      case 'spatial':
        setSpatialEnabled(!spatialOn);
      case 'exciter':
        setExciterEnabled(!exciterOn);
      case 'comp':
        setCompEnabled(!compOn);
      case 'bass':
        setInt('bass.enable', bassOn ? 0 : 1);
      case 'eq':
        setInt('eq.enable', eqOn ? 0 : 1);
      case 'arbmag':
        setArbmagEnabled(!arbmagOn);
      case 'convolver':
        setInt(ParamId.convEnable, convEnabled ? 0 : 1);
      case 'ddc':
        setDdcEnabled(!ddcOn);
      case 'liveprog':
        setLiveprogEnabled(!lpEnabled);
      case 'crossfeed':
        setInt('crossfeed.enable', xfeedOn ? 0 : 1);
      case 'stereo':
        setStereoEnabled(!stereoOn);
      case 'reverb':
        if (reverbPreset >= 0) {
          setInt('reverb.preset', -1);
        } else {
          // -1→preset 0；-2→重申自定义（setSpatialReverbEnabled 内保护，
          // 直接 setReverbPreset(0) 会吃掉自定义参数）。
          setSpatialReverbEnabled(true);
        }
      case 'output':
        setInt('limiter.enable', limiterOn ? 0 : 1);
    }
  }

  // ---- Liveprog 脚本 ----

  void setLiveprogCode(String text) {
    lpError = null;
    lpCode = text;
    lpPresetCodeMismatch = false;
    lpCompileMs = -1;
    send({'cmd': 'setParamStr', 'id': ParamId.lpCode, 'text': text});
    // 单一默认值源（v2 §3.2）：脚本内 sliderN: 声明优先。
    // 引擎 LoadCode 已把 8 滑块清零，这里全量回推对齐；声明签名不变时
    // 保留用户已调值（只做回推），声明变化才采纳新默认值。
    // 同一 isolate SendPort 保序：code → 默认值 → 调用方后续值。
    final metas = EelSliderParser.parse(text);
    final sig = StringBuffer();
    for (var i = 1; i <= 8; i++) {
      final meta = metas[i];
      if (meta != null) {
        sig.write('$i:${meta.defaultVal}:${meta.minVal}:${meta.maxVal};');
      }
    }
    if (sig.toString() != _lpDeclSig) {
      _lpDeclSig = sig.toString();
      for (var i = 1; i <= 8; i++) {
        final meta = metas[i];
        if (meta != null) {
          var d = meta.defaultVal;
          if (meta.minVal <= meta.maxVal) {
            d = d.clamp(meta.minVal, meta.maxVal);
          }
          lpParams[i - 1] = d;
        }
      }
    }
    for (var i = 0; i < 8; i++) {
      setLiveprogParam(i, lpParams[i]);
    }
    scheduleAutoSave();
  }

  void setLiveprogEnabled(bool on) {
    lpEnabled = on;
    _notifyUi();
    _markSent(ParamId.lpEnable);
    send({
      'cmd': 'setParam',
      'id': ParamId.lpEnable,
      'value': on ? 1 : 0,
      'isFloat': false,
    });
    scheduleAutoSave();
  }

  void unloadLiveprog() {
    lpEnabled = false;
    lpStatus = 0;
    lpError = null;
    lpPresetCodeMismatch = false;
    lpCompileMs = -1;
    // v2 §3.2：不再清 lpCode——编辑器内容即真相，卸载只关使能；
    // 下次应用同签名代码时滑块值予以保留（见 setLiveprogCode）。
    _notifyUi();
    _markSent(ParamId.lpUnload);
    send({
      'cmd': 'setParam',
      'id': ParamId.lpUnload,
      'value': 0,
      'isFloat': false,
    });
    scheduleAutoSave();
  }

  void setLiveprogParam(int index, double v) {
    setFloat('liveprog.param${index + 1}', v);
  }

  // ---- 卷积 / VDC / DDC ----

  /// 卷积使能：废除品质档拦截限制，无条件自由放行
  void setConvolverEnabled(bool on, {String? autoQualityMsg}) {
    convEnabled = on;
    if (on && !convReady) {
      if (convIrPath != null &&
          convIrPath!.isNotEmpty &&
          File(convIrPath!).existsSync()) {
        loadConvolverIr(convIrPath!);
      }
    }
    _notifyUi();
    _markSent(ParamId.convEnable);
    // Auto-bypass：即使无 IR 文件，也如实下发 enable 状态。
    // 底层引擎在 ir_ready=0 时自动内部直通 (Convolver1DDisable)，
    // 回读也能如实反映 convEnable=1，避免无文件开启后被回读冲刷关闭。
    send({
      'cmd': 'setParam',
      'id': ParamId.convEnable,
      'value': on ? 1 : 0,
      'isFloat': false,
    });
    scheduleAutoSave();
  }

  void loadConvolverIr(String path) {
    convIrPath = path;
    // 字符串参数复用 setParamStr 通道；meta 由 paramResult→getParams 回读
    send({'cmd': 'setParamStr', 'id': ParamId.convIrPath, 'text': path});
    scheduleAutoSave();
  }

  void clearConvolver() {
    convEnabled = false;
    convReady = false;
    convIrPath = null;
    convFrames = convChannels = convSrcRate = 0;
    convPeak = 0;
    convSpectrum = [];
    _notifyUi();
    _markSent(ParamId.convClear);
    send({
      'cmd': 'setParam',
      'id': ParamId.convClear,
      'value': 0,
      'isFloat': false,
    });
    scheduleAutoSave();
  }

  void parseVdcMetadata(String path) {
    try {
      final f = File(path);
      if (!f.existsSync()) return;
      ddcFileName = path.split(RegExp(r'[\\/]')).last;
      final lines = f.readAsLinesSync();
      final rates = <String>[];
      int maxPoles = 0;
      for (final line in lines) {
        if (line.startsWith('SR_')) {
          final parts = line.split(':');
          if (parts.isNotEmpty) {
            final sr = parts[0].replaceAll('SR_', '');
            rates.add('$sr Hz');
            if (parts.length > 1) {
              final coeffs = parts[1].split(',');
              final stages = coeffs.length ~/ 5;
              if (stages > maxPoles) maxPoles = stages;
            }
          }
        }
      }
      ddcDetails = rates.isNotEmpty
          ? '${rates.join(', ')} · ${maxPoles > 0 ? '$maxPoles 阶双二阶' : '校准矩阵'}'
          : '已解析校准矩阵';
    } catch (e, st) {
      swallow(e, st);
      ddcFileName = path.split(RegExp(r'[\\/]')).last;
      ddcDetails = '已加载校准文件';
    }
  }

  void loadVdc(String path) {
    ddcPath = path;
    parseVdcMetadata(path);
    send({'cmd': 'setParamStr', 'id': ParamId.ddcLoad, 'text': path});
    // D3：字符串参数走 meta 通道，不主动 getParams 的话 ddcReady 永远不会
    // 翻转，卡片就一直停在「未加载」且 ddcReady 驱动的 UI 不刷新。
    _toIso?.send({'cmd': 'getParams'});
    scheduleAutoSave();
    _notifyUi();
  }

  void setDdcEnabled(bool on) {
    ddcOn = on;
    if (on && !ddcReady) {
      if (ddcPath != null &&
          ddcPath!.isNotEmpty &&
          File(ddcPath!).existsSync()) {
        loadVdc(ddcPath!);
      }
    }
    // 同卷积：auto-bypass，UI 开关与引擎生效状态解耦。
    // 必须直接 send 而不能用 setInt —— _mirror 会把 ddcEnable 镜像回 ddcOn
    // (state.dart:760)，下发 0 会把刚打开的开关立刻翻回关闭态。
    _markSent(ParamId.ddcEnable);
    send({
      'cmd': 'setParam',
      'id': ParamId.ddcEnable,
      'value': (on && ddcReady) ? 1 : 0,
      'isFloat': false,
    });
    // 绕过 setInt 后原本由它代劳的 UI 刷新没了，必须自己通知。
    // 漏掉这行会导致「关不掉」——模型已改但界面不重绘，直到别处触发刷新才生效。
    _notifyUi();
    scheduleAutoSave();
  }
}
