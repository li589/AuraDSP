// part of state.dart —— P4 按区拆分，extension 包装零逻辑改动。
part of '../state.dart';

/// 会话回放 / 预设脏跟踪 / 防抖自动保存 / 主题本地化 / 自定义目录 / 采样率。
///
/// 方法体逐字保留自 AppModel 类体（notifyListeners() 按 P2 约定改调
/// _notifyUi()）。
extension StateSession on AppModel {
  // ---- 插件扫描目录（2026-10-28 改版，P-042） ----
  //
  // 语义：列表即真值——引擎只扫描 enabled 条目；平台预置目录首次播种后
  // 由用户全权管理（清空不再自动加回）；内置目录（随应用分发的插件）
  // 自动创建、恒启用、不可移除。

  /// 内置插件目录（未来自带开源/自研插件）。subDir 顺手完成创建。
  String get bundledPluginDir => ConfigManager.subDir('plugins').path;

  /// 启动时调用一次：保证内置条目存在 + 平台目录首次播种 + 同步扫描集。
  void ensurePluginScanDirs() {
    final dirs = config.pluginScanDirs;
    final builtinPath = bundledPluginDir;

    // 内置条目归一：只允许一条、恒启用、builtin 标记不可被配置篡改。
    dirs.removeWhere((e) => e.builtin && e.path != builtinPath);
    final idx = dirs.indexWhere((e) => e.path == builtinPath);
    if (idx >= 0) {
      dirs[idx] = dirs[idx].copyWith(enabled: true, builtin: true);
    } else {
      dirs.insert(
        0,
        PluginScanDirEntry(path: builtinPath, enabled: true, builtin: true),
      );
    }

    // 平台预置目录：仅首次播种（目录必须真实存在，见 PluginScanDirs.discover）。
    if (!config.pluginScanDirsSeeded) {
      final known = dirs
          .map((e) => Platform.isWindows ? e.path.toLowerCase() : e.path)
          .toSet();
      for (final p in PluginScanDirs.discover()) {
        final key = Platform.isWindows ? p.toLowerCase() : p;
        if (known.add(key)) {
          dirs.add(PluginScanDirEntry(path: p));
        }
      }
      config.pluginScanDirsSeeded = true;
    }

    ConfigManager.save(config);
    _syncPluginScanDirs();
  }

  void _syncPluginScanDirs() {
    pluginManager.setScanDirs(
      config.pluginScanDirs
          .where((e) => e.enabled)
          .map((e) => e.path)
          .toList(growable: false),
    );
  }

  void addPluginScanDir(String dir) {
    final path = dir.trim();
    if (path.isEmpty) return;
    final exists = config.pluginScanDirs.any(
      (e) => Platform.isWindows
          ? e.path.toLowerCase() == path.toLowerCase()
          : e.path == path,
    );
    if (exists) return;
    config.pluginScanDirs.add(PluginScanDirEntry(path: path));
    ConfigManager.save(config);
    _syncPluginScanDirs();
    _notifyUi();
  }

  /// 移除条目；内置目录拒绝移除（返回 false，UI 侧按钮本身也禁用）。
  bool removePluginScanDir(String dir) {
    final i = config.pluginScanDirs.indexWhere((e) => e.path == dir);
    if (i < 0) return false;
    if (config.pluginScanDirs[i].builtin) return false;
    config.pluginScanDirs.removeAt(i);
    ConfigManager.save(config);
    _syncPluginScanDirs();
    _notifyUi();
    return true;
  }

  /// 勾选/取消单个目录（内置目录恒启用）。
  void setPluginScanDirEnabled(String dir, bool enabled) {
    final i = config.pluginScanDirs.indexWhere((e) => e.path == dir);
    if (i < 0) return;
    final e = config.pluginScanDirs[i];
    if (e.builtin && !enabled) return;
    if (e.enabled == enabled) return;
    config.pluginScanDirs[i] = e.copyWith(enabled: enabled);
    ConfigManager.save(config);
    _syncPluginScanDirs();
    _notifyUi();
  }

  /// 全选 / 清除（清除 = 全部取消勾选；内置目录保持启用）。
  void setAllPluginScanDirsEnabled(bool enabled) {
    var changed = false;
    for (var i = 0; i < config.pluginScanDirs.length; i++) {
      final e = config.pluginScanDirs[i];
      final target = e.builtin ? true : enabled;
      if (e.enabled != target) {
        config.pluginScanDirs[i] = e.copyWith(enabled: target);
        changed = true;
      }
    }
    if (!changed) return;
    ConfigManager.save(config);
    _syncPluginScanDirs();
    _notifyUi();
  }

  // ---- 自定义脚本目录 ----

  void addCustomScriptDir(String dir) {
    final path = dir.trim();
    if (path.isNotEmpty && !config.customScriptDirs.contains(path)) {
      config.customScriptDirs.add(path);
      ConfigManager.save(config);
      _notifyUi();
    }
  }

  void removeCustomScriptDir(String dir) {
    if (config.customScriptDirs.remove(dir)) {
      ConfigManager.save(config);
      _notifyUi();
    }
  }

  // ---- 防抖自动保存 / 回读对账 / 脏标记 ----

  void scheduleAutoSave() {
    if (_testing || _isReplayingSession) return;
    _lastEditAt = DateTime.now().millisecondsSinceEpoch;
    _debounceSaveTimer?.cancel();
    _debounceSaveTimer = Timer(
      Duration(milliseconds: config.autoSaveDebounceMs),
      () {
        SessionMemory.save(this);
        // 决策 #4：参数风暴平息后防抖回读引擎，全量 getParams 对账。
        // 与 setParam 同端口 FIFO —— 读到的必含此前全部改动，无同端竞态。
        scheduleReadback();
      },
    );
  }

  /// 防抖回读（决策 #4）：拉一次引擎全量 getParams，'params' 事件归来后
  /// 由分支顶部守卫决定采用或丢弃。快速频繁改动时每个 settle 窗口
  /// （autoSaveDebounceMs）只花一次往返，不在 setter 热路径上。
  void scheduleReadback() {
    if (_testing || _isReplayingSession) return;
    _readbackPending = true;
    _readbackRequestedAt = DateTime.now().millisecondsSinceEpoch;
    _toIso?.send({'cmd': 'getParams'});
  }

  /// 重算「偏离已应用预设」脏标记并按需通知 UI（2026-10-16 决策 #3）。
  /// 生产路径：防抖自动保存回调（SessionMemory.save 内部）统一触发——
  /// 用户快速频繁改动时，每 500ms 只花一次 snapshot 指纹的开销；
  /// 测试（_testing）可直呼。
  bool evaluatePresetDirty() {
    final fp = PresetLibrary.fingerprintOf(this);
    final dirty =
        appliedPresetFingerprint != null && fp != appliedPresetFingerprint;
    if (dirty != presetDirty) {
      presetDirty = dirty;
      _notifyUi();
    }
    return dirty;
  }

  // ---- 会话回放 ----

  Future<void> replaySessionToEngine() async {
    _isReplayingSession = true;
    try {
      // 0. 输入门控（总增益与声道平衡）
      setFloat(ParamId.inputGain, inputGain);
      setFloat(ParamId.inputBalance(1), inputBalanceL);
      setFloat(ParamId.inputBalance(2), inputBalanceR);

      // [P-031] 声道模式必须随会话回放下发：它不在任何 ParamSection 里
      // （不预设持久化），此前恢复后 UI 分段控件显示"离散逐声道"，引擎却
      // 停在默认的矩阵模式——多声道策略在重启后静默降级。
      setInt('channels.mode', channelsMode);
      setInt('channels.countMode', channelsCountMode);
      if (channelsCountMode == 1) {
        setInt('channels.count', channelsCount);
      }

      // 1. 下发全量基础开关与数值
      setInt('bass.enable', bassOn ? 1 : 0);
      setFloat('bass.gain', bassGain);
      // [PATCHED-AuraDSP P-032] ViPER 模式（谐波配方宏）必须一并下发：
      // 它在会话快照里被保存，但本方法是手写清单（不遍历 spec）→ 此前
      // 恢复后引擎侧仍是 0，回读把 UI 的模式覆盖成"自然低音"。
      // 用 setInt 而非 setBassMode：配方（harmonics/blend）另行恢复，
      // 此处只同步模式状态，避免重写配方。
      setInt('bass.mode', bassMode);
      // 声场（v1.2）：开关位独立后，直发 bypass _mirror（旧 setFloat 会把
      // UI 的 mix/band 回写冲掉）；关闭时下发 0，UI 值保留。开时与旧行为一致。
      final stereoK = stereoOn ? 1.0 : 0.0;
      _markSent('stereo.mix');
      send({
        'cmd': 'setParam',
        'id': 'stereo.mix',
        'value': stereoMix * stereoWidenMax * stereoK,
        'isFloat': true,
      });
      if (stereoBandUsed) {
        setInt('stereo.bandUsed', 1);
        for (var i = 0; i < 5; i++) {
          final bandId = 'stereo.band${i + 1}';
          _markSent(bandId);
          send({
            'cmd': 'setParam',
            'id': bandId,
            'value': stereoBands[i] * stereoK,
            'isFloat': true,
          });
        }
      }
      setInt('tube.enable', tubeOn ? 1 : 0);
      setFloat('tube.gain', tubeGain);
      // P-011：电子管音色/混合/补偿
      setInt(ParamId.tubeStyle, tubeStyle);
      setFloat(ParamId.tubeMix, tubeMix);
      setFloat(ParamId.tubeCompensation, tubeCompensation);
      setInt(ParamId.tubeOversample, tubeOversample ? 1 : 0);
      setInt('crossfeed.enable', xfeedOn ? 1 : 0);
      setInt(ParamId.xfeedMode, xfeedMode);
      setFloat(ParamId.xfeedFcut, xfeedFcut);
      setFloat(ParamId.xfeedFeed, xfeedFeed);
      setInt('shelf.enable', shelfOn ? 1 : 0);
      setFloat('shelf.freq', shelfFreq);
      setFloat('shelf.gain', shelfGain);
      setInt(ParamId.bassmonoEnable, bassmonoOn ? 1 : 0);
      setFloat(ParamId.bassmonoFreq, bassmonoFreq);
      setInt(ParamId.bassmonoPairs, bassmonoPairs);
      setInt(ParamId.bassmonoMerge, bassmonoMerge);
      setInt(ParamId.haasEnable, haasOn ? 1 : 0);
      setFloat(ParamId.haasDelay, haasDelayMs);
      setFloat(ParamId.haasMix, haasMix);
      setInt(ParamId.haasSide, haasSide);
      setInt(ParamId.spatialEnable, spatialOn ? 1 : 0);
      // spatial.style 必须先于 room/width/center 下发：预设档的规范值由
      // 引擎 style hook 写入；再发三个参数会触发 custom hook 把 style 改成 3。
      // 旧会话曾把自定义态存成 0..2（UI 回读钳制所致）——若值与预设规范
      // 不符，按自定义（3）迁移，避免启动时被预设值覆盖。
      final spatialCustom = spatialStyle == 3 ||
          !_spatialMatchesPreset(
              spatialStyle, spatialRoom, spatialWidth, spatialCenter);
      if (spatialCustom && spatialStyle != 3) {
        spatialStyle = 3;
      }
      setInt(ParamId.spatialStyle, spatialStyle);
      if (spatialCustom) {
        setFloat(ParamId.spatialRoom, spatialRoom);
        setFloat(ParamId.spatialWidth, spatialWidth);
        setFloat(ParamId.spatialCenter, spatialCenter);
      }
      setFloat(ParamId.spatialOutGain, spatialOutGain);
      setInt(ParamId.spatialAutoGain, spatialAutoGain ? 1 : 0);
      setFloat(ParamId.spatialMix, spatialMix);
      setFloat(ParamId.spatialElevation, spatialElevation);
      setInt(ParamId.spatialBinaural, spatialBinaural ? 1 : 0);
      setFloat(ParamId.spatialHeadAzim, spatialHeadAzim);
      setInt(ParamId.spatialHeadTrack, spatialHeadTrack ? 1 : 0);
      _syncHeadTracker();
      setInt(ParamId.exciterEnable, exciterOn ? 1 : 0);
      setFloat(ParamId.exciterAmount, exciterAmount);
      setFloat(ParamId.exciterHifreq, exciterHifreq);
      setInt(ParamId.exciterOversample, exciterOversample ? 1 : 0);
      // P-010：每效果输出增益门 + 自动补偿
      setFloat(ParamId.bassOutGain, bassOutputGain);
      setInt(ParamId.bassAutoGain, bassAutoGain ? 1 : 0);
      setFloat(ParamId.eqOutGain, eqOutputGain);
      setInt(ParamId.eqAutoGain, eqAutoGain ? 1 : 0);
      setFloat(ParamId.tubeOutGain, tubeOutputGain);
      setInt(ParamId.tubeAutoGain, tubeAutoGain ? 1 : 0);
      setFloat(ParamId.compOutGain, compOutputGain);
      setInt(ParamId.compAutoGain, compAutoGain ? 1 : 0);
      setInt(ParamId.compMode, compMode);
      setFloat(ParamId.reverbOutGain, reverbOutputGain);
      setInt(ParamId.reverbAutoGain, reverbAutoGain ? 1 : 0);
      // 噪声门 + Deesser
      setInt(ParamId.gateEnable, gateOn ? 1 : 0);
      setFloat(ParamId.gateThreshold, gateThreshold);
      setFloat(ParamId.gateAttack, gateAttackMs);
      setFloat(ParamId.gateRelease, gateReleaseMs);
      setFloat(ParamId.gateHysteresis, gateHysteresis);
      setFloat(ParamId.gateRange, gateRange);
      setFloat(ParamId.gateHoldMs, gateHoldMs);
      setInt(ParamId.gateAutoGain, gateAutoGain ? 1 : 0);
      setInt(ParamId.deesserEnable, deesserOn ? 1 : 0);
      setFloat(ParamId.deesserFreq, deesserFreq);
      setFloat(ParamId.deesserAmount, deesserAmount);
      // 全参数动态EQ
      setInt(ParamId.dyneqEnable, dyneqOn ? 1 : 0);
      setFloat(ParamId.dyneqAttack, dyneqAttackMs);
      setFloat(ParamId.dyneqRelease, dyneqReleaseMs);
      setFloat(ParamId.dyneqB1Attack, dyneqB1Attack);
      setFloat(ParamId.dyneqB1Release, dyneqB1Release);
      setFloat(ParamId.dyneqB2Attack, dyneqB2Attack);
      setFloat(ParamId.dyneqB2Release, dyneqB2Release);
      setFloat(ParamId.dyneqB3Attack, dyneqB3Attack);
      setFloat(ParamId.dyneqB3Release, dyneqB3Release);
      setInt(ParamId.dyneqLowEnable, dyneqLowOn ? 1 : 0);
      setFloat(ParamId.dyneqLowFreq, dyneqLowFreq);
      setFloat(ParamId.dyneqLowQ, dyneqLowQ);
      setFloat(ParamId.dyneqLowGain, dyneqLowGain);
      setFloat(ParamId.dyneqLowRange, dyneqLowRange);
      setFloat(ParamId.dyneqLowThreshold, dyneqLowThreshold);
      setInt(ParamId.dyneqMidEnable, dyneqMidOn ? 1 : 0);
      setFloat(ParamId.dyneqMidFreq, dyneqMidFreq);
      setFloat(ParamId.dyneqMidQ, dyneqMidQ);
      setFloat(ParamId.dyneqMidGain, dyneqMidGain);
      setFloat(ParamId.dyneqMidRange, dyneqMidRange);
      setFloat(ParamId.dyneqMidThreshold, dyneqMidThreshold);
      setInt(ParamId.dyneqHighEnable, dyneqHighOn ? 1 : 0);
      setFloat(ParamId.dyneqHighFreq, dyneqHighFreq);
      setFloat(ParamId.dyneqHighQ, dyneqHighQ);
      setFloat(ParamId.dyneqHighGain, dyneqHighGain);
      setFloat(ParamId.dyneqHighRange, dyneqHighRange);
      setFloat(ParamId.dyneqHighThreshold, dyneqHighThreshold);
      setInt(ParamId.loudnessEnable, loudnessOn ? 1 : 0);
      setFloat(ParamId.loudnessAmount, loudnessAmount);
      setFloat(ParamId.bassHarmonics, bassHarmonics);
      setFloat(ParamId.bassHarmonicBlend, bassHarmonicBlend);
      setFloat(ParamId.bassSubFreq, bassSubFloor);
      setFloat(ParamId.bassCutoffF, bassCutoff);
      setInt(ParamId.filterEnable, filterOn ? 1 : 0);
      setInt(ParamId.filterType, filterType);
      setFloat(ParamId.filterFreq, filterFreq);
      setFloat(ParamId.filterQ, filterQ);
      setFloat(ParamId.arbmagOutGain, arbmagOutputGain);
      setInt(ParamId.arbmagAutoGain, arbmagAutoGain ? 1 : 0);
      setInt('limiter.enable', limiterOn ? 1 : 0);
      setFloat(ParamId.limiterRelease, limiterReleaseMs);
      setFloat(ParamId.limiterThreshold, limiterThreshold);
      setInt(ParamId.limiterLink, limiterLink ? 1 : 0);
      setInt(ParamId.limiterLookahead, limiterLookahead ? 1 : 0);
      setFloat('post.gain', postGain);
      for (var c = 0; c < 8; c++) {
        setFloat(ParamId.postGainCh(c), mirrorFloat(ParamId.postGainCh(c), 0.0));
      }

      // 动态压限器
      setFloat(ParamId.compTimeconstant, compTimeconstant);
      setInt(ParamId.compGranularity, compGranularity);
      setInt(ParamId.compTfresolution, compTfresolution);
      for (var i = 0; i < 7; i++) {
        setFloat('comp.freq${i + 1}', compFreqs[i]);
        setFloat('comp.gain${i + 1}', compGains[i]);
      }
      setInt(ParamId.compEnable, compOn ? 1 : 0);

      // 2. 混响（WP1：reverb.preset 是唯一开关；freeverb.* 只是自定义参数）
      setFloat('freeverb.decay', fvDecay);
      setFloat('freeverb.damp', fvDamp);
      setFloat('freeverb.wet', fvWet);
      setFloat('freeverb.dry', fvDry);
      setFloat('freeverb.roomsize', fvRoomSize);
      setFloat('freeverb.width', fvWidth);
      setFloat(ParamId.reverbPredelay, reverbPredelay);
      setInt(ParamId.reverbLfe, reverbLfe ? 1 : 0);
      setReverbPreset(reverbPreset);

      // 3. EQ 状态与曲线
      setInt('eq.enable', eqOn ? 1 : 0);
      _pushEqCurve();

      // 4. 外部文件自校验重载
      if (convIrPath != null &&
          convIrPath!.isNotEmpty &&
          File(convIrPath!).existsSync()) {
        loadConvolverIr(convIrPath!);
        if (convEnabled) setInt(ParamId.convEnable, 1);
      }
      // 干湿比有独立引擎参数，重启后必须重推，否则界面显示的混合比
      // 与引擎默认值不一致（“记忆与滑块打架”的成因之一）。
      setFloat('convolver.mix', convMix);
      if (ddcPath != null &&
          ddcPath!.isNotEmpty &&
          File(ddcPath!).existsSync()) {
        loadVdc(ddcPath!);
        if (ddcOn) setInt(ParamId.ddcEnable, 1);
      }
      if (lpCode != null && lpCode!.isNotEmpty) {
        setLiveprogCode(lpCode!);
        if (lpEnabled) setInt(ParamId.lpEnable, 1);
        // 脚本滑块 1..8 有独立引擎参数，重启后必须重推，
        // 否则界面显示的滑块值与引擎归零值不一致（同上）。
        for (var i = 0; i < 8 && i < lpParams.length; i++) {
          setFloat('liveprog.param${i + 1}', lpParams[i]);
        }
      }
      if (arbmagString.isNotEmpty) {
        setArbmagString(arbmagString);
        if (arbmagOn) {
          setInt(ParamId.arbmagEnable, 1);
        }
      }
      if (graphOrder != null && graphOrder!.isNotEmpty) {
        setGraphOrder(graphOrder!);
      }

      if (savedPluginPdc) {
        send({'cmd': 'pluginSetPdc', 'pdc': true});
      }

      if (savedPluginSlots.isNotEmpty) {
        for (final item in savedPluginSlots) {
          if (item.path.isNotEmpty && File(item.path).existsSync()) {
            send({
              'cmd': 'pluginSlotLoad',
              'slot': item.slot,
              'path': item.path,
              'id': item.id,
            });
            if (item.channels != 0xFF) {
              send({
                'cmd': 'pluginSlotSetChannels',
                'slot': item.slot,
                'mask': item.channels,
              });
            }
            // F-6（2026-10-23）：VB 各路 Ch 记忆随会话恢复。旧会话无此字段
            // （null）→ 保持原行为（回落 0xFF）。先播种 manager 记忆（UI
            // 立即可见），再对非默认路下发引擎。
            final rcMasks = item.routeChannels;
            if (rcMasks != null) {
              pluginManager.seedRouteChannels(item.slot, rcMasks);
              for (var g = 0; g < 8 && g < rcMasks.length; g++) {
                if (rcMasks[g] != 0xFF) {
                  send({
                    'cmd': 'pluginSlotSetChannels',
                    'slot': item.slot,
                    'mask': rcMasks[g],
                    'group': g,
                  });
                }
              }
            }
            if (item.stage != PluginInsertStage.defaultStage) {
              send({
                'cmd': 'pluginSlotSetInsertStage',
                'slot': item.slot,
                'stage': item.stage,
              });
            }
            // P-041（2026-10-28）：引擎挂载即旁路，回放必须**恒发**保存的
            // 旁路值——旧实现只发 true，保存为激活的槽挂载后被引擎挂载旁路
            // 卡死（无人下发 false）。
            send({
              'cmd': 'pluginSlotSetBypass',
              'slot': item.slot,
              'bypass': item.bypass,
            });
          }
        }
      } else if (savedPluginPath != null &&
          savedPluginPath!.isNotEmpty &&
          File(savedPluginPath!).existsSync()) {
        send({
          'cmd': 'pluginSlotLoad',
          'slot': 0,
          'path': savedPluginPath!,
          'id': savedPluginId,
        });
        // P-041：恒发保存的旁路值（挂载即旁路，激活槽必须显式解旁路）。
        send({'cmd': 'pluginSlotSetBypass', 'slot': 0, 'bypass': savedPluginBypass});
      }
    } finally {
      _isReplayingSession = false;
      _toIso?.send({'cmd': 'getParams'});
    }
  }

  // ---- 用户预设 / 主题 / 本地化 / 采样率 ----

  bool saveAsUserPreset(
    String name, {
    String category = 'Custom',
    String description = '',
  }) {
    final preset = PresetLibrary.snapshot(
      this,
      name: name,
      category: category,
      description: description,
    );
    final ok = PresetLibrary.saveUserPreset(preset);
    if (ok) {
      activePresetName = name;
      // 保存即锚定（决策 #3）：当前状态 = 该预设内容，脏标记归零。
      appliedPresetFingerprint = PresetLibrary.fingerprintOf(this);
      presetDirty = false;
    }
    _notifyUi();
    scheduleAutoSave();
    return ok;
  }

  void loadPreset(AuraPreset preset) {
    PresetLibrary.apply(this, preset);
    _notifyUi();
    scheduleAutoSave();
  }

  void setTheme(AuraThemeId id) {
    themeId = id;
    config.themeId = id.name;
    ConfigManager.save(config);
    _notifyUi();
    scheduleAutoSave();
  }

  void setLocale(Locale l) {
    locale = l;
    config.locale = l.languageCode;
    ConfigManager.save(config);
    _notifyUi();
    scheduleAutoSave();
  }

  void setAutoRestoreSession(bool enable) {
    config.autoRestoreSession = enable;
    if (_testing) {
      // 测试隔离：只改内存开关，不碰磁盘。
      _notifyUi();
      return;
    }
    ConfigManager.save(config);
    if (enable) {
      SessionMemory.save(this);
    } else {
      SessionMemory.clear();
    }
    _notifyUi();
  }

  void setSampleRate(int rate) {
    if (rate == config.sampleRate) return;
    config.sampleRate = rate;
    ConfigManager.save(config);
    _rebuildEqGridForSampleRate();
    if (audioMode == 'vbcallback' || audioMode == 'asio') {
      _notifyUi();
      return;
    }
    _pendingRestartPush = true;
    _restartIsolate();
    _notifyUi();
  }
}
