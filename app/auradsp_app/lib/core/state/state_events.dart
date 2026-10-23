// part of state.dart —— P3 按区拆分，extension 包装零逻辑改动。
part of '../state.dart';

/// isolate 事件路由（_onMessage 全量 case）+ 同因事件去重 + 延迟探测。
///
/// 方法体逐字保留自 AppModel 类体（notifyListeners() 按 P2 约定改调
/// _notifyUi()；类 static 引用加 AppModel. 限定——extension 作用域
/// 不含被扩展类型的 static 成员）。

/// 同因事件去重窗口（ms）。原为 AppModel 类 static const，随 _admitEngineEvent
/// 迁入本文件顶层——extension 方法体不能非限定引用类 static；仅去重逻辑使用，
/// 无外部调用者。
const int _kEventDedupWindowMs = 5000;

extension StateEvents on AppModel {
  void _onMessage(dynamic raw) {
    if (raw is! Map) return;
    switch (raw['evt'] as String) {
      case 'isoReady':
        _toIso = raw['port'] as SendPort;
        if (!TrayService.instance.isWindowVisible.value) {
          send({'cmd': 'setVizSuspended', 'value': true});
        }
        break;
      case 'ready':
        info = EngineInfo(
          raw['abi'] as int,
          raw['version'] as String,
          raw['deviceRate'] as int,
          raw['deviceCh'] as int,
          raw['bufferFrames'] as int,
        );
        // 协商采样率可能与请求值不同：EQ 网格必须按实际引擎采样率重建，
        // 否则曲线、响应和生产链使用三套不同的频率假设。
        _rebuildEqGridForSampleRate(notify: false);
        latencyMs = (raw['latencyMs'] as num).toDouble();
        conn = EngineConn.ready;
        engineState = 1;
        _fatalRetries = 0; // 活过来了，backoff 计数清零
        // 输出恢复即清除降级标记（deviceRate>0 = 真有设备）。
        if ((raw['deviceRate'] as num?)?.toInt() != 0) wasapiError = '';
        _notifyUi();
        if (!config.autoRestoreSession) {
          _toIso?.send({'cmd': 'getParams'});
        }
        // 持久化的是 VB 模式：就绪后自动进桥（与用户上次状态一致）。
        if (audioMode == 'vbcallback') {
          _toIso?.send({'cmd': 'vbmode', 'on': true});
        }
        // 插件级预设数据：厂商表 + 编辑器隔离名单（引擎跳过 removed()），
        // 就绪后加载并下发 close 名单；同时检查上一进程崩溃日志做自动登记。
        pluginManager.loadPluginTables();
        // 持久化的是 ASIO 模式：就绪后自动进桥（isolate 内部自带 detect）。
        if (audioMode == 'asio') {
          _toIso?.send({
            'cmd': 'asiomode',
            'on': true,
            'driver': config.asioDriver,
            'bufSize': config.asioBufSize,
            'outPair': config.asioOutPair,
          });
        }
        // 持久化的是 AuraVAIO 模式：就绪后自动进桥。
        if (audioMode == 'vaio') {
          _toIso?.send({
            'cmd': 'vaiomode',
            'on': true,
            'outputEndpoint': config.vaioOutputEndpoint,
          });
        }
        // 会话回放必须落在音频后端就绪之后：VB/ASIO/VAIO 模式下桥引擎才是
        // 真正的处理路径，提前回放会把插件装到本地引擎、随后建桥时镜像为空
        // （表现为重启后插件未挂载）。
        if (config.autoRestoreSession) {
          replaySessionToEngine();
        }
        // isolate 重启（采样率切换）：标准 session 回放只管参数，不管音源选择
        // 与 bypass 开关——这里补推（model 级状态是真相源）。
        if (_pendingRestartPush) {
          _pendingRestartPush = false;
          if (bypass) send({'cmd': 'bypass', 'value': true});
          send({'cmd': 'source51', 'value': source51Mode});
          if (sourceKind.isNotEmpty) {
            send({
              'cmd': 'source',
              'kind': sourceKind,
              'path': sourcePath.isEmpty ? null : sourcePath,
            });
            playing = true;
          } else {
            playing = false;
          }
          _notifyUi();
        }
        break;
      case 'params':
        // 决策 #4 对账守卫：用户触发（防抖）的回读若在发出后又有新编辑，
        // 则该轮回读已过期——采用会把最新改动回滚成旧值，直接丢弃。
        // 连接期/重放期回读（_readbackPending=false）不设防，照常全量采用。
        if (_readbackPending) {
          _readbackPending = false;
          if (_lastEditAt > _readbackRequestedAt) break;
        }
        bassOn = (raw['bassEnable'] as int) != 0;
        bassGain = (raw['bassGain'] as num).toDouble();
        reverbPreset = raw['reverbPreset'] as int;
        // 引擎真相是 0..stereoWidenMax，换算回 UI 显示刻度 0..1。
        // 开关关闭时引擎侧是"静音语义"的 0（_pushStereoChain 的 k=0 直发），
        // 不代表用户滑块记忆——2026-10-19 修复：旧实现无条件回写，用户
        // 关着开关退出后，下次启动回放推 0 → readback 把 UI 滑块清零 →
        // autoSave 再把 0 存回会话（会话记忆被静默销毁；用户打开开关时
        // 又被 setStereoEnabled 的兜底拉回 0.5，表现为"滑块自己跑到 50%"）。
        if (raw['stereoEnable'] != null) {
          stereoOn = (raw['stereoEnable'] as int) != 0;
        }
        if (stereoOn && raw['stereoMix'] != null) {
          stereoMix = ((raw['stereoMix'] as num).toDouble() / stereoWidenMax)
              .clamp(0.0, 1.0);
        }
        eqOn = (raw['eqEnable'] as int) != 0;
        postGain = (raw['postGain'] as num).toDouble();
        limiterOn = (raw['limiterEnable'] as int) != 0;
        lpEnabled = (raw['lpEnable'] as int) != 0;
        lpStatus = raw['lpStatus'] as int;
        convEnabled = (raw['convEnable'] as int) != 0;
        convReady = (raw['convReady'] as int) != 0;
        // auto-bypass 的另一半：资源在此刻就绪且用户开关为开 → 立即生效，
        // 无需用户再拨一次开关。
        if (convReady && convEnabled) {
          _markSent(ParamId.convEnable);
          send({
            'cmd': 'setParam',
            'id': ParamId.convEnable,
            'value': 1,
            'isFloat': false,
          });
        }
        convFrames = raw['convFrames'] as int;
        convChannels = raw['convChannels'] as int;
        convSrcRate = raw['convSrcRate'] as int;
        convPeak = (raw['convPeak'] as num).toDouble();
        if (raw['convSpectrum'] != null) {
          convSpectrum = (raw['convSpectrum'] as List)
              .map((e) => (e as List).cast<double>().toList())
              .toList();
        } else if (!convReady) {
          convSpectrum = [];
        }
        tubeOn = (raw['tubeEnable'] as int) != 0;
        // P-011：电子管音色/混合/补偿回读
        if (raw['tubeStyle'] != null) {
          tubeStyle = (raw['tubeStyle'] as int).clamp(0, 2);
        }
        if (raw['tubeMix'] != null) {
          tubeMix = (raw['tubeMix'] as num).toDouble().clamp(0.0, 1.0);
        }
        if (raw['tubeCompensation'] != null) {
          tubeCompensation = (raw['tubeCompensation'] as num).toDouble().clamp(
            -12.0,
            12.0,
          );
        }
        xfeedOn = (raw['xfeedEnable'] as int) != 0;
        if (raw['xfeedMode'] != null) xfeedMode = raw['xfeedMode'] as int;
        if (raw['xfeedFcut'] != null) {
          xfeedFcut = (raw['xfeedFcut'] as num).toDouble();
        }
        if (raw['xfeedFeed'] != null) {
          xfeedFeed = (raw['xfeedFeed'] as num).toDouble();
        }
        stereoBandUsed = (raw['stereoBandUsed'] as int) != 0;
        convMix = (raw['convMix'] as num).toDouble();
        // auto-bypass 的另一半：资源此刻就绪且用户开关为开 → 立即生效。
        // 同样必须直接 send，绕开 _mirror 对 ddcOn 的回写（否则开关被翻回）。
        if (ddcReady && ddcOn && (raw['ddcEnable'] as int) == 0) {
          _markSent(ParamId.ddcEnable);
          send({
            'cmd': 'setParam',
            'id': ParamId.ddcEnable,
            'value': 1,
            'isFloat': false,
          });
        }
        shelfOn = (raw['shelfEnable'] as int) != 0;
        shelfFreq = (raw['shelfFreq'] as num).toDouble().clamp(40.0, 400.0);
        shelfGain = (raw['shelfGain'] as num).toDouble();
        if (raw['bassmonoEnable'] != null) {
          bassmonoOn = (raw['bassmonoEnable'] as int) != 0;
        }
        if (raw['bassmonoFreq'] != null) {
          bassmonoFreq = (raw['bassmonoFreq'] as num).toDouble();
        }
        if (raw['haasEnable'] != null) {
          haasOn = (raw['haasEnable'] as int) != 0;
        }
        if (raw['haasDelay'] != null) {
          haasDelayMs = (raw['haasDelay'] as num).toDouble();
        }
        if (raw['haasMix'] != null) {
          haasMix = (raw['haasMix'] as num).toDouble();
        }
        if (raw['haasSide'] != null) {
          haasSide = (raw['haasSide'] as int) != 0 ? 1 : 0;
        }
        if (raw['spatialEnable'] != null) {
          spatialOn = (raw['spatialEnable'] as int) != 0;
        }
        if (raw['spatialStyle'] != null) {
          spatialStyle = (raw['spatialStyle'] as int).clamp(0, 2);
        }
        if (raw['spatialRoom'] != null) {
          spatialRoom = (raw['spatialRoom'] as num).toDouble();
        }
        if (raw['spatialWidth'] != null) {
          spatialWidth = (raw['spatialWidth'] as num).toDouble();
        }
        if (raw['spatialCenter'] != null) {
          spatialCenter = (raw['spatialCenter'] as num).toDouble();
        }
        if (raw['spatialOutGain'] != null) {
          spatialOutGain = (raw['spatialOutGain'] as num).toDouble();
        }
        if (raw['spatialAutoGain'] != null) {
          spatialAutoGain = (raw['spatialAutoGain'] as int) != 0;
        }
        if (raw['spatialMix'] != null) {
          spatialMix = (raw['spatialMix'] as num).toDouble();
        }
        if (raw['spatialElevation'] != null) {
          spatialElevation = (raw['spatialElevation'] as num).toDouble();
        }
        if (raw['spatialBinaural'] != null) {
          spatialBinaural = (raw['spatialBinaural'] as int) != 0;
        }
        if (raw['spatialFdn'] != null) {
          spatialFdn = (raw['spatialFdn'] as int) != 0;
        }
        if (raw['spatialLate'] != null) {
          spatialLate = (raw['spatialLate'] as num).toDouble();
        }
        if (raw['spatialHeadAzim'] != null) {
          spatialHeadAzim = (raw['spatialHeadAzim'] as num).toDouble();
        }
        if (raw['spatialHeadTrack'] != null) {
          spatialHeadTrack = (raw['spatialHeadTrack'] as int) != 0;
        }
        if (raw['exciterEnable'] != null) {
          exciterOn = (raw['exciterEnable'] as int) != 0;
        }
        if (raw['exciterAmount'] != null) {
          exciterAmount = (raw['exciterAmount'] as num).toDouble();
        }
        if (raw['exciterHifreq'] != null) {
          exciterHifreq = (raw['exciterHifreq'] as num).toDouble();
        }
        // P-010：每效果输出增益门 + 自动补偿
        if (raw['bassOutGain'] != null) {
          bassOutputGain = (raw['bassOutGain'] as num).toDouble();
        }
        if (raw['bassAutoGain'] != null) {
          bassAutoGain = (raw['bassAutoGain'] as int) != 0;
        }
        if (raw['eqOutGain'] != null) {
          eqOutputGain = (raw['eqOutGain'] as num).toDouble();
        }
        if (raw['eqAutoGain'] != null) {
          eqAutoGain = (raw['eqAutoGain'] as int) != 0;
        }
        if (raw['tubeOutGain'] != null) {
          tubeOutputGain = (raw['tubeOutGain'] as num).toDouble();
        }
        if (raw['tubeAutoGain'] != null) {
          tubeAutoGain = (raw['tubeAutoGain'] as int) != 0;
        }
        if (raw['compOutGain'] != null) {
          compOutputGain = (raw['compOutGain'] as num).toDouble();
        }
        if (raw['compAutoGain'] != null) {
          compAutoGain = (raw['compAutoGain'] as int) != 0;
        }
        if (raw['reverbOutGain'] != null) {
          reverbOutputGain = (raw['reverbOutGain'] as num).toDouble();
        }
        if (raw['reverbAutoGain'] != null) {
          reverbAutoGain = (raw['reverbAutoGain'] as int) != 0;
        }
        if (raw['exciterOversample'] != null) {
          exciterOversample = (raw['exciterOversample'] as int) != 0;
        }
        if (raw['tubeOversample'] != null) {
          tubeOversample = (raw['tubeOversample'] as int) != 0;
        }
        if (raw['limiterRelease'] != null) {
          limiterReleaseMs = (raw['limiterRelease'] as num).toDouble();
        }
        if (raw['limiterThreshold'] != null) {
          limiterThreshold = (raw['limiterThreshold'] as num).toDouble();
        }
        if (raw['limiterLink'] != null) {
          limiterLink = (raw['limiterLink'] as int) != 0;
        }
        if (raw['limiterLookahead'] != null) {
          limiterLookahead = (raw['limiterLookahead'] as int) != 0;
        }
        if (raw['gateHysteresis'] != null) {
          gateHysteresis = (raw['gateHysteresis'] as num).toDouble();
        }
        if (raw['gateRange'] != null) {
          gateRange = (raw['gateRange'] as num).toDouble();
        }
        if (raw['gateHoldMs'] != null) {
          gateHoldMs = (raw['gateHoldMs'] as num).toDouble();
        }
        if (raw['gateEnable'] != null) gateOn = (raw['gateEnable'] as int) != 0;
        if (raw['gateThreshold'] != null) {
          gateThreshold = (raw['gateThreshold'] as num).toDouble();
        }
        if (raw['gateAttack'] != null) {
          gateAttackMs = (raw['gateAttack'] as num).toDouble();
        }
        if (raw['gateRelease'] != null) {
          gateReleaseMs = (raw['gateRelease'] as num).toDouble();
        }
        if (raw['gateAutoGain'] != null) {
          gateAutoGain = (raw['gateAutoGain'] as int) != 0;
        }
        if (raw['deesserEnable'] != null) {
          deesserOn = (raw['deesserEnable'] as int) != 0;
        }
        if (raw['deesserFreq'] != null) {
          deesserFreq = (raw['deesserFreq'] as num).toDouble();
        }
        if (raw['deesserAmount'] != null) {
          deesserAmount = (raw['deesserAmount'] as num).toDouble();
        }
        if (raw['dyneqEnable'] != null) {
          dyneqOn = (raw['dyneqEnable'] as int) != 0;
        }
        if (raw['dyneqAttack'] != null) {
          dyneqAttackMs = (raw['dyneqAttack'] as num).toDouble();
        }
        if (raw['dyneqRelease'] != null) {
          dyneqReleaseMs = (raw['dyneqRelease'] as num).toDouble();
        }
        if (raw['dyneqB1Attack'] != null) {
          dyneqB1Attack = (raw['dyneqB1Attack'] as num).toDouble();
        }
        if (raw['dyneqB1Release'] != null) {
          dyneqB1Release = (raw['dyneqB1Release'] as num).toDouble();
        }
        if (raw['dyneqB2Attack'] != null) {
          dyneqB2Attack = (raw['dyneqB2Attack'] as num).toDouble();
        }
        if (raw['dyneqB2Release'] != null) {
          dyneqB2Release = (raw['dyneqB2Release'] as num).toDouble();
        }
        if (raw['dyneqB3Attack'] != null) {
          dyneqB3Attack = (raw['dyneqB3Attack'] as num).toDouble();
        }
        if (raw['dyneqB3Release'] != null) {
          dyneqB3Release = (raw['dyneqB3Release'] as num).toDouble();
        }
        if (raw['dyneqLowEnable'] != null) {
          dyneqLowOn = (raw['dyneqLowEnable'] as int) != 0;
        }
        if (raw['dyneqLowFreq'] != null) {
          dyneqLowFreq = (raw['dyneqLowFreq'] as num).toDouble();
        }
        if (raw['dyneqLowQ'] != null) {
          dyneqLowQ = (raw['dyneqLowQ'] as num).toDouble();
        }
        if (raw['dyneqLowGain'] != null) {
          dyneqLowGain = (raw['dyneqLowGain'] as num).toDouble();
        }
        if (raw['dyneqLowRange'] != null) {
          dyneqLowRange = (raw['dyneqLowRange'] as num).toDouble();
        }
        if (raw['dyneqLowThreshold'] != null) {
          dyneqLowThreshold = (raw['dyneqLowThreshold'] as num).toDouble();
        }
        if (raw['dyneqMidEnable'] != null) {
          dyneqMidOn = (raw['dyneqMidEnable'] as int) != 0;
        }
        if (raw['dyneqMidFreq'] != null) {
          dyneqMidFreq = (raw['dyneqMidFreq'] as num).toDouble();
        }
        if (raw['dyneqMidQ'] != null) {
          dyneqMidQ = (raw['dyneqMidQ'] as num).toDouble();
        }
        if (raw['dyneqMidGain'] != null) {
          dyneqMidGain = (raw['dyneqMidGain'] as num).toDouble();
        }
        if (raw['dyneqMidRange'] != null) {
          dyneqMidRange = (raw['dyneqMidRange'] as num).toDouble();
        }
        if (raw['dyneqMidThreshold'] != null) {
          dyneqMidThreshold = (raw['dyneqMidThreshold'] as num).toDouble();
        }
        if (raw['dyneqHighEnable'] != null) {
          dyneqHighOn = (raw['dyneqHighEnable'] as int) != 0;
        }
        if (raw['dyneqHighFreq'] != null) {
          dyneqHighFreq = (raw['dyneqHighFreq'] as num).toDouble();
        }
        if (raw['dyneqHighQ'] != null) {
          dyneqHighQ = (raw['dyneqHighQ'] as num).toDouble();
        }
        if (raw['dyneqHighGain'] != null) {
          dyneqHighGain = (raw['dyneqHighGain'] as num).toDouble();
        }
        if (raw['dyneqHighRange'] != null) {
          dyneqHighRange = (raw['dyneqHighRange'] as num).toDouble();
        }
        if (raw['dyneqHighThreshold'] != null) {
          dyneqHighThreshold = (raw['dyneqHighThreshold'] as num).toDouble();
        }
        if (raw['loudnessEnable'] != null) {
          loudnessOn = (raw['loudnessEnable'] as int) != 0;
        }
        if (raw['loudnessAmount'] != null) {
          loudnessAmount = (raw['loudnessAmount'] as num).toDouble();
        }
        if (raw['bassHarmonics'] != null) {
          bassHarmonics = (raw['bassHarmonics'] as num).toDouble();
        }
        if (raw['bassHarmonicBlend'] != null) {
          bassHarmonicBlend = (raw['bassHarmonicBlend'] as num).toDouble();
        }
        if (raw['bassSubFreq'] != null) {
          bassSubFloor = (raw['bassSubFreq'] as num).toDouble();
        }
        if (raw['bassCutoffF'] != null) {
          bassCutoff = (raw['bassCutoffF'] as num).toDouble();
        }
        if (raw['filterEnable'] != null) {
          filterOn = (raw['filterEnable'] as int) != 0;
        }
        if (raw['filterType'] != null) {
          filterType = (raw['filterType'] as int).clamp(0, 2);
        }
        if (raw['filterFreq'] != null) {
          filterFreq = (raw['filterFreq'] as num).toDouble();
        }
        if (raw['filterQ'] != null) {
          filterQ = (raw['filterQ'] as num).toDouble();
        }
        if (raw['fvEnable'] != null) fvOn = (raw['fvEnable'] as int) != 0;
        if (raw['fvDecay'] != null) {
          fvDecay = (raw['fvDecay'] as num).toDouble();
        }
        if (raw['fvDamp'] != null) fvDamp = (raw['fvDamp'] as num).toDouble();
        if (raw['fvWet'] != null) fvWet = (raw['fvWet'] as num).toDouble();
        if (raw['fvDry'] != null) fvDry = (raw['fvDry'] as num).toDouble();
        if (raw['compEnable'] != null) compOn = (raw['compEnable'] as int) != 0;
        if (raw['compTimeconstant'] != null) {
          compTimeconstant = (raw['compTimeconstant'] as num).toDouble();
        }
        if (raw['compGranularity'] != null) {
          compGranularity = raw['compGranularity'] as int;
        }
        if (raw['compTfresolution'] != null) {
          compTfresolution = raw['compTfresolution'] as int;
        }
        if (raw['compFreqs'] is List) {
          final list = (raw['compFreqs'] as List)
              .map((e) => (e as num).toDouble())
              .toList();
          for (var i = 0; i < math.min(list.length, compFreqs.length); i++) {
            compFreqs[i] = list[i];
          }
        }
        if (raw['compGains'] is List) {
          final list = (raw['compGains'] as List)
              .map((e) => (e as num).toDouble())
              .toList();
          for (var i = 0; i < math.min(list.length, compGains.length); i++) {
            compGains[i] = list[i];
          }
        }
        if (raw['arbmagReady'] != null) {
          arbmagReady = (raw['arbmagReady'] as int) != 0;
        }
        if (raw['arbmagNodeCount'] != null) {
          arbmagNodeCount = raw['arbmagNodeCount'] as int;
        }
        /* 字符串回读对账（预设 §8.1 / 调研 §1.2-1.3；null=引擎无副本或超 cap）：
         * - lpCode：编辑器内容即真相（v2 铁律）——只在本地为空时补位，
         *   绝不覆盖用户正在编辑的文本；用于引擎重起后回填与分叉检测。
         * - arbmagString：引擎是已应用曲线的真相源（可能被解析器钳位/规范化），
         *   非空即采纳，m 副本与之对齐。
         * - eqCurve：引擎回显的是下发原串（引擎存原串副本，不重序列化）——
         *   存独立对账字段，不回灌 eqGains/eqFreqs（避免 toStringAsFixed(1)
         *   舍入漂移与用户拖拽打架）。 */
        final rbLp = raw['lpCode'];
        if (rbLp is String &&
            rbLp.isNotEmpty &&
            (lpCode == null || lpCode!.isEmpty)) {
          lpCode = rbLp;
        }
        final rbArb = raw['arbmagString'];
        if (rbArb is String && rbArb.isNotEmpty && rbArb != arbmagString) {
          arbmagString = rbArb;
        }
        final rbEq = raw['eqCurve'];
        if (rbEq is String) engineEqCurve = rbEq.isEmpty ? null : rbEq;
        if (raw['arbmagEnable'] != null) {
          final en = (raw['arbmagEnable'] as int) != 0;
          if (arbmagReady && arbmagOn && !en) {
            _markSent(ParamId.arbmagEnable);
            send({
              'cmd': 'setParam',
              'id': ParamId.arbmagEnable,
              'value': 1,
              'isFloat': false,
            });
          } else if (!arbmagOn || arbmagReady) {
            arbmagOn = en;
          }
        }

        // P3: 全量回读补齐此前遗漏的 14 类参数（输入/增益/分带/混响/EQ/EEL2/链顺序等）
        if (raw['inputGain'] != null) {
          inputGain = (raw['inputGain'] as num).toDouble();
        }
        if (raw['inputBalanceL'] != null) {
          inputBalanceL = (raw['inputBalanceL'] as num).toDouble();
        }
        if (raw['inputBalanceR'] != null) {
          inputBalanceR = (raw['inputBalanceR'] as num).toDouble();
        }
        if (raw['tubeGain'] != null) {
          tubeGain = (raw['tubeGain'] as num).toDouble();
        }
        if (raw['stereoEnable'] != null) {
          stereoOn = (raw['stereoEnable'] as int) != 0;
        }
        if (raw['stereoBands'] is List) {
          final bands = (raw['stereoBands'] as List);
          // B4 对账（D-2）：引擎 raw 值 = (band*stereoMix*2).clamp(0,1)*stereoWidenMax*k，
          // 逆换算回 UI 刻度；stereo 关闭（k=0）或 mix=0 时引擎侧恒 0，跳过对账保留 UI 记忆值。
          if (stereoOn && stereoMix > 0.0 && stereoWidenMax > 0.0) {
            final denom = stereoMix * 2.0;
            for (var i = 0; i < bands.length && i < 5; i++) {
              final eff = (bands[i] as num).toDouble();
              final norm = (eff / stereoWidenMax).clamp(0.0, 1.0);
              stereoBands[i] = (norm / denom).clamp(0.0, 1.0);
            }
          }
        }
        if (raw['fvRoomSize'] != null) {
          fvRoomSize = (raw['fvRoomSize'] as num).toDouble();
        }
        if (raw['fvWidth'] != null) {
          fvWidth = (raw['fvWidth'] as num).toDouble();
        }
        if (raw['eqBandsCount'] != null) {
          eqBandsCount = raw['eqBandsCount'] as int;
        }
        if (raw['eqFilter'] != null) eqFilter = raw['eqFilter'] as int;
        if (raw['eqInterp'] != null) eqInterp = raw['eqInterp'] as int;
        if (raw['eqQ'] != null) eqQ = (raw['eqQ'] as num).toDouble();
        if (raw['bassMode'] != null) bassMode = raw['bassMode'] as int;
        if (raw['bassIntensity'] != null) {
          bassIntensity = (raw['bassIntensity'] as num).toDouble();
        }
        if (raw['lpParams'] is List) {
          final lpp = (raw['lpParams'] as List);
          for (var i = 0; i < lpp.length && i < 8; i++) {
            lpParams[i] = (lpp[i] as num).toDouble();
          }
        }
        if (raw['chainOrder'] is String &&
            (raw['chainOrder'] as String).isNotEmpty) {
          graphOrder = raw['chainOrder'] as String;
        }

        // P3: 全量同步至通用字典 _paramValues，保证 SSOT 与引擎状态绝对一致
        for (final spec in ParamRegistry.allParams) {
          _paramValues[spec.id] = spec.read(this);
        }

        _notifyUi();
        break;
      case 'arbmag':
        arbmagNodeCount = (raw['nodes'] as int?) ?? 0;
        arbmagReady = (raw['ready'] as int?) == 1;
        if (arbmagReady && arbmagOn) {
          _markSent(ParamId.arbmagEnable);
          send({
            'cmd': 'setParam',
            'id': ParamId.arbmagEnable,
            'value': 1,
            'isFloat': false,
          });
        }
        _notifyUi();
        break;
      case 'liveprog':
        lpStatus = raw['status'] as int;
        if (lpStatus == 1) lpError = null;
        _notifyUi();
        break;
      case 'fatal':
        conn = EngineConn.fatal;
        fatalMsg = raw['msg'] as String;
        _notifyUi();
        // 设备被占是持续态（对端独占释放前不会好）：backoff 重起，
        // 5 次约 10s 还起不来才认命留 fatal 屏。其它错误直接留屏。
        if (fatalMsg?.contains('0x8889000a') == true) {
          _scheduleFatalRetry();
        }
        break;
      case 'wasapiLost':
        // 运行中端点被独占（旧 client 在对端释放前永好不了）：只有还在进程内
        // 模式才重起；用户若已切走（桥模式），忽略（桥侧自有重建/状态）。
        if (audioMode != 'vbcallback' && audioMode != 'asio') {
          _fatalRetries = 0;
          _restartIsolate();
          _notifyUi();
        }
        break;
      case 'wasapiError':
        // 输出缺失但引擎正常：不清 fatal、不红屏，设备卡展示原因 + 重试。
        wasapiError = (raw['msg'] as String?) ?? 'output unavailable';
        _notifyUi();
        break;
      case 'state':
        engineState = raw['state'] as int;
        latencyMs = (raw['latencyMs'] as num).toDouble();
        _notifyUi();
        break;
      case 'playing':
        playing = raw['playing'] as bool;
        if (raw['srcCh'] is int) {
          fileChannels = (raw['srcCh'] as int).clamp(1, 8);
        }
        _notifyUi();
        break;
      case 'paramResult':
        final rc = raw['rc'] as int;
        final id = raw['id'] as String;
        final t0 = _pendingSentAt.remove(id);
        if (t0 != null) {
          // 点击 → 引擎确认 的回环耗时（定位"生效慢"到底慢在哪一段）
          dbgLog(
            'rt $id = ${DateTime.now().millisecondsSinceEpoch - t0}ms rc=$rc',
          );
        }
        // v3：脚本编译耗时回传（成功失败都记，供胶囊展示）
        if (id == ParamId.lpCode && raw['tookMs'] is int) {
          lpCompileMs = raw['tookMs'] as int;
        }
        if (rc != 0) {
          final msg = (raw['msg'] as String?) ?? 'engine rc=$rc';
          dbgLog('engine reject id=$id rc=$rc raw=$msg'); // B-2：原始串只进 dbgLog
          // 引擎拒绝 → 回读引擎真相，抹掉 _mirror 的乐观假象
          // （否则界面会一直显示"已选中"，但引擎里根本没生效）。
          // 回写与提示解耦：被同因抑制时依然要回读。
          _toIso?.send({'cmd': 'getParams'});
          // 同因抑制（见 _admitEngineEvent）：批量路径下同一拒绝会连成
          // 串 SnackBar；窗口内只提示第一次。
          if (!_admitEngineEvent('guard|$id|$msg')) break;
          lastGuard = GuardRejection(id, msg, rc);
          if (id == ParamId.lpCode || id.startsWith('liveprog.')) {
            lpError = lastGuard!.message; // 编辑页内联标红用
          }
          eventSeq.value = ++_guardSeq;
          _notifyUi();
        } else if (id == ParamId.convIrPath) {
          // IR 加载成功 → 回读 meta（frames/channels/srcRate/peak）
          _toIso?.send({'cmd': 'getParams'});
        }
        break;
      case 'viz':
        if (!TrayService.instance.isWindowVisible.value) break;
        spectrum.value = (raw['spectrum'] as List).cast<double>();
        if (raw['eqIn'] != null) {
          eqInSpectrum.value = (raw['eqIn'] as List).cast<double>();
        }
        levelL.value = (raw['l'] as num).toDouble();
        levelR.value = (raw['r'] as num).toDouble();
        if (raw['stageL'] != null) {
          final sL = (raw['stageL'] as List)
              .cast<num>()
              .map((e) => e.toDouble())
              .toList();
          stageLevelsL.value = sL;
          if (sL.length >= 30) {
            grLimiter.value = sL[24];
            grComp.value = sL[25];
            grGate.value = sL[26];
            grDyneqLow.value = sL[27];
            grDyneqMid.value = sL[28];
            grDyneqHigh.value = sL[29];
          }
        }
        if (raw['stageR'] != null) {
          stageLevelsR.value = (raw['stageR'] as List)
              .cast<num>()
              .map((e) => e.toDouble())
              .toList();
        }
        if (raw['inputInL'] != null) {
          inputMeterInL.value = (raw['inputInL'] as num).toDouble();
        }
        if (raw['inputInR'] != null) {
          inputMeterInR.value = (raw['inputInR'] as num).toDouble();
        }
        if (raw['inputOutL'] != null) {
          inputMeterOutL.value = (raw['inputOutL'] as num).toDouble();
        }
        if (raw['inputOutR'] != null) {
          inputMeterOutR.value = (raw['inputOutR'] as num).toDouble();
        }
        break;
      case 'error':
        final msg = raw['msg'] as String;
        dbgLog('engine error raw=$msg'); // B-2：原始串只进 dbgLog
        // 同因抑制：与 guard 拒绝共用一套窗口（isolate 侧 pump 错误已有
        // 3s 节流，但 paramResult 拒绝没有任何节流，UI 侧必须兜底）。
        if (!_admitEngineEvent('error|$msg')) break;
        lastEngineError = msg;
        eventSeq.value = ++_guardSeq;
        _notifyUi();
        break;
      case 'vbstatus':
        final was = vbActive;
        vbActive = (raw['running'] as bool?) ?? false;
        vbInfo = Map<String, dynamic>.from(raw);
        if (vbActive && !was) {
          // VB 上升沿：清掉上一会话的残留帧，基线归零，活数据随后流入。
          // A5（2026-10-22 审查）：进 VB 时编辑器目标路可能还是上一会话
          // 的 -2 哨兵或已失效路——回落最低有效路，避免插件页落入
          // 「无路可操作」态（A/B 与 Ch 曾被 group=-1 拖活）。
          _fallbackVbPluginEditorGroup();
          spectrum.value = List<double>.filled(32, 0.0);
          eqInSpectrum.value = List<double>.filled(32, 0.0);
          levelL.value = -90.0;
          levelR.value = -90.0;
          grLimiter.value = 0.0;
          grComp.value = 0.0;
          grGate.value = 0.0;
          grDyneqLow.value = 0.0;
          grDyneqMid.value = 0.0;
          grDyneqHigh.value = 0.0;
          // 长度必须与声明一致（kEngineStageCount=12；此前误写 5，
          // _StageStereoMeter 按 0..18 索引，越界回退 -120 造成 LED 恒灭）。
          stageLevelsL.value = List<double>.filled(kEngineStageCount, -90.0);
          stageLevelsR.value = List<double>.filled(kEngineStageCount, -90.0);
        }
        // P0-2：1s 心跳只推 hbTick（高频读数组件），粗通知仅在 running
        // 翻转等结构变化时发——避免 IndexedStack 保活后离屏页每秒重建。
        hbTick.value++;
        if (was != vbActive) _notifyUi();
        break;
      case 'asiostatus':
        final wasA = asioActive;
        asioActive = (raw['running'] as bool?) ?? false;
        asioInfo = Map<String, dynamic>.from(raw);
        if (asioActive && !wasA) {
          // ASIO 上升沿：同 VB——清残留帧，基线归零（长度同上，12）。
          spectrum.value = List<double>.filled(32, 0.0);
          eqInSpectrum.value = List<double>.filled(32, 0.0);
          levelL.value = -90.0;
          levelR.value = -90.0;
          grLimiter.value = 0.0;
          grComp.value = 0.0;
          grGate.value = 0.0;
          grDyneqLow.value = 0.0;
          grDyneqMid.value = 0.0;
          grDyneqHigh.value = 0.0;
          stageLevelsL.value = List<double>.filled(kEngineStageCount, -90.0);
          stageLevelsR.value = List<double>.filled(kEngineStageCount, -90.0);
        }
        // Phase 4：驱动请求重置（kAsioResetRequest，采样率/设备变化等）→
        // 复用热切换（stop→start 新参数；C++ 侧 start 时清标志，不会循环）。
        if (asioActive && (raw['resetPending'] as int? ?? 0) == 1) {
          _sendAsioRestart();
        }
        hbTick.value++;
        if (wasA != asioActive) _notifyUi();
        break;
      case 'vaiostatus':
        final wasV = vaioActive;
        vaioActive = (raw['running'] as bool?) ?? false;
        vaioInfo = Map<String, dynamic>.from(raw);
        if (vaioActive && !wasV) {
          spectrum.value = List<double>.filled(32, 0.0);
          eqInSpectrum.value = List<double>.filled(32, 0.0);
          levelL.value = -90.0;
          levelR.value = -90.0;
          stageLevelsL.value = List<double>.filled(kEngineStageCount, -90.0);
          stageLevelsR.value = List<double>.filled(kEngineStageCount, -90.0);
        }
        hbTick.value++;
        if (wasV != vaioActive) _notifyUi();
        break;
      case 'vaiodetect':
        vaioDetectInfo = Map<String, dynamic>.from(raw);
        _notifyUi();
        break;
      case 'asiodrivers':
        // 驱动清单（isolate 内 asio_detect 的结果；桥缺失/无驱动时 note 有原因）。
        asioDrivers = [
          for (final d in (raw['drivers'] as List?) ?? [])
            Map<String, String>.from(d as Map),
        ];
        asioDriversNote = (raw['note'] as String?) ?? '';
        _notifyUi();
        break;
      case 'pluginScanProgress':
        // C2：扫描分块推进中的进度回执（已处理候选 / 候选总数 / 已发现插件）。
        pluginManager.onPluginScanProgress(
          raw['done'] as int? ?? 0,
          raw['total'] as int? ?? 0,
          raw['found'] as int? ?? 0,
        );
        // 不 notifyListeners 由被监听对象自身触发（见 onPluginScanProgress），
        // 这里仅保证 UI 至少刷新一次。
        _notifyUi();
        break;
      case 'pluginScanned':
        pluginManager.onPluginScanned(raw['count'] as int, raw['json']);
        _notifyUi();
        break;
      case 'pluginList':
        pluginManager.onPluginList(raw['json']);
        _notifyUi();
        break;
      case 'pluginLoaded':
        pluginManager.onPluginLoaded(
          raw['path'] as String,
          raw['rc'] as int,
          raw['status'],
        );
        scheduleAutoSave();
        _notifyUi();
        break;
      case 'pluginUnloaded':
        pluginManager.onPluginUnloaded(raw['rc'] as int, raw['status']);
        scheduleAutoSave();
        _notifyUi();
        break;
      case 'pluginBypass':
        pluginManager.onPluginBypass(raw['bypass'] as bool, raw['status']);
        scheduleAutoSave();
        _notifyUi();
        break;
      case 'pluginPdc':
        pluginManager.onPluginPdc(raw['pdc'] as bool, raw['rc'] as int);
        scheduleAutoSave();
        _notifyUi();
        break;
      case 'pluginStatus':
        pluginManager.onPluginStatus(raw['status']);
        _notifyUi();
        break;
      case 'pluginSlotLoaded':
        pluginManager.onPluginSlotLoaded(
          raw['slot'] as int,
          raw['path'] as String,
          raw['rc'] as int,
          raw['status'],
          (raw['stage'] as num).toInt(),
        );
        scheduleAutoSave();
        _notifyUi();
        break;
      case 'pluginSlotBusy':
        pluginManager.onPluginSlotBusy(raw['slot'] as int, raw['busy'] as bool);
        break;
      case 'pluginSlotUnloaded':
        pluginManager.onPluginSlotUnloaded(
          raw['slot'] as int,
          raw['rc'] as int,
          raw['status'],
        );
        scheduleAutoSave();
        _notifyUi();
        break;
      case 'pluginSlotBypass':
        pluginManager.onPluginSlotBypass(
          raw['slot'] as int,
          raw['bypass'] as bool,
          raw['status'],
        );
        scheduleAutoSave();
        _notifyUi();
        break;
      case 'pluginSlotStatus':
        pluginManager.onPluginSlotStatus(
          raw['slot'] as int,
          raw['status'],
          (raw['stage'] as num).toInt(),
        );
        // P1-1 路由锁定轮询兜底：编辑器打开态随 status 回执同步。
        final eoSlot = (raw['slot'] as num?)?.toInt() ?? 0;
        if (raw['editorOpen'] is bool) {
          pluginManager.onSlotEditorOpenPolled(
            eoSlot,
            raw['editorOpen'] as bool,
          );
        }
        _notifyUi();
        break;
      case 'pluginSlotInsertStage':
        pluginManager.onPluginSlotInsertStage(
          raw['slot'] as int,
          (raw['stage'] as num).toInt(),
          raw['rc'] as int,
        );
        scheduleAutoSave();
        _notifyUi();
        break;
      case 'pluginSlotChannels':
        pluginManager.onPluginSlotChannels(
          raw['slot'] as int,
          (raw['mask'] as num).toInt(),
          raw['rc'] as int,
          // A4（2026-10-22 审查）：回执携带下发路由，Dart 按路归位
          // （旧版恒写 _slotChannels，VB 任一路回执即污染 -1 路记忆）。
          group: (raw['group'] as num?)?.toInt() ?? -1,
        );
        scheduleAutoSave();
        _notifyUi();
        break;
      case 'pluginSlotEditorResult':
        // 此前该事件被发出却无人处理：插件原生 GUI 打开失败对用户完全静默。
        final slot = (raw['slot'] as num?)?.toInt() ?? 0;
        final isShow = raw['action'] == 'show';
        final ok = (raw['rc'] as num?)?.toInt() != 0;
        // P1-1：路由锁定状态同步（编辑器开/关回执）。
        pluginManager.onPluginSlotEditorResult(
          slot,
          isShow ? 'show' : 'close',
          ok,
        );
        if (ok) {
          lastInfo = isShow ? '插件 ${slot + 1} 界面已打开' : '插件 ${slot + 1} 界面已关闭';
        } else {
          lastEngineError = isShow
              ? '插件 ${slot + 1} 未能打开界面（该插件可能不提供 GUI，或初始化失败）'
              : '插件 ${slot + 1} 关闭界面失败';
        }
        eventSeq.value = ++_guardSeq;
        _notifyUi();
        break;
      case 'componentLatency':
        final comp = raw['comp'] as String? ?? '';
        final rc = (raw['rc'] as num?)?.toInt() ?? -2;
        final samples = (raw['samples'] as num?)?.toInt() ?? 0;
        _onComponentLatencyResult(comp, rc, samples);
        break;
      default:
        // 兜底：未知事件至少留痕，避免再次出现「发了但静默丢弃」。
        // 绝不 notifyListeners()，未知事件不应引发 UI 重建。
        break;
    }
  }

  // ---- 同因事件去重 ----

  /// 同因放行判定。true = 应提示；false = 抑制。
  bool _admitEngineEvent(String key) {
    final now = debugNowOverride ?? DateTime.now().millisecondsSinceEpoch;
    if (key == _lastEventKey && now - _lastEventAt < _kEventDedupWindowMs) {
      _lastEventAt = now;
      _lastEventSuppressed++;
      return false;
    }
    _lastEventKey = key;
    _lastEventAt = now;
    return true;
  }

  // ---- 底层异常信息清除 ----

  void clearAudioError() {
    lastAudioError = null;
    _notifyUi();
  }

  void clearVaioError() {
    lastVaioError = null;
    _notifyUi();
  }

  void clearAsioError() {
    lastAsioError = null;
    _notifyUi();
  }

  void clearApoError() {
    lastApoError = null;
    _notifyUi();
  }

  // ---- 组件延迟实测 ----

  void _onComponentLatencyResult(String comp, int rc, int samples) {
    _probing.remove(comp);
    // deviceRate 守卫：采样率未知/为 0 时 samples/deviceRate → NaN/Inf，
    // 会把徽标刷成 "NaN ms"（历史事故）。此时与失败同处理——清除旧值，
    // 卡片 Badge 静默保持「未测量」与 Tooltip 说明。
    if (rc == 0 && deviceRate > 0) {
      _measuredLatencyMs[comp] = samples / deviceRate * 1000.0;
    } else {
      _measuredLatencyMs.remove(comp);
    }
    _notifyUi();
  }

  /// 触发一次真实脉冲探测。
  /// 关键架构优化：采用独立后台 Isolate.run 异步执行，绝不塞进 audio_isolate 实时音频泵，
  /// 彻底消除测量时因阻塞音频泵循环引发的 WASAPI 缓冲区欠载爆音与声音卡顿。
  ///
  /// 2026-10-18：删除 haas / bass_shaping 两处「假测量」分支（延时 100~120ms
  /// 后把标称值写进 _measuredLatencyMs，冒充实测）。引擎 probe_is_supported
  /// 明确不支持这两者（haas 探针结构性失明，必测出 0ms；bass_shaping 在引擎
  /// 侧的探针名是 shelf，无此 id）。伪造「实测」比报「不可测」更危险，
  /// 现统一由 componentLatency 的 ≈ 标称态如实展示。
  Future<void> refreshComponentLatency(String compId) async {
    if (_probing.contains(compId)) return;

    // 2026-10-19：haas / spatial 探针已支持，全部组件均可真实测——「三档
    // 口径」的档位 3（结构性不可测）已不存在，全部走引擎脉冲实测。
    if (!AppModel.isLatencyProbeSupported(compId) &&
        !AppModel.kLatencyProbeAliases.containsKey(compId)) {
      _latencyRefreshTicks[compId] = DateTime.now().millisecondsSinceEpoch;
      _notifyUi();
      return;
    }

    _probing.add(compId);
    _latencyRefreshTicks[compId] = DateTime.now().millisecondsSinceEpoch;
    _notifyUi();

    // 别名探针——合并卡映射到引擎实名，逐段实测求和。
    final alias = AppModel.kLatencyProbeAliases[compId];
    final res = latencyProbeResource(compId) ?? '';
    final rate = info?.deviceRate.toDouble() ?? 48000.0;
    final enginePath = AuraDspLib.loadedPath;
    // haas 是纯延迟线，其"算法延迟"= 用户当前设定值。把 live 值传给引擎
    // 的 auradsp_probe_component_current，测出的才是当前口径——否则引擎
    // 会用出厂默认 12ms，与 compute_latency 动态上报脱节。
    final isHaas = compId == 'haas';
    final haasArg = haasDelayMs;

    try {
      final result = await Isolate.run(() {
        final l = AuraDspLib.load(enginePath);
        int probeOne(String name) {
          final out = malloc<Uint32>();
          final compPtr = name.toNativeUtf8();
          try {
            out.value = 0;
            int rc;
            if (name == 'haas' && isHaas) {
              rc = l.probeComponentCurrent(compPtr, haasArg, rate, out);
            } else if (res.isEmpty) {
              rc = l.probeComponent(compPtr, rate, out);
            } else {
              final p = res.toNativeUtf8();
              try {
                rc = l.probeComponentWithResource(compPtr, p, rate, out);
              } finally {
                malloc.free(p);
              }
            }
            return rc == 0 ? out.value.toInt() : -1;
          } finally {
            malloc.free(out);
            malloc.free(compPtr);
          }
        }

        // 单名直测；别名列表逐段求和（任一段失败即整体失败，不拼凑数字）。
        if (alias == null) {
          final s = probeOne(compId);
          return {'rc': s < 0 ? -1 : 0, 'samples': s < 0 ? 0 : s};
        }
        var total = 0;
        for (final name in alias) {
          final s = probeOne(name);
          if (s < 0) return {'rc': -1, 'samples': 0};
          total += s;
        }
        return {'rc': 0, 'samples': total};
      });
      _onComponentLatencyResult(
        compId,
        result['rc'] as int,
        result['samples'] as int,
      );
    } catch (_) {
      _onComponentLatencyResult(compId, -2, 0);
    }
  }

  /// 该组件实测所需的外部资源路径；无则返回 null（走无资源探针）。
  String? latencyProbeResource(String compId) {
    switch (compId) {
      case 'convolver':
        final p = convIrPath;
        return (p != null && p.isNotEmpty && File(p).existsSync()) ? p : null;
      case 'ddc':
        final p = ddcPath;
        return (p != null && p.isNotEmpty && File(p).existsSync()) ? p : null;
      default:
        return null;
    }
  }

  // ---- 探测状态查询 ----

  /// 探测进行中
  bool isProbingLatency(String compId) => _probing.contains(compId);
}
