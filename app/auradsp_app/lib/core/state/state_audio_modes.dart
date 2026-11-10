// part of state.dart —— P6 按区拆分，extension 包装零逻辑改动。
part of '../state.dart';

/// 音频处理模式/管线 + 设备枚举 + VAIO 驱动 + ASIO 注册 + System APO 运维。
///
/// 方法体逐字保留自 AppModel 类体（notifyListeners() 按 P2 约定改调
/// _notifyUi()）。

extension AudioModesState on AppModel {

  // ---- 模式与管线 ----

  /// 进入 sysapo 时的文件型效果策略（2026-11-10 用户裁定）：
  /// 卷积/DDC 若开着则自动关闭（经正常 setParamById 路径，全链
  /// 同步）并通知一次；离开 sysapo 不自动恢复，由用户自行重开。
  /// setParam 侧另有开启拦截（见 state_core.setParam）。
  void applyApoFileEffectPolicy() {
    // ModeCaps 口径：仅在 fileEffects 不可用的模式下执行本策略
    // （当前只有 sysapo）；能力可用时整段为空操作，调用方无需
    // 再写模式判断。
    if (modeCaps.fileEffects) return;
    var turnedOff = false;
    for (final id in kApoFileEffectEnables) {
      final v = getParamById(id);
      if (v == true || (v is num && v != 0)) {
        setParamById(id, false);
        turnedOff = true;
      }
    }
    if (turnedOff) {
      postNotice('已进入 System APO 模式：卷积混响与 DDC 依赖外部文件、'
          '此模式下无法加载，已自动关闭', level: NoticeLevel.info);
    }
  }

  /// 音频处理模式切换：非法 id 直接忽略；合法即落盘 + 通知。
  /// vbcallback/asio 切入/切出时联动 isolate 启停对应桥（WASAPI 路径随之
  /// 暂停/恢复）；其余模式当前仅持久化选择（引擎接线待后续版本，重启生效）。
  void setAudioMode(String id) {
    final valid = AudioModes.normalize(id);
    config.modeCategory = AudioModes.categoryForMode(valid);
    if (config.modeCategory == AudioModes.categoryAttachment) {
      config.attachmentMode = (valid == 'vbcallback')
          ? AudioModes.attachVoicemeeterApi
          : AudioModes.attachSysApo;
    } else {
      // 模式↔输出端多对一：覆写口径收敛在
      // AudioModes.pipelineOutputForMode（非损，见其注释）。
      // Linux 不写（细审 R-D L8）：该纯函数是 Windows 管线
      // 口径，Linux 下会把 pipelineOutput 覆写成 'wasapi'
      // 惰性落盘（Linux 无消费者，污染配置无收益）。
      if (!PlatformProfile.isLinux) {
        config.pipelineOutput =
            AudioModes.pipelineOutputForMode(valid, config.pipelineOutput);
      }
    }
    if (valid == audioMode && config.audioMode == valid) return;
    // P2 边界：模式切换会重建引擎链路（插件重挂）——先把各槽 A/B 预设
    // 落盘并清理编辑器状态，避免调音丢失/锁定卡死。
    pluginManager.onAudioModeSwitching();
    final wasVb = audioMode == 'vbcallback';
    final isVb = valid == 'vbcallback';
    final wasAsio = audioMode == 'asio';
    final isAsio = valid == 'asio';
    final wasVaio = audioMode == 'vaio';
    final isVaio = valid == 'vaio';
    final linuxModeBefore = audioMode;
    audioMode = valid;
    config.audioMode = valid;
    // F-3：VB 多总线标志随模式切换更新。必须在 onAudioModeSwitching
    // （用旧语义落盘）之后、重挂恢复（异步事件）之前——恢复路径据此
    // 决定 -1 路是否合法。
    pluginManager.setVbMultiBus(isVb);
    pluginManager.setApoShadow(
        AudioModes.capsFor(valid).pluginProcessing == PluginProcessing.apo);
    persistRoutingChange();
    if (wasVb != isVb) {
      // 进桥先推掩码（isolate 记 session 变量，start 时同步进桥；桥未起时仅记录）。
      if (isVb) {
        _toIso?.send({'cmd': 'setBusMask', 'mask': vbBusMask});
        _toIso?.send({'cmd': 'setPluginGroupMask', 'mask': vbPluginGroupMask});
        _toIso?.send({'cmd': 'setPluginAutoProtect', 'on': config.vbAutoProtect});
      }
      _toIso?.send({'cmd': 'vbmode', 'on': isVb});
      if (!isVb) {
        vbActive = false;
        vbInfo = {};
      }
    }
    if (wasAsio != isAsio) {
      // asiomode 内部自带 detect（无论能否启动都回 asiodrivers 事件给设置页）。
      _toIso?.send({
        'cmd': 'asiomode',
        'on': isAsio,
        'driver': config.asioDriver,
        'bufSize': config.asioBufSize,
        'outPair': config.asioOutPair,
      });
      if (!isAsio) {
        asioActive = false;
        asioInfo = {};
      }
    }
    if (wasVaio != isVaio) {
      // 全接线：Windows 管线类别下链路由 composeChain 决定——
      // 合成链为 capture/asio 时不按模式发 vaiomode，统一由
      // 本函数末尾的 applyPipelineChain 分发（防先起 VAIO 桥
      // 再被捕获链/ASIO 桥拆掉的空转）。
      final chainBlocksVaio = isVaio &&
          PlatformProfile.supportsBridges &&
          config.modeCategory == AudioModes.categoryPipeline &&
          pipelineChain != PipelineChain.vaio;
      if (!chainBlocksVaio) {
        _toIso?.send({
          'cmd': 'vaiomode',
          'on': isVaio,
          'outputEndpoint': config.vaioOutputEndpoint,
        });
        // 崩溃断路器联动：手动进入 VAIO = 知情接管，解除跳过
        // 并重新布防；离开 VAIO（桥干净停）= 解除布防。
        if (isVaio) {
          vaioBootGuardTripped = false;
          _armVaioGuard();
        } else {
          _disarmVaioGuard();
        }
      }
      if (!isVaio) {
        vaioActive = false;
        vaioInfo = {};
      }
    }
    if (PlatformProfile.isLinux && linuxModeBefore != valid) {
      // ADR-012 D-5：Linux 模式变化时让 isolate 重组管线（virtual 建
      // 虚拟 sink + monitor 采集；driver 接 snd-aloop 源；system 拆除）。
      _toIso?.send({'cmd': 'linuxmode', 'mode': valid});
    }
    // APO 真处理通道（P1）：sysapo 生效期间让 isolate 轮询 APO
    // 回传块（电平/频谱合成 viz），并在进入时全量重发参数块；
    // 离开 sysapo 即停读。isolate 侧非 Windows 永久静默，无副作用。
    _toIso?.send({'cmd': 'apotelemetry', 'on': valid == 'sysapo'});
    if (valid == 'sysapo') {
      applyApoFileEffectPolicy();
      _toIso?.send({'cmd': 'apopublish'});
    } else if (apoEngineActive || apoEngineFault) {
      // 离开 sysapo：引擎状态面复位（读者已停，不再有事件回填）。
      apoEngineActive = false;
      apoEngineFault = false;
      apoEngineRate = 0;
      apoEngineChannels = 0;
      apoParamsApplied = 0;
      apoLoadStage = 0;
      apoLoadErr = 0;
    }
    applyPipelineChain();
    _notifyUi();
  }

  /// Linux 设备面板「刷新」：请求 isolate 重新探测 PA 设备并回推
  /// linuxstatus（不改管线，只刷新状态）。
  void refreshLinuxStatus() {
    if (!PlatformProfile.isLinux) return;
    _toIso?.send({'cmd': 'linuxstatus'});
  }

  /// Linux 音频后端切换（D-6 二期）：'pulse' | 'alsa'。后端在
  /// isolate 生成时由工厂按配置选定，切换须重启 isolate 生效
  /// （与「重试」同路径）；落盘 + 重启 + 通知。
  void setLinuxAudioBackend(String backend) {
    if (!PlatformProfile.isLinux) return;
    final v = backend == 'alsa' ? 'alsa' : 'pulse';
    if (config.linuxAudioBackend == v) return;
    config.linuxAudioBackend = v;
    persistRoutingChange();
    _restartIsolate();
    _notifyUi();
  }

  /// ALSA PCM 设备枚举（设置页设备编辑的下拉数据源）：FFI 直查
  /// libasound 的 device_name_hint；无库/失败返回空表（可手填）。
  List<String> listAlsaDevices({bool capture = false}) {
    if (!PlatformProfile.isLinux) return const [];
    return alsa_ffi.listAlsaPcmDeviceNames(capture: capture);
  }

  /// ALSA 输出设备名（专家模式）：落盘 + 重启 isolate 生效。
  void setAlsaOutputDevice(String device) {
    if (!PlatformProfile.isLinux) return;
    final v = device.trim();
    if (config.alsaOutputDevice == v) return;
    config.alsaOutputDevice = v;
    persistRoutingChange();
    if (config.linuxAudioBackend == 'alsa') _restartIsolate();
    _notifyUi();
  }

  /// ALSA 采集设备名（专家模式 driver 路径）：落盘 + 重启
  /// isolate 生效（采集设备在 isolate 构造时定死，同输出侧口径）。
  /// 打磨三期补齐：此前该字段只有配置与 isolate 消费、无设置入口，
  /// 非默认回环卡的用户只能手改配置文件。
  void setAlsaCaptureDevice(String device) {
    if (!PlatformProfile.isLinux) return;
    final v = device.trim();
    if (config.alsaCaptureDevice == v) return;
    config.alsaCaptureDevice = v;
    persistRoutingChange();
    if (config.linuxAudioBackend == 'alsa') _restartIsolate();
    _notifyUi();
  }

  /// ADR-009: 切换音频范式（附加模式 vs 普通管线模式）
  void setModeCategory(String category) {
    if (category != AudioModes.categoryAttachment &&
        category != AudioModes.categoryPipeline) {
      return;
    }
    config.modeCategory = category;
    final composed = AudioModes.composeMode(
      category: category,
      attachmentMode: config.attachmentMode,
      pipelineOut: config.pipelineOutput,
    );
    if (composed != audioMode) {
      setAudioMode(composed);
    } else {
      persistRoutingChange();
      _notifyUi();
    }
  }

  /// ADR-009: 切换附加模式子类型（System APO vs Voicemeeter API）
  void setAttachmentMode(String mode) {
    config.attachmentMode = mode;
    if (modeCategory == AudioModes.categoryAttachment) {
      final composed = AudioModes.composeMode(
        category: AudioModes.categoryAttachment,
        attachmentMode: mode,
      );
      if (composed != audioMode) {
        setAudioMode(composed);
      } else {
        // 漂移对账统一收口（全接线，2026-11-10）：旧实现在此
        // 内嵌 vaio/asio 补发，但附加类别下 composeMode 只产
        // sysapo/vbcallback，该补发实际不可达（详审待代码细
        // 审轮核销）；对账语义已由 applyPipelineChain 在
        // setPipelineInput/Output/setAudioMode/ready 各路统
        // 一承担，此处顺手收口捕获链状态。
        applyPipelineChain();
        persistRoutingChange();
        _notifyUi();
      }
    } else {
      persistRoutingChange();
      _notifyUi();
    }
  }

  /// 当前管线链路（仅管线类别内有意义；其余类别返回 null）。
  PipelineChain? get pipelineChain =>
      config.modeCategory == AudioModes.categoryPipeline
          ? AudioModes.composeChain(
              input: config.pipelineInput,
              output: config.pipelineOutput,
            )
          : null;

  /// 在枚举结果里按 id 或名称找端点（config 里存的设备值是
  /// 「id 优先、缺失时名称」的下拉 value，两种形态都要认）。
  AudioDeviceItem? _resolveWasapiDevice(String v) {
    if (v.isEmpty) return null;
    for (final d in wasapiDevices) {
      if (d.id == v || d.name == v) return d;
    }
    return null;
  }

  /// 设备值的规范 id（枚举命中且有 id 时用 id，否则原值；
  /// 空 = 默认端点）。
  String _deviceIdOf(String v) {
    final item = _resolveWasapiDevice(v);
    return (item != null && item.id.isNotEmpty) ? item.id : v;
  }

  /// 规范 id 层面的自激判定：双默认（细审 R-A H1——空值在
  /// isolate 侧都解为系统默认渲染端点，捕获它又写回它必反馈，
  /// 恰是零配置路径）或两 id 相等。
  bool _idsConflict(String capId, String outId) =>
      (capId.isEmpty && outId.isEmpty) ||
      (capId.isNotEmpty && outId.isNotEmpty && capId == outId);

  /// 输入/输出设备存值是否构成自激对（下拉互斥规格与起链守卫
  /// 共用同一口径，避免两处判定漂移）。
  bool _isFeedbackPair(String inputDevice, String outputDevice) {
    final capItem = _resolveWasapiDevice(inputDevice);
    final capId = (capItem != null && capItem.id.isNotEmpty)
        ? capItem.id
        : inputDevice;
    return _idsConflict(capId, _deviceIdOf(outputDevice));
  }

  /// 构造捕获链命令（含反馈守卫）：回录端点与输出端点是
  /// 同一设备时，我们的渲染会被自己抓回形成自激——拒绝
  /// 起链并返回 null（调用方负责提示/停链）。
  Map<String, dynamic>? _captureCommand(String cmd) {
    final capItem = _resolveWasapiDevice(config.pipelineInputDevice);
    final capId = (capItem != null && capItem.id.isNotEmpty)
        ? capItem.id
        : config.pipelineInputDevice;
    final outId = _deviceIdOf(config.pipelineOutputDevice);
    if (_idsConflict(capId, outId)) {
      dbgLog(capId.isEmpty && outId.isEmpty
          ? 'pipeline.capture: feedback pair blocked (both default)'
          : 'pipeline.capture: feedback pair blocked (cap==out)');
      return null;
    }
    return {
      'cmd': cmd,
      'captureEndpoint': capId,
      // 下拉默认项与渲染端点 = 回录；录音端点 = 直采。
      'loopback': capItem?.isRender ?? true,
      'outputEndpoint': outId,
    };
  }

  /// 管线链路唯一下发方（全接线）：按 composeChain 的合成
  /// 结果对齐 isolate 侧链路——切输入、切输出、切模式、
  /// 就绪恢复都经此收口，杜绝「选择只落盘、链路不动」的
  /// 漂移。桥链起停与 isolate 侧互斥（stopOtherBridges +
  /// start* 拆捕获链）叠加，本函数只按状态位做增量对账。

  // VAIO 崩溃断路器布防/解除（testing 构造不落盘，与会话存盘
  // 同口径；守卫语义见 vaio_boot_guard.dart）。
  void _armVaioGuard() {
    if (_testing) return;
    VaioBootGuard.arm(ConfigManager.dataDir);
  }

  void _disarmVaioGuard() {
    if (_testing) return;
    VaioBootGuard.disarm(ConfigManager.dataDir);
  }

  void applyPipelineChain() {
    if (!PlatformProfile.supportsBridges) return;
    final chain = pipelineChain;
    if (chain == PipelineChain.capture) {
      final payload = _captureCommand('capturemode');
      if (payload == null) {
        if (captureActive) {
          _toIso?.send({'cmd': 'capturemode', 'on': false});
          captureActive = false; // 与非捕获分支同口径本地清位（细审 R-A L3）
        }
        postNotice('输入与输出为同一端点，回录会自激啸叫，已阻止启动捕获链',
            level: NoticeLevel.warning);
        return;
      }
      if (!captureActive) {
        payload['on'] = true;
        _toIso?.send(payload);
        dbgLog('pipeline.chain: capturemode on');
      }
      return;
    }
    // 非捕获链：捕获链若在跑必须停（离开管线类别同理）。
    if (captureActive) {
      _toIso?.send({'cmd': 'capturemode', 'on': false});
      captureActive = false;
      dbgLog('pipeline.chain: capturemode off');
    }
    if (chain == PipelineChain.vaio && !vaioActive) {
      // 断路器跳过期内对账不得把桥偷偷补起来（用户手动选
      // VAIO 清除 tripped 后本门自然放行）。
      if (vaioBootGuardTripped) {
        dbgLog('pipeline.reconcile: vaiomode resend suppressed (breaker)');
        return;
      }
      dbgLog('pipeline.reconcile: resend vaiomode (vaioActive=false)');
      _toIso?.send({
        'cmd': 'vaiomode',
        'on': true,
        'outputEndpoint': config.vaioOutputEndpoint,
      });
      _armVaioGuard();
    } else if (chain == PipelineChain.asio && !asioActive) {
      dbgLog('pipeline.reconcile: resend asiomode (asioActive=false)');
      _toIso?.send({
        'cmd': 'asiomode',
        'on': true,
        'driver': config.asioDriver,
        'bufSize': config.asioBufSize,
        'outPair': config.asioOutPair,
      });
    }
  }

  /// 设备下拉变更（输入/输出端点）：捕获链在跑时热重建，
  /// 未跑但合成结果是捕获链时顺势起链；其余链路不消费
  /// 这两个字段（VAIO 落点是 vaioOutputEndpoint、ASIO 是
  /// 驱动参数），不动。
  void _pipelineDeviceChanged() {
    if (!PlatformProfile.supportsBridges) return;
    if (pipelineChain != PipelineChain.capture) return;
    if (!captureActive) {
      applyPipelineChain();
      return;
    }
    final payload = _captureCommand('capturerestart');
    if (payload == null) {
      _toIso?.send({'cmd': 'capturemode', 'on': false});
      postNotice('输入与输出为同一端点，回录会自激啸叫，已停止捕获链',
          level: NoticeLevel.warning);
      return;
    }
    _toIso?.send(payload);
    dbgLog('pipeline.chain: capturerestart');
  }

  /// ADR-009: 切换管线输入源（Virtual ASIO / AuraVAIO / WASAPI）
  void setPipelineInput(String inType) {
    config.pipelineInput = inType;
    // 全接线：输入第一次真实驱动链路（此前只落盘——真机项
    // 4「切输入无反应、链路靠输出点击带起来」的根源）。
    applyPipelineChain();
    persistRoutingChange();
    _notifyUi();
  }

  /// ADR-009: 切换管线输出端（WASAPI Render / AuraVAIO / ASIO Client）
  void setPipelineOutput(String outType) {
    config.pipelineOutput = outType;
    if (modeCategory == AudioModes.categoryPipeline) {
      final composed = AudioModes.composeMode(
        category: AudioModes.categoryPipeline,
        pipelineOut: outType,
      );
      if (composed != audioMode) {
        setAudioMode(composed);
      } else {
        // 模式未变也要对账链路（输入侧合成可能已变、桥可能
        // 已漂移）：applyPipelineChain 统一承担。
        applyPipelineChain();
        persistRoutingChange();
        _notifyUi();
      }
    } else {
      persistRoutingChange();
      _notifyUi();
    }
  }

  void setPipelineInputDevice(String device) {
    config.pipelineInputDevice = device;
    // 互斥规格（第四轮项 2）：新输入与已选输出撞成自激对时，
    // 输出自动让位到第一个不冲突的渲染设备（下拉层已撤下该
    // 项，这里收口存量冲突）；无候选则保留原值——输出下拉呈
    // 置灰「无可用声卡」、起链守卫继续兜底。不清成 ''：'' 本
    // 身即默认端点别名，清值等于换一种撞法。
    if (config.pipelineOutput == AudioModes.outputWasapi &&
        _isFeedbackPair(device, config.pipelineOutputDevice)) {
      for (final d in filteredWasapiOutputs) {
        final v = d.id.isNotEmpty ? d.id : d.name;
        if (!_isFeedbackPair(device, v)) {
          config.pipelineOutputDevice = v;
          dbgLog('pipeline.devices: output auto-moved off input device');
          break;
        }
      }
    }
    _pipelineDeviceChanged();
    persistRoutingChange();
    _notifyUi();
  }

  void setPipelineOutputDevice(String device) {
    config.pipelineOutputDevice = device;
    _pipelineDeviceChanged();
    persistRoutingChange();
    _notifyUi();
  }

  void setPipelineInputEnabled(bool enabled) {
    config.pipelineInputEnabled = enabled;
    persistRoutingChange();
    _notifyUi();
  }

  void setPipelineOutputEnabled(bool enabled) {
    config.pipelineOutputEnabled = enabled;
    persistRoutingChange();
    _notifyUi();
  }

  // ---- 设备枚举 ----

  /// 刷新所有 WASAPI 端点与音频设备。
  ///
  /// V-02 加固（2026-11-09）：三个「刷新设备」按钮均未 await 本方法，
  /// 任何未捕获异常都会变成未处理异步错误——故全程守卫、绝不上抛；
  /// 端点工具缺失时显式置 lastAudioError（旧行为是整段静默跳过，
  /// 用户点刷新毫无反馈）；关键节点写 dbgLog 埋点，真机再现闪退时
  /// 可凭日志尾迹定位死在哪一段。
  Future<void> refreshAudioDevices() async {
    dbgLog('devices.refresh: start', sync: true);
    try {
      refreshVaioDetect();
    } catch (e, st) {
      swallow(e, st);
    }
    if (_testing || !PlatformProfile.supportsBridges) return;
    try {
      final exePath = _findApoInspectExe();
      if (exePath == null) {
        dbgLog('devices.refresh: apo_inspect unavailable', sync: true);
        lastAudioError = '端点探测工具不可用（apo_inspect.exe 缺失）';
        _notifyUi();
        return;
      }
      {
        final res =
            await windowsSystem.inspectAudioDevices(
          exePath,
        );
        // 细分埋点（真机报告 2026-11-09 §1.1b：驱动区刷新闪退新点）：
        // 与 I/O 区刷新共用本方法且后者正常，故把 inspect 返回、
        // 解析空集、通知后三段分开记日志尾，下次复现凭尾迹定段。
        dbgLog('devices.refresh: inspect exit=${res.exitCode}', sync: true);
        if (res.exitCode == 0) {
          final stdout = (res.stdout as String).trim();
          final lines = stdout.split('\n');
          final lastLine = lines.isNotEmpty ? lines.last.trim() : '';
          if (lastLine.isNotEmpty) {
            final json = jsonDecode(lastLine) as Map<String, dynamic>;
            final eps = (json['endpoints'] as List?) ?? [];
            final items = <AudioDeviceItem>[];
            for (final ep in eps) {
              if (ep is Map) {
                final name = (ep['name'] as String?) ?? '';
                final dir = (ep['direction'] as String?) ?? 'render';
                final id = (ep['id'] as String?) ?? '';
                final state = (ep['state'] as num?)?.toInt() ?? 1;
                if (name.isNotEmpty && state == 1) {
                  items.add(
                    AudioDeviceItem(
                      id: id,
                      name: name,
                      isRender: dir == 'render',
                      active: true,
                    ),
                  );
                }
              }
            }
            if (items.isNotEmpty) {
              wasapiDevices = items;
              lastAudioError = null;
              dbgLog('devices.refresh: done n=${items.length}', sync: true);
              _notifyUi();
              dbgLog('devices.refresh: notified', sync: true);
            } else {
              dbgLog('devices.refresh: no endpoints parsed', sync: true);
            }
          } else {
            dbgLog('devices.refresh: empty stdout', sync: true);
          }
        } else {
          dbgLog('devices.refresh: inspect failed', sync: true);
          lastAudioError = '端点探测工具退出异常 (代码: ${res.exitCode})';
          _notifyUi();
        }
      }
    } catch (e) {
      dbgLog('devices.refresh: error $e', sync: true);
      lastAudioError = '刷新音频设备失败: $e';
      _notifyUi();
    }
  }

  // ---- 辅助可执行文件查找（统一走 WindowsSystemPort）----
  //
  // 定位口径（2026-11-09 收口，V-01/V-03 共同根因）：一律随包优先
  // （findInstalledFile，以可执行文件目录为基准的 driver/ 扁平布局）、
  // 源码树兜底（findRepoFile，仅开发期成立）。bundled 标记随命中结果
  // 一路带到 port 命令拼装：随包脚本与开发脚本的参数口径不同。

  String? _findApoInspectExe() =>
      windowsSystem.findInstalledFile(const ['driver/apo_inspect.exe']) ??
      windowsSystem.findRepoFile(const [
        'core/desktop/windows-drivers/out/Release/apo_inspect.exe',
      ]);

  ({String path, bool bundled})? _findVaioInstallScript() {
    final bundled = windowsSystem
        .findInstalledFile(const ['driver/install_vaio.ps1']);
    if (bundled != null) return (path: bundled, bundled: true);
    final repo = windowsSystem.findRepoFile(const [
      'core/desktop/windows-drivers/01_vaio_driver/install_driver.ps1',
    ]);
    if (repo != null) return (path: repo, bundled: false);
    return null;
  }

  // ---- VAIO 驱动安装 ----

  /// 一键 UAC 提权安装 AuraVAIO 虚拟声卡驱动
  ///
  /// 诚实口径（真机报告 2026-11-09 §2.2）：脚本退出码为 0 不等于
  /// 安装成功——未开启测试签名的 Win11 上驱动包可被暂存而设备
  /// 始终不出现。故装后必须等一次 vaiodetect 复检，found 为真才
  /// 报成功；脚本成功但复检不符置 [vaioActionUnverified]，通知层
  /// 改走未生效文案，不再假报成功。
  Future<bool> installVaioDriver({bool elevated = true}) async {
    if (!PlatformProfile.supportsBridges) return false;
    vaioActionUnverified = false;
    try {
      final hit = _findVaioInstallScript();
      if (hit == null) {
        lastVaioError = '未找到 VAIO 驱动安装脚本（随包 driver/install_vaio.ps1 缺失）';
        // V-01 根因 A：旧实现在此 early return，refreshVaioDetect 在
        // 其后 → 点安装失败后检测仍不跑、界面恒显未检测到。失败路径
        // 也必须刷新检测，让状态与真机现状对齐。
        refreshVaioDetect();
        _notifyUi();
        return false;
      }
      final res = await windowsSystem.vaioDriver(
        hit.path,
        install: true,
        elevated: elevated,
        bundled: hit.bundled,
      );
      final gotDetect = await awaitVaioDetect();
      await refreshAudioDevices();
      final scriptOk = res.exitCode == 0;
      final found = vaioDetectInfo['found'] == true;
      final ok = scriptOk && gotDetect && found;
      vaioActionUnverified = scriptOk && !ok;
      if (!scriptOk) {
        // 失败文案按退出码分因（细审 R-D L11）：旧实现一律
        // 归咎 UAC，退出码 3（未开测试签名）/5（pnputil）/
        // 6-7（devcon）时与真实原因不符、误导排障。退出码
        // 口径见随包 install_vaio.ps1 文件头。
        lastVaioError = switch (res.exitCode) {
          2 => 'AuraVAIO 安装未完成 (退出码: 2)：需要管理员权限，请在 UAC 弹窗中选择允许提权',
          3 => 'AuraVAIO 安装未完成 (退出码: 3)：系统未开启测试签名模式，测试签名的驱动无法安装',
          4 => 'AuraVAIO 安装未完成 (退出码: 4)：随包驱动文件缺失',
          5 => 'AuraVAIO 安装未完成 (退出码: 5)：pnputil 安装驱动失败，详情见 %TEMP%/auradsp-vaio-install.log',
          6 => 'AuraVAIO 安装未完成 (退出码: 6)：devcon 创建设备节点失败，详情见 %TEMP%/auradsp-vaio-install.log',
          7 => 'AuraVAIO 安装未完成 (退出码: 7)：随包 devcon.exe 缺失',
          _ => 'AuraVAIO 安装未完成 (退出码: ${res.exitCode})，请在 UAC 弹窗中选择允许提权',
        };
      } else {
        lastVaioError = null;
      }
      _notifyUi();
      return ok;
    } catch (e) {
      lastVaioError = '安装驱动异常: $e';
      refreshVaioDetect();
      _notifyUi();
      return false;
    }
  }

  /// 一键 UAC 提权卸载 AuraVAIO 虚拟声卡驱动
  ///
  /// 与安装同口径诚实校验：脚本成功后复检仍 found 则未生效。
  Future<bool> uninstallVaioDriver({bool elevated = true}) async {
    if (!PlatformProfile.supportsBridges) return false;
    vaioActionUnverified = false;
    try {
      final hit = _findVaioInstallScript();
      if (hit == null) {
        // 旧实现静默 return false：用户点卸载只看到通用失败提示。
        lastVaioError = '未找到 VAIO 驱动安装脚本（随包 driver/install_vaio.ps1 缺失）';
        refreshVaioDetect();
        _notifyUi();
        return false;
      }
      final res = await windowsSystem.vaioDriver(
        hit.path,
        install: false,
        elevated: elevated,
        bundled: hit.bundled,
      );
      final gotDetect = await awaitVaioDetect();
      await refreshAudioDevices();
      final scriptOk = res.exitCode == 0;
      final stillFound = vaioDetectInfo['found'] == true;
      final ok = scriptOk && gotDetect && !stillFound;
      vaioActionUnverified = scriptOk && !ok;
      if (ok) {
        lastVaioError = null;
      } else if (!scriptOk) {
        // 与安装侧对称（细审 R-D L11）：旧实现卸载脚本失败
        // 不写 lastVaioError，只剩面板通用文案兜底。
        lastVaioError =
            'AuraVAIO 卸载未完成 (退出码: ${res.exitCode})，请在 UAC 弹窗中选择允许提权';
      }
      _notifyUi();
      return ok;
    } catch (e) {
      lastVaioError = '卸载异常: $e';
      refreshVaioDetect();
      _notifyUi();
      return false;
    }
  }

  // ---- APO 挂载配置 ----

  void setApoTargetEndpoint(String endpoint) {
    config.apoTargetEndpoint = endpoint;
    persistRoutingChange();
    _notifyUi();
  }

  void setMonitorMirroring(bool enabled) {
    config.monitorMirroring = enabled;
    persistRoutingChange();
    _notifyUi();
  }

  void setApoAttached(bool attached) {
    apoAttached = attached;
    _notifyUi();
  }

  // ---- ASIO 驱动注册 ----

  /// 检查 AuraDSP Virtual ASIO 驱动在 Windows 系统的注册状态
  Future<void> checkAsioDriverStatus() async {
    if (!PlatformProfile.supportsBridges) {
      asioDriverInstalled = false;
      _notifyUi();
      return;
    }
    try {
      // 注册表读取统一经 RegistryPort（reg.exe 只在 platform/registry/）。
      asioDriverInstalled = registry.keyExists(
        r'HKLM\SOFTWARE\ASIO\AuraDSP Driver',
      );
    } catch (e, st) {
      swallow(e, st);
      asioDriverInstalled = false;
    }
    _notifyUi();
  }

  /// 一键注册 AuraDSP 虚拟 ASIO 驱动到系统（支持 Windows UAC 提权授权）
  Future<bool> registerAsioDriver({bool elevated = true}) async {
    if (!PlatformProfile.supportsBridges) return false;
    // 脚本缺失不得静默 return false（旧实现 UI 只弹通用失败提示，
    // 安装版上「一键注册」长期无声失败，见真机报告 §5.4-1）。
    final hit = _findAsioRegisterScript();
    if (hit == null) {
      lastAsioError = '未找到 ASIO 注册脚本（随包 driver/register_asio.ps1 缺失）';
      _notifyUi();
      return false;
    }
    try {
      final res =
          await windowsSystem.asioDriverScript(
        hit.path,
        register: true,
        elevated: elevated,
        bundled: hit.bundled,
      );
      await checkAsioDriverStatus();
      // 脚本自报失败（结果文件通道）：呈现真实原因（DLL
      // 缺失 / regsvr32 退出码等），不再用 UAC 兜底文案掩盖。
      if (res.toolOk == false) {
        lastAsioError =
            'ASIO 驱动注册失败：${res.toolMessage ?? res.toolError ?? '脚本未报告原因'}';
        _notifyUi();
        return false;
      }
      final ok =
          res.toolOk == true || (res.exitCode == 0 && asioDriverInstalled);
      if (!ok) {
        lastAsioError = 'ASIO 驱动注册未完成，请确认在 UAC 提权弹窗中选择“是”以授予管理员权限';
      } else {
        lastAsioError = null;
      }
      _notifyUi();
      return ok;
    } catch (e) {
      lastAsioError = 'ASIO 驱动注册异常: $e';
      _notifyUi();
      return false;
    }
  }

  /// 一键反注册 AuraDSP 虚拟 ASIO 驱动（支持 Windows UAC 提权授权）
  Future<bool> unregisterAsioDriver({bool elevated = true}) async {
    if (!PlatformProfile.supportsBridges) return false;
    final hit = _findAsioRegisterScript();
    if (hit == null) {
      lastAsioError = '未找到 ASIO 注册脚本（随包 driver/register_asio.ps1 缺失）';
      _notifyUi();
      return false;
    }
    try {
      final res =
          await windowsSystem.asioDriverScript(
        hit.path,
        register: false,
        elevated: elevated,
        bundled: hit.bundled,
      );
      await checkAsioDriverStatus();
      if (res.toolOk == false) {
        lastAsioError =
            'ASIO 驱动注销失败：${res.toolMessage ?? res.toolError ?? '脚本未报告原因'}';
        _notifyUi();
        return false;
      }
      final ok =
          res.toolOk == true || (res.exitCode == 0 && !asioDriverInstalled);
      if (!ok) {
        lastAsioError = 'ASIO 驱动注销未完成';
      } else {
        lastAsioError = null;
      }
      _notifyUi();
      return ok;
    } catch (e) {
      lastAsioError = 'ASIO 驱动注销异常: $e';
      _notifyUi();
      return false;
    }
  }

  ({String path, bool bundled})? _findAsioRegisterScript() {
    final bundled = windowsSystem
        .findInstalledFile(const ['driver/register_asio.ps1']);
    if (bundled != null) return (path: bundled, bundled: true);
    final repo = windowsSystem.findRepoFile(const [
      'core/desktop/windows-drivers/04_asio_driver/register_driver.ps1',
      'scripts/register_driver.ps1',
      'register_driver.ps1',
      '../scripts/register_driver.ps1',
    ]);
    if (repo != null) return (path: repo, bundled: false);
    return null;
  }

  // ---- System APO 运维 ----

  // 原生工具定位（2026-11-09 §2.3 方案 A）：随包 driver/ 优先，
  // 开发期回退 windows-drivers 构建产物。旧 python 脚本链路已下线
  // ——目标机器无 Python 运行时是真机实证的断裂点，不再保留。
  String? _findApoConfigTool() =>
      windowsSystem.findInstalledFile(const ['driver/apo_config.exe']) ??
      windowsSystem.findRepoFile(const [
        'core/desktop/windows-drivers/out/Release/apo_config.exe',
        'core/desktop/windows-drivers/out/Debug/apo_config.exe',
      ]);

  void setApoCompositeMode(bool enabled) {
    apoCompositeMode = enabled;
    _notifyUi();
  }

  /// 检查 System APO 在系统注册与端点挂载状态，并检测心跳。
  /// [silent] = 后台探测（模型初始化时）：脚本缺失/查询失败不置错误，
  /// 避免用户未做任何操作就先攒下一条陈旧报错；UI 按钮与附加/卸载
  /// 后的复查走默认（非静默），失败必须有可见反馈（V-03 静默点）。
  /// 已安装端点记录与目标（id / 完整名称）的精确匹配（细审
  /// R-C M-3 口径）：旧口径双向子串在多端点机器上可误命中他
  /// 端点、误报已附加；全等对现行 id 存值与旧版名称存值都兼容。
  bool _apoEndpointMatches(Map<String, dynamic> e, String target) {
    final short = e['short_guid']?.toString().toLowerCase() ?? '';
    final name = e['DeviceName']?.toString().toLowerCase() ?? '';
    final id = e['EndpointId']?.toString().toLowerCase() ?? '';
    final t = target.toLowerCase();
    return t.isNotEmpty && (t == short || t == name || t == id);
  }

  Future<void> checkApoStatus({double timeout = 0.4, bool silent = false}) async {
    if (!PlatformProfile.supportsBridges) {
      apoAttached = false;
      apoAnyAttached = false;
      apoAttachedName = '';
      apoHeartbeatAlive = false;
      _notifyUi();
      return;
    }
    try {
      final script = _findApoConfigTool();
      if (script == null) {
        if (!silent) lastApoError = '未找到 apo_config.exe 驱动管理工具';
        _notifyUi();
        return;
      }
      {
        final res =
            await windowsSystem.apoStatus(
          script,
          timeout,
        );
        if (res.exitCode == 0) {
          final out = res.stdout.toString().trim();
          final lines = out
              .split(RegExp(r'\r?\n'))
              .where((l) => l.trim().startsWith('{'))
              .toList();
          if (lines.isNotEmpty) {
            final data = jsonDecode(lines.last) as Map<String, dynamic>;
            final rawInstalled = data['installed_endpoints'] as List?;
            final installed = rawInstalled != null
                ? rawInstalled
                      .map((e) => Map<String, dynamic>.from(e as Map))
                      .toList()
                : <Map<String, dynamic>>[];
            apoInstalledEndpoints = installed;
            // 任意端点附加真值（第六轮项 3）：与所选目标无关，
            // 状态行与卸载目标据此，不让切目标把附加「藏丢」。
            apoAnyAttached = installed.isNotEmpty;
            apoAttachedName = installed.isEmpty
                ? ''
                : (installed.first['DeviceName']?.toString() ??
                    installed.first['short_guid']?.toString() ??
                    '');

            final target = config.apoTargetEndpoint;
            if (target.isEmpty) {
              apoAttached = installed.isNotEmpty;
            } else {
              apoAttached =
                  installed.any((e) => _apoEndpointMatches(e, target));
            }

            final hb = data['heartbeat'] as Map<String, dynamic>?;
            if (hb != null && hb['alive'] == true) {
              apoHeartbeatAlive = true;
              apoHeartbeatSeq = (hb['seq'] as num?)?.toInt() ?? 0;
              apoHeartbeatSr = (hb['sr'] as num?)?.toInt() ?? 0;
              apoHeartbeatFrames = (hb['frames'] as num?)?.toInt() ?? 0;
            } else {
              apoHeartbeatAlive = false;
            }
            lastApoError = null;
            _notifyUi();
            return;
          }
        }
      }
      // 脚本在但退出码非 0 / 无 JSON 输出：旧实现静默落到末尾刷新，
      // 「刷新状态」看起来毫无反应——非静默调用必须给出可见原因。
      if (!silent) lastApoError = 'APO 状态查询失败（脚本无有效输出）';
    } catch (e, st) {
      swallow(e, st);
    }
    _notifyUi();
  }

  /// 一键将 System APO 挂载到指定音频端点（支持 Windows UAC 提权授权，支持复合插槽）
  Future<bool> attachSystemApo({
    String? endpointNameOrId,
    bool? composite,
    bool elevated = true,
  }) async {
    if (!PlatformProfile.supportsBridges) return false;
    isApoOperating = true;
    lastApoError = null;
    _notifyUi();

    try {
      final script = _findApoConfigTool();
      if (script == null) {
        lastApoError = '未找到 apo_config.exe 驱动管理工具';
        isApoOperating = false;
        _notifyUi();
        return false;
      }

      final target = (endpointNameOrId != null && endpointNameOrId.isNotEmpty)
          ? endpointNameOrId
          : config.apoTargetEndpoint;
      if (target.isEmpty) {
        lastApoError = '请先选择需要附加的音频端点';
        isApoOperating = false;
        _notifyUi();
        return false;
      }

      final useComposite = composite ?? apoCompositeMode;
      final res = await windowsSystem.apoInstall(
        script,
        target: target,
        composite: useComposite,
        elevated: elevated,
      );

      // 工具自报失败（如端点匹配歧义/注册表写入失败）：原因
      // 就在结果通道里，直接呈现，不再走退出码猜层。工具经
      // --result-file 跨 UAC 边界回传 JSON 裁定（真机实证：
      // 手动运行工具全程正常，App 路径失败却只报 UAC）。
      if (res.toolOk == false) {
        lastApoError =
            'System APO 附加失败：${res.toolMessage ?? res.toolError ?? '工具未报告原因'}';
        isApoOperating = false;
        _notifyUi();
        return false;
      }

      await Future.delayed(const Duration(milliseconds: 600));
      await checkApoStatus(timeout: 0.6);

      // 裁定 = 工具自报与状态复查合取（细审 R-C M-2 的 App
      // 侧一半）：toolOk 单独为真不再短路——工具写槽已改为
      // 成败必查后 toolOk 可信，但复查未见附加时仍走下方
      // 分层文案报未确认，不假报成功。
      final ok = (res.toolOk ?? (res.exitCode == 0)) && apoAttached;
      if (!ok && lastApoError == null) {
        // 失败文案按层区分（旧版一律归咎 UAC，对真机实证的
        // 「提权已执行但工具侧失败」毫无诊断价值）：
        // 提权进程退出码非 0 = UAC 拒绝/拉起失败；退出码 0 但
        // 状态复查无附加记录 = 工具已运行但未完成附加（端点
        // 匹配/注册表写入等），需看工具自身输出定位。
        lastApoError = res.exitCode != 0
            ? 'System APO 附加未生效：提权执行失败（退出码 ${res.exitCode}），请确认在 UAC 提权弹窗中选择“是”以授予管理员权限'
            : 'System APO 附加未生效：提权工具已执行，但未产生附加记录（端点匹配或注册表写入未完成）。可用管理员终端进入 driver 目录运行 apo_config.exe install 查看具体原因';
      }
      isApoOperating = false;
      _notifyUi();
      return ok;
    } catch (e) {
      lastApoError = 'System APO 附加异常: $e';
      isApoOperating = false;
      _notifyUi();
      return false;
    }
  }

  /// 一键卸载已挂载的 System APO 并精确还原原始系统/厂商 APO
  Future<bool> detachSystemApo({
    String? endpointNameOrId,
    bool elevated = true,
  }) async {
    if (!PlatformProfile.supportsBridges) return false;
    isApoOperating = true;
    lastApoError = null;
    _notifyUi();

    try {
      final script = _findApoConfigTool();
      if (script == null) {
        lastApoError = '未找到 apo_config.exe 驱动管理工具';
        isApoOperating = false;
        _notifyUi();
        return false;
      }

      // 卸载对象 = 实际已附加的端点，不是下拉的当前选择（第六
      // 轮项 3 定罪）：装在 A、切到 B 点卸载，旧实现对未装的
      // B 执行、工具报「未找到匹配的已安装端点」，且状态行按
      // B 推导把 A 的附加显示成「未附加」。先静默刷新附加清
      // 单，清单非空时以其首个端点为准；显式参数仍最高优先。
      await checkApoStatus(silent: true);
      var target = (endpointNameOrId != null && endpointNameOrId.isNotEmpty)
          ? endpointNameOrId
          : config.apoTargetEndpoint;
      if ((endpointNameOrId == null || endpointNameOrId.isEmpty) &&
          apoInstalledEndpoints.isNotEmpty) {
        final first = apoInstalledEndpoints.first;
        target = first['EndpointId']?.toString() ??
            first['short_guid']?.toString() ??
            target;
      }
      final res = await windowsSystem.apoUninstall(
        script,
        target: target,
        elevated: elevated,
      );

      await Future.delayed(const Duration(milliseconds: 600));
      await checkApoStatus(timeout: 0.6);

      if (res.toolOk == false && lastApoError == null) {
        lastApoError =
            'System APO 卸载失败：${res.toolMessage ?? res.toolError ?? '工具未报告原因'}';
      }
      // 裁定与 attach 对称（细审 R-C M-1 的 App 侧一半）：
      // 此前 detach 完全不看复查结果，端点级还原失败时假
      // 报成功。现口径：工具自报（或退出码）成功且复查确
      // 认【被卸端点】已摘除，才算卸载完成（不用所选目标的
      // apoAttached——选择与被卸端点可能不是同一个）。
      final stillThere =
          apoInstalledEndpoints.any((e) => _apoEndpointMatches(e, target));
      final ok = (res.toolOk ?? (res.exitCode == 0)) && !stillThere;
      if (!ok && lastApoError == null) {
        lastApoError = stillThere
            ? 'System APO 卸载后复查仍显示已附加，请重试或检查工具返回明细'
            : 'System APO 卸载未完成，请确认在 UAC 提权弹窗中选择“是”';
      }
      isApoOperating = false;
      _notifyUi();
      return ok;
    } catch (e) {
      lastApoError = 'System APO 卸载异常: $e';
      isApoOperating = false;
      _notifyUi();
      return false;
    }
  }
}
