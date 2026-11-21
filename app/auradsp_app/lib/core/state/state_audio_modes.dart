// part of state.dart —— P6 按区拆分，extension 包装零逻辑改动。
part of '../state.dart';

/// 音频处理模式/管线 + 设备枚举 + VAIO 驱动 + ASIO 注册 + System APO 运维。
///
/// 方法体逐字保留自 AppModel 类体（notifyListeners() 按 P2 约定改调
/// _notifyUi()）。

/// 解析默认别名后的自激判定（纯函数，第七轮 S2；置于 extension 外
/// 是因为 extension 不能挂可按类名调用的 static）：'' 是系统默认
/// 渲染端点的别名，先解析为 defaultRenderId 再比——「默认回录 vs
/// 默认端点的具名输出」与双默认（细审 R-A H1）是同一自激对
/// （项 3 定罪：旧实现只符号比较、两者皆空才冲突，具名别名直接
/// 漏网，实测处理与可视化照常有效）。默认身份未知（尚未刷新
/// 成功）时保留旧口径：双默认仍拦。
bool idsConflictResolved(String capId, String outId, String defaultRenderId) {
  final cap = capId.isEmpty ? defaultRenderId : capId;
  final out = outId.isEmpty ? defaultRenderId : outId;
  if (cap.isNotEmpty && out.isNotEmpty) return cap == out;
  return capId.isEmpty && outId.isEmpty;
}

extension AudioModesState on AppModel {

  // ---- 模式与管线 ----

  /// 进入 sysapo 时的文件型效果策略（历史口径）：2026-11-10
  /// 用户裁定曾为「卷积/DDC 若开着则自动关闭并通知一次」；
  /// 2026-11-12 资源计划 P4 起 sysapo 经文件中转后 fileEffects
  /// 可用，本策略按 ModeCaps 恒为空操作（函数与调用点保留，
  /// 作为未来再有 fileEffects 不可用模式时的统一策略位）。
  void applyApoFileEffectPolicy() {
    // ModeCaps 口径：仅在 fileEffects 不可用的模式下执行本策略；
    // 能力可用时整段为空操作，调用方无需再写模式判断。
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
  ///
  /// 离开 sysapo 的前置（业主 2026-11-12）：仍有端点附加时先把
  /// APO 全部卸载再切换——卸载是提权异步操作，本函数在此拦截：
  /// 置 apoDetachBlocking（UI 禁选 + 等待动画）、吞掉等待期间的
  /// 一切切换请求，卸载成功后以原目标续行本函数；失败则留在
  /// sysapo 并回滚各 setter 预写的范式/附加字段 + 错误通知。
  /// 无端点附加时（从未附加/已手动卸载）不等待、直接切换。
  void setAudioMode(String id) {
    _displayGen++; // S3：模式变更 → 显示合成可覆盖
    final valid = AudioModes.normalize(id);
    if (audioMode == 'sysapo' && valid != 'sysapo') {
      if (apoDetachBlocking) return; // 卸载在途：吞掉反复切换
      if (apoAnyAttached || apoInstalledEndpoints.isNotEmpty) {
        apoDetachBlocking = true;
        _pendingModeAfterDetach = valid;
        _notifyUi();
        _runApoDetachThenMode();
        return;
      }
    }
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
      // 切入 ASIO 即停测试源（第四十九轮 S3）：ASIO 链路
      // 下测试源无效，状态先清干净，不留假播放态。
      if (isAsio && sourceKind.isNotEmpty) setSource('stop');
      // asiomode 内部自带 detect（无论能否启动都回 asiodrivers 事件给设置页）。
      // 第七轮 S2：开关总闸压过模式直发起桥（见 _pipelineIoSuppressed）。
      if (!(isAsio && _pipelineIoSuppressed)) {
        _toIso?.send({
          'cmd': 'asiomode',
          'on': isAsio,
          'driver': config.asioDriver,
          'bufSize': config.asioBufSize,
          'outPair': config.asioOutPair,
          'flavor': config.asioFlavor,
          'muted': _asioVirtualMuted,
        });
      }
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
          (pipelineChain != PipelineChain.vaio || _pipelineIoSuppressed);
      if (!chainBlocksVaio) {
        _toIso?.send({
          'cmd': 'vaiomode',
          'on': isVaio,
          'outputEndpoint': config.vaioOutputEndpoint,
          'monitorMirror': config.monitorMirroring,
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
    _toIso?.send({
      'cmd': 'apotelemetry',
      'on': valid == 'sysapo',
      'endpointId': selectedApoEndpointId,
    });
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
    _sendChCap(); // S2：模式变更 → 按新模式重算能力下发
    _notifyUi();
    // 全面复审 S4（ENG-2）：桥模式期间改过的采样率只落了盘，
    // isolate 仍按生成率运行——切回进程内模式（含 sysapo 影子
    // 引擎）时对账：生成率 != 配置率则重启 isolate 使新率生效
    // （此前永不生效：面板显示新率、引擎跑旧率）。
    if (valid != 'vbcallback' && valid != 'asio' && valid != 'vaio' &&
        isolateSpawnSampleRate != 0 &&
        isolateSpawnSampleRate != config.sampleRate) {
      _pendingRestartPush = true;
      _restartIsolate();
    }
  }

  /// 切离 sysapo 的卸载续行：先等面板侧可能在途的 detach 落定
  /// （避免两个 apo_config 卸载进程并发），再执行全端点卸载。
  /// 成功 → 以挂起目标重入 setAudioMode（此刻端点已空、门直
  /// 通）；失败 → 回滚 setter 预写字段、留在 sysapo 并通知。
  Future<void> _runApoDetachThenMode() async {
    final target = _pendingModeAfterDetach;
    _pendingModeAfterDetach = null;
    var ok = false;
    try {
      var guard = 0;
      while (isApoOperating && guard++ < 60) {
        await Future.delayed(const Duration(milliseconds: 500));
      }
      if (apoInstalledEndpoints.isEmpty && !apoAnyAttached) {
        ok = true; // 等待期间面板已卸净，无需再跑一遍
      } else {
        final runner = apoDetachRunnerOverride;
        ok = runner != null ? await runner() : await detachSystemApo();
      }
    } catch (e, st) {
      swallow(e, st);
      ok = false;
    }
    apoDetachBlocking = false;
    if (ok && target != null) {
      setAudioMode(target);
    } else {
      config.modeCategory = AudioModes.categoryAttachment;
      config.attachmentMode = AudioModes.attachSysApo;
      postNotice(
          '切换模式前卸载 System APO 失败，已保持 System APO 模式'
          '${lastApoError != null ? '：$lastApoError' : ''}',
          level: NoticeLevel.error);
      _notifyUi();
    }
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

  /// ADR-009: 切换音频范式（附加模式 vs 普通管线模式）；
  /// 2026-11-20 ASIO 重构起第三范式 ASIO（子形态见 setAsioFlavor）。
  void setModeCategory(String category) {
    if (category != AudioModes.categoryAttachment &&
        category != AudioModes.categoryPipeline &&
        category != AudioModes.categoryAsio) {
      return;
    }
    config.modeCategory = category;
    if (category == AudioModes.categoryPipeline) {
      // 回管线范式：管线对里的 ASIO 残留已无对应选项（ASIO
      // 已升独立范式、管线选择器不再提供），按既有口径降为
      // VAIO（pipelineOutputForMode 对模式直切的同款处理）。
      if (config.pipelineInput == AudioModes.inputAsioDriver) {
        config.pipelineInput = AudioModes.inputVaio;
      }
      if (config.pipelineOutput == AudioModes.outputAsioClient) {
        config.pipelineOutput = AudioModes.outputVaio;
      }
    }
    if (category == AudioModes.categoryAsio) {
      // 进入 ASIO 范式先按已存子形态把管线对拨到位，合成链
      // 才恒为 asio（composeChain 仍以管线对为真相，S1 行为
      // 等价搬家；新卡呈现留 S2）。
      _applyAsioFlavorToPair();
    }
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

  /// 把管线对拨到当前 ASIO 子形态对应的存量形态：virtual →
  /// 输入 asio_driver（DAW 注入）；client → 输出 asio_client。
  /// 只写形态所属的那一侧，另一侧保留用户既有选择（合成链
  /// 任一侧命中即 asio，非损口径同 pipelineOutputForMode）。
  void _applyAsioFlavorToPair() {
    if (config.asioFlavor == AudioModes.asioVirtual) {
      config.pipelineInput = AudioModes.inputAsioDriver;
    } else {
      config.pipelineOutput = AudioModes.outputAsioClient;
    }
  }

  /// ASIO 范式子形态切换（虚拟 ASIO / ASIO Client）：落盘 +
  /// 管线对拨形 + 链路对账。两形态同合成 'asio' 模式，模式
  /// 漂移（非 asio）时经 setAudioMode 收口。
  void setAsioFlavor(String flavor) {
    if (!AudioModes.isValidAsioFlavor(flavor)) return;
    config.asioFlavor = flavor;
    if (config.modeCategory == AudioModes.categoryAsio) {
      _applyAsioFlavorToPair();
      if (audioMode != 'asio') {
        setAudioMode('asio');
        return;
      }
      applyPipelineChain();
      // S4 起两形态在 isolate 侧根本分岔（虚拟=控制模式无会话 /
      // Client=桥会话）：已在 asio 模式时对账分发只在链未活时
      // 重发，活会话下形态切换必须显式直达 isolate。
      if (!_pipelineIoSuppressed) {
        _toIso?.send({
          'cmd': 'asiomode',
          'on': true,
          'driver': config.asioDriver,
          'bufSize': config.asioBufSize,
          'outPair': config.asioOutPair,
          'flavor': config.asioFlavor,
          'muted': _asioVirtualMuted,
        });
      }
      _sendChCap();
    }
    persistRoutingChange();
    _notifyUi();
  }

  /// 输入/输出开关总闸（第七轮 S2 项 5）：管线类别内任一开关
  /// 关闭即压过一切起链路径（分发器对账、模式直发、就绪恢复）。
  /// ASIO 范式沿用同一总闸（I/O 卡 S2 重画前行为等价）。
  bool get _pipelineIoSuppressed =>
      (config.modeCategory == AudioModes.categoryPipeline ||
          config.modeCategory == AudioModes.categoryAsio) &&
      (!config.pipelineInputEnabled || !config.pipelineOutputEnabled);

  /// ASIO 虚拟形态的链路静音（r61 验收修复）：总闸压下时不拆
  /// 控制模式，改经参数块 mute 字段令驱动泵静音（Client 形态
  /// 仍走 asiomode off 停桥）。
  bool get _asioVirtualMuted =>
      config.asioFlavor == AudioModes.asioVirtual && _pipelineIoSuppressed;

  /// 当前管线链路（仅管线/ASIO 类别内有意义；其余类别返回
  /// null）。ASIO 范式恒 asio 链（子形态差异在管线对与桥的
  /// 驱动参数，不在链种类）。
  PipelineChain? get pipelineChain =>
      config.modeCategory == AudioModes.categoryPipeline
          ? AudioModes.composeChain(
              input: config.pipelineInput,
              output: config.pipelineOutput,
            )
          : config.modeCategory == AudioModes.categoryAsio
              ? PipelineChain.asio
              : null;

  /// 链路任一端经 ASIO（输入 ASIO 驱动或输出 ASIO 客户端
  /// 任一成立，合成链即 ASIO 桥链）。测试源无效判定（拦
  /// 截/徽标/禁用/切入停源）的唯一谓词（第五十轮 S2 订
  /// 正）：第四十九轮曾以 audioMode == 'asio' 判定，但输
  /// 入端切 ASIO 时 composeMode 只看输出端、合成模式仍
  /// 为 vaio，判定全数落空（user 实测：无徽标、测试可点
  /// 且点了无效）——一律以合成链为准。
  bool get asioInChain => pipelineChain == PipelineChain.asio;

  /// 当前模式下 viz 数据的预期来源（生产者标签口径，第二十三轮
  /// 按数据来源治理）：桥帧由 isolate 泵打标 'vaio'/'vb'/'asio'，
  /// APO 合成帧带 'sysapo'，进程内泵帧无标签按 'local' 记。
  /// 判定顺序（第二十四轮修正）：**范式类别优先**——喂数者由
  /// isolate 的实际分发决定，而分发看的是 modeCategory：类别为
  /// pipeline 时跑管线链（桥/进程内泵），audioMode 只是合成值，
  /// 可以滞后于管线选择（鲜装默认即如此：原始 'auto' 派生
  /// category=pipeline，audioMode 归一为 'sysapo' 而从未重派；
  /// 只点管线选择器时 setPipelineInput 也不改写 audioMode）。
  /// 第二十三轮曾以「附加优先」判此混合态，把管线帧全数误杀
  /// （vm-win10 鲜装实证：处理正常、可视化全黑，日志
  /// `viz: dropped local frame (expected sysapo)`），已定罪改判。
  /// 类别为 attachment 时才由 audioMode 直接分发（sysapo 读
  /// APO 遥测、vbcallback 走 VM 桥）；其余直连模式按 audioMode。
  String get expectedVizBackend {
    if (modeCategory == AudioModes.categoryAsio) return 'asio';
    if (modeCategory == AudioModes.categoryPipeline) {
      final chain = pipelineChain;
      if (chain == PipelineChain.asio) return 'asio';
      if (chain == PipelineChain.vaio) return 'vaio';
      if (chain == PipelineChain.capture) return 'local';
    }
    if (audioMode == 'sysapo') return 'sysapo';
    if (audioMode == 'vbcallback') return 'vb';
    if (audioMode == 'asio') return 'asio';
    if (audioMode == 'vaio') return 'vaio';
    return 'local';
  }

  /// 数据源切换即清零（第二十三轮）：新源尚未产帧、或切到的
  /// 选项根本无声（无帧的驱动选项/断路器拦下桥未起）时，旧源的
  /// 最后一帧不得残留。基线与当前预期一致则不动——重复调用
  /// 幂等；由 applyPipelineChain 入口与 setAudioMode 各调用点
  /// 汇合触发（setAudioMode 末尾必经 applyPipelineChain）。
  void _syncVizSourceOnSwitch() {
    final expected = expectedVizBackend;
    if (_vizSourceBaseline != expected) {
      _vizSourceBaseline = expected;
      vizSource = null;
    }
    // 切换即清屏（第四十九轮 S4，user 定案）：凡链路重组
    // （模式/设备/路由切换都汇合于此）一律立刻清屏，不再只
    // 限预期后端变化——同后端换设备时旧帧残留正是宾机所报
    // 「切换驱动后频谱有时不归零」的一条路径。看门狗记账
    // 一并复位，新源首帧到达前不触发断流清屏的重复通知。
    _vizLastFrameAt = null;
    _vizSilentSince = null;
    if (!_vizDisplayCleared) _clearVizState();
  }

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

  bool _idsConflict(String capId, String outId) =>
      idsConflictResolved(capId, outId, defaultRenderId);

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

  /// 断路器暂停是否正挡着当前模式的 VAIO 桥（设备页横幅的显
  /// 示条件）：已跳过且当前模式/合成链确实要走 VAIO 桥时才
  /// 为真——切到无关模式后横幅自然消失（tripped 本身仍留待
  /// 手动接管或下次构造消费，语义不变）。
  bool get vaioGuardBlocksCurrentMode =>
      vaioBootGuardTripped &&
      (audioMode == 'vaio' || pipelineChain == PipelineChain.vaio);

  /// 设备页「仍然启动 VAIO」（第二十一轮用户裁定）：断路器
  /// 跳过自动起桥后，用户在设备页知情接管——等同手动重选
  /// VAIO 模式的接管语义（清跳过态、重新布防），起桥走与
  /// ready 恢复相同的直发口径；管线类别下合成链非 vaio 时
  /// 交由对账按当前链收口（门已清除，对账不再被挡）。
  void startVaioDespiteGuard() {
    if (!vaioBootGuardTripped) return;
    vaioBootGuardTripped = false;
    dbgLog('vaio-guard: user started VAIO anyway from device panel; '
        'breaker cleared');
    if (audioMode == 'vaio' &&
        !_pipelineIoSuppressed &&
        pipelineChain != PipelineChain.capture &&
        pipelineChain != PipelineChain.asio) {
      _toIso?.send({
        'cmd': 'vaiomode',
        'on': true,
        'outputEndpoint': config.vaioOutputEndpoint,
        'monitorMirror': config.monitorMirroring,
      });
      _armVaioGuard();
    } else {
      applyPipelineChain();
    }
    _notifyUi();
  }

  void applyPipelineChain() {
    if (!PlatformProfile.supportsBridges) return;
    // 第二十三轮：链路对账前先按数据来源对齐显示面——本函数的
    // 全部调用点（模式切换/管线改选/就绪对账）config 已持新值，
    // 预期来源变化即清零（幂等，见 _syncVizSourceOnSwitch）。
    _syncVizSourceOnSwitch();
    // 模式切换后异步补刷设备+调和（第三十四轮）。
    _requestDeviceRefreshAfterChain();
    // 第七轮 S2（项 5）：开关总闸——任一关闭，合成链不下发，在跑
    // 的捕获/桥链按模式切换的同口径拆干净。此前两标志只被面板
    // 读取（收起子面板），分发器从不看（项 5 定罪：开关纯装饰、
    // 链路照跑；面板文案却早已承诺「采集暂停/输出静音」）。
    if (_pipelineIoSuppressed) {
      if (captureActive) {
        _toIso?.send({'cmd': 'capturemode', 'on': false});
        captureActive = false;
        dbgLog('pipeline.chain: capturemode off (io switch)');
      }
      if (vaioActive) {
        _toIso?.send({
          'cmd': 'vaiomode',
          'on': false,
          'outputEndpoint': config.vaioOutputEndpoint,
        });
        vaioActive = false;
        vaioInfo = {};
        _disarmVaioGuard();
        dbgLog('pipeline.chain: vaiomode off (io switch)');
      }
      if (config.modeCategory == AudioModes.categoryAsio &&
          config.asioFlavor == AudioModes.asioVirtual) {
        // r61 验收修复：虚拟形态总闸不拆控制模式——拆会话拆不
        // 掉 DAW 进程内的驱动（声音与遥测照旧，宾机实报缺陷），
        // 改经参数块 mute 字段令驱动泵整体静音。
        _toIso?.send({
          'cmd': 'asiomode',
          'on': true,
          'driver': config.asioDriver,
          'bufSize': config.asioBufSize,
          'outPair': config.asioOutPair,
          'flavor': config.asioFlavor,
          'muted': true,
        });
        dbgLog('pipeline.chain: asiomode virtual muted (io switch)');
      } else if (asioActive) {
        _toIso?.send({
          'cmd': 'asiomode',
          'on': false,
          'driver': config.asioDriver,
          'bufSize': config.asioBufSize,
          'outPair': config.asioOutPair,
          'flavor': config.asioFlavor,
        });
        asioActive = false;
        asioInfo = {};
        dbgLog('pipeline.chain: asiomode off (io switch)');
      }
      return;
    }
    // 链路汇合点停源（第五十轮 S2）：输入/输出改选使合成
    // 链进入 ASIO 时，在播测试源即停——setAudioMode 的
    // wasAsio 停源只覆盖模式直切，管线改选不经模式切换
    // （输入 ASIO 时合成模式仍 vaio），须在此汇合点补齐
    // （与第四十九轮 S4 清屏同汇合点口径）。
    if (asioInChain && sourceKind.isNotEmpty) setSource('stop');
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
        'monitorMirror': config.monitorMirroring,
      });
      _armVaioGuard();
    } else if (chain == PipelineChain.asio &&
        (!asioActive || config.asioFlavor == AudioModes.asioVirtual)) {
      // 虚拟形态恒重发：控制模式无会话活标志，总闸的静音/解静
      // 音状态只能靠重发 asiomode 携带（isolate 侧幂等）。
      dbgLog('pipeline.reconcile: resend asiomode');
      _toIso?.send({
        'cmd': 'asiomode',
        'on': true,
        'driver': config.asioDriver,
        'bufSize': config.asioBufSize,
        'outPair': config.asioOutPair,
        'flavor': config.asioFlavor,
        'muted': _asioVirtualMuted,
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
    _sendChCap();
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
        _sendChCap();
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
    _sendChCap();
    persistRoutingChange();
    _notifyUi();
  }

  void setPipelineOutputDevice(String device) {
    config.pipelineOutputDevice = device;
    _pipelineDeviceChanged();
    _sendChCap();
    persistRoutingChange();
    _notifyUi();
  }

  void setPipelineInputEnabled(bool enabled) {
    config.pipelineInputEnabled = enabled;
    // 第七轮 S2（项 5）：开关接线分发器——关即拆链、开即对账恢复。
    applyPipelineChain();
    persistRoutingChange();
    _notifyUi();
  }

  void setPipelineOutputEnabled(bool enabled) {
    config.pipelineOutputEnabled = enabled;
    applyPipelineChain();
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
    // 在飞合并（2026-11-14）：看守/链路对账/手动按钮可能并发触发，
    // 同一时刻只跑一份扫描，后到者直接返回（其关心的应用阶段由
    // 在飞的那份完成，签名与调和都是全量口径，不丢更新）。
    if (_deviceRefreshInFlight) return;
    _deviceRefreshInFlight = true;
    try {
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
        final res = await windowsSystem.inspectAudioDevices(exePath);
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
            _applyDeviceScan(json);
          } else {
            dbgLog('devices.refresh: empty stdout', sync: true);
          }
        } else {
          dbgLog('devices.refresh: inspect failed', sync: true);
          lastAudioError = '端点探测工具退出异常 (代码: ${res.exitCode})';
          _notifyUi();
        }
      } catch (e) {
        dbgLog('devices.refresh: error $e', sync: true);
        lastAudioError = '刷新音频设备失败: $e';
        _notifyUi();
      }
    } finally {
      _deviceRefreshInFlight = false;
      _lastDeviceRefreshAt = DateTime.now();
    }
  }

  /// 扫描结果应用（手动刷新与系统监听共用）：写默认身份/设备表/
  /// 签名，跑自激守卫与选择调和，最后统一通知 UI。
  void _applyDeviceScan(Map<String, dynamic> json) {
    deviceScanDone = true; // S4：一轮设备枚举已落地
    _displayGen++; // S3：设备表/格式变更 → 显示合成可覆盖
    // 第七轮 S2 地基：默认端点身份（此前被解析层丢弃）。
    defaultRenderId = (json['defaultRender'] as String?) ?? '';
    defaultCaptureId = (json['defaultCapture'] as String?) ?? '';
    final eps = (json['endpoints'] as List?) ?? const [];
    final items = <AudioDeviceItem>[];
    // 在场键集（id 与名称，含非 ACTIVE 端点）：调和的「设备还在
    // 不在」按它判——被禁用 ≠ 被拔走，禁用设备的已存选择要保住，
    // 等其重新启用后自动恢复（下拉幽灵项口径不变）。
    final presentKeys = <String>{};
    for (final ep in eps) {
      if (ep is Map) {
        final name = (ep['name'] as String?) ?? '';
        final dir = (ep['direction'] as String?) ?? 'render';
        final id = (ep['id'] as String?) ?? '';
        final state = (ep['state'] as num?)?.toInt() ?? 1;
        if (id.isNotEmpty) presentKeys.add(id);
        if (name.isNotEmpty) presentKeys.add(name);
        if (name.isNotEmpty && state == 1) {
          items.add(
            AudioDeviceItem(
              id: id,
              name: name,
              isRender: dir == 'render',
              active: true,
              rate: (ep['rate'] as num?)?.toInt() ?? 0,
              ch: (ep['ch'] as num?)?.toInt() ?? 0,
              bits: (ep['bits'] as num?)?.toInt() ?? 0,
            ),
          );
        }
      }
    }
    _sysMonitor?.noteExternalScan(json); // S5：监听基线同步
    if (items.isEmpty) {
      dbgLog('devices.refresh: no endpoints parsed', sync: true);
      return;
    }
    wasapiDevices = items;
    lastAudioError = null;
    // 第七轮 S2（项 4）：默认身份刷新后重估在跑捕获链的自激面——
    // 用户中途在系统里把默认输出改成回录源端点时，原本合法的链
    // 会变成自激对：停链 + 提醒。只停不起（刷新不许意外起链）。
    if (captureActive &&
        _isFeedbackPair(config.pipelineInputDevice,
            config.pipelineOutputDevice)) {
      _toIso?.send({'cmd': 'capturemode', 'on': false});
      captureActive = false;
      postNotice('系统默认设备已变更，输入与输出变为同一端点，已停止捕获链以防自激',
          level: NoticeLevel.warning);
      dbgLog('pipeline.capture: stopped after refresh (feedback pair)');
    }
    reconcileDeviceSelections(presentKeys);
    // 声道能力对账（第四十二轮 S1）：扫描带来端点最新 mix 格
    // 式（含用户在系统设置里改声道数），sysapo 时补发钳制器。
    _sendChCap();
    dbgLog('devices.refresh: done n=${items.length}', sync: true);
    _notifyUi();
    dbgLog('devices.refresh: notified', sync: true);
  }

  /// 选择调和（2026-11-14 驱动刷新及时性轮，业主裁定）：已存的
  /// 设备选择若其端点已从系统消失（presentKeys 不含其 id/名称），
  /// 自动改回默认（''）并落盘 + 通知——免去用户手动点开下拉再选
  /// 一次默认设备。存在性只按原始枚举判：下拉的互斥筛选
  /// （wasapiOutputsExcludingInput 等）是呈现/起链守卫，绝不能
  /// 成为「设备不存在」的判据，否则输入占用的输出会被误清
  /// （业主明示避让筛选不受本功能影响）。
  /// 在跑链路不热换：捕获腿输入消失时沿用第七轮先例停腿；桥链
  /// 已打开的落点不受影响，修复值只决定下次起链。
  /// 两次确认防抖（S5，宾机 E2E 定罪）：单次扫描缺席不修——音频
  /// 服务重启/驱动安装后的重枚举瞬间端点会短暂消失（实测装机后
  /// 首扫 HDA 端点不在场，合法 VAIO 落点险被误清）；其后改两击
  /// 确认仍不够（S7 定罪：装机后音频栈重枚举可超过 8 秒，合法
  /// 落点在两击窗口内仍被误清）——现行口径为**持续缺席满 20
  /// 秒**才判真消失：首扫缺席只记起始时刻，其后每轮扫描复核，
  /// 满 20 秒仍缺席才修复（真实拔除约 20 秒落定）。缺席待确认
  /// 期间看守即使签名未变也持续应用扫描复核（S6）。在场即清
  /// 记录，App 重启记录自清。[now] 供单测注入时钟。
  void reconcileDeviceSelections(Set<String> presentKeys, {DateTime? now}) {
    if (presentKeys.isEmpty) return;
    final t = now ?? DateTime.now();
    final repaired = <String>[];
    // 返回 true = 本轮应修复（持续缺席已满宽限期）；在场/空值
    // 清记录；首次缺席只记录起始时刻。[present] 由调用方按字段
    // 语义判：在场键精确命中，或（仅 VAIO 落点）子串命中——
    // vaioOutputEndpoint 的字段语义本就是「端点名子串」
    // （config.dart），存量值可能是部分名，精确判会把合法的
    // 子串落点误判消失（第三十六轮代码审查 F1）。
    bool absentLongEnough(String field, String value, bool present) {
      if (value.isEmpty || present) {
        _reconcileAbsentSince.remove(field);
        return false;
      }
      final since = _reconcileAbsentSince[field];
      if (since == null) {
        _reconcileAbsentSince[field] = t;
        return false;
      }
      return t.difference(since) >= const Duration(seconds: 20);
    }

    bool presentExact(String v) => presentKeys.contains(v);
    bool presentVaio(String v) =>
        presentKeys.contains(v) ||
        presentKeys.any((k) => k.contains(v));

    if (absentLongEnough(
        'in', config.pipelineInputDevice, presentExact(config.pipelineInputDevice))) {
      config.pipelineInputDevice = '';
      _reconcileAbsentSince.remove('in');
      repaired.add('输入设备');
      if (captureActive) {
        _toIso?.send({'cmd': 'capturemode', 'on': false});
        captureActive = false;
        dbgLog('pipeline.capture: stopped after reconcile (input gone)');
      }
    }
    if (absentLongEnough('out', config.pipelineOutputDevice,
        presentExact(config.pipelineOutputDevice))) {
      config.pipelineOutputDevice = '';
      _reconcileAbsentSince.remove('out');
      repaired.add('输出设备');
    }
    if (absentLongEnough('vaio', config.vaioOutputEndpoint,
        presentVaio(config.vaioOutputEndpoint))) {
      config.vaioOutputEndpoint = '';
      _reconcileAbsentSince.remove('vaio');
      repaired.add('VAIO 物理输出');
    }
    if (repaired.isNotEmpty) {
      persistRoutingChange();
      postNotice('已移除的设备（${repaired.join('、')}）已自动改回默认设备',
          level: NoticeLevel.warning);
      dbgLog('devices.reconcile: reset to default: ${repaired.join(',')}');
    }
  }

  /// 请求本机/桥引擎生效值回读（第三十五轮）：「引擎生效值」
  /// 面板展开时调用，应答经 'enginevalues' 事件回填
  /// localEffValues/bridgeEffValues。APO 行走 telemetry v6
  /// （apoEffMode/apoEffFill），不经此路。
  void requestEngineValues() {
    _toIso?.send({'cmd': 'enginevalues'});
  }

  /// 统一系统监听启动（ready 恢复点调用；幂等）。第四十二轮
  /// S5：原 4 秒签名看守（本文件内嵌 Timer + 签名比对）收敛
  /// 进平台层 WindowsSystemMonitor——节拍/签名/变化分类（插
  /// 拔、默认变更、格式变更、服务重启、APO 拓扑）都在监听模
  /// 块里，本层只供探针闭包与事件处理。签名未变时零状态写
  /// 入、不扰动 UI（旧看守口径不变）。
  void startDeviceWatch() {
    if (_testing || !PlatformProfile.supportsBridges) return;
    if (_sysMonitor != null) return;
    _sysMonitor = createWindowsSystemMonitor(
      scanProbe: _probeDeviceScan,
      apoProbe: _probeApoAttachedIds,
      onEvent: _onSysMonEvent,
      onTick: _onSysMonTick,
      gate: () => !_deviceRefreshInFlight && !apoDetachBlocking,
    )..start();
    dbgLog('devices.watch: started (system monitor)');
  }

  /// 监听探针：一轮 apo_inspect 扫描 + 解析（任何失败 = null，
  /// 监听模块据连续失败→恢复判音频服务重启）。
  Future<Map<String, dynamic>?> _probeDeviceScan() async {
    try {
      final exePath = _findApoInspectExe();
      if (exePath == null) return null;
      final res = await windowsSystem.inspectAudioDevices(exePath);
      if (res.exitCode != 0) return null;
      final stdout = (res.stdout as String).trim();
      if (stdout.isEmpty) return null;
      final lastLine = stdout.split('\n').last.trim();
      if (lastLine.isEmpty) return null;
      return jsonDecode(lastLine) as Map<String, dynamic>;
    } catch (e, st) {
      swallow(e, st);
      return null;
    }
  }

  /// APO 拓扑探针（轻量读，不带对账副作用）：当前已附加端点
  /// id 集；非 sysapo 时不适用（返回 null，监听模块跳过）。
  Future<Set<String>?> _probeApoAttachedIds() async {
    if (audioMode != 'sysapo') return null;
    final script = _findApoConfigTool();
    if (script == null) return null;
    try {
      final res = await windowsSystem.apoStatus(script, 0.4);
      if (res.exitCode != 0) return null;
      final lines = res.stdout
          .toString()
          .trim()
          .split(RegExp(r'\r?\n'))
          .where((l) => l.trim().startsWith('{'))
          .toList();
      if (lines.isEmpty) return null;
      final data = jsonDecode(lines.last) as Map<String, dynamic>;
      final raw = data['installed_endpoints'] as List?;
      if (raw == null) return null;
      return {
        for (final e in raw)
          if (e is Map && e['EndpointId'] != null)
            e['EndpointId'].toString(),
      };
    } catch (e, st) {
      swallow(e, st);
      return null;
    }
  }

  /// 系统监听事件处理（Windows）：设备类事件应用其携带的扫
  /// 描（应用尾巴里 _applyDeviceScan 会连带 S1 chcap 重发与
  /// S3 显示收敛）；服务重启与 APO 拓扑变化走完整状态对账。
  void _onSysMonEvent(SysMonEvent e) {
    dbgLog('sysmon: ${e.kind.name} ${e.detail}');
    switch (e.kind) {
      case SysMonEventKind.deviceSetChanged:
      case SysMonEventKind.defaultDeviceChanged:
      case SysMonEventKind.formatChanged:
        if (e.scan != null) _applyMonitorScan(e.scan!);
        break;
      case SysMonEventKind.audioServiceRestarted:
        if (e.scan != null) _applyMonitorScan(e.scan!);
        if (audioMode == 'sysapo') checkApoStatus(silent: true);
        break;
      case SysMonEventKind.apoTopologyChanged:
        // 本 App 之外的附加/分离（或状态漂移）：完整对账
        // （含选中回落与 chcap 重发，都在 checkApoStatus 内）。
        checkApoStatus(silent: true);
        break;
    }
  }

  /// 监听扫描的应用（旧看守的应用段）：VAIO detect 刷新 +
  /// 在飞标记下应用设备扫描。
  void _applyMonitorScan(Map<String, dynamic> json) {
    try {
      refreshVaioDetect();
    } catch (err, st) {
      swallow(err, st);
    }
    if (_deviceRefreshInFlight) return;
    _deviceRefreshInFlight = true;
    try {
      _applyDeviceScan(json);
    } finally {
      _deviceRefreshInFlight = false;
      _lastDeviceRefreshAt = DateTime.now();
    }
  }

  /// 每轮成功扫描（含无变化轮次）：仅推进「缺席待确认」的调
  /// 和复核（旧看守 S6 例外口径——不持续应用则消失设备的修
  /// 复永不落定）。
  void _onSysMonTick(Map<String, dynamic> scan) {
    if (_reconcileAbsentSince.isEmpty) return;
    if (_deviceRefreshInFlight) return;
    _deviceRefreshInFlight = true;
    try {
      _applyDeviceScan(scan);
    } finally {
      _deviceRefreshInFlight = false;
      _lastDeviceRefreshAt = DateTime.now();
    }
  }

  /// Linux 统一系统监听启动（ready 恢复点调用；幂等）。与
  /// Windows 侧同词汇：探针为状态层 Linux 字段快照，节拍回
  /// 调催 isolate 回推 linuxstatus 新真值，事件只做日志与刷
  /// 新催促（字段真值由 linuxstatus 事件回填并同步基线）。
  void startLinuxSystemMonitor() {
    if (_testing || !PlatformProfile.isLinux) return;
    if (_linuxSysMonitor != null) return;
    _linuxSysMonitor = createLinuxSystemMonitor(
      probe: () => LinuxAudioSnapshot(
        defaultSink: linuxDefaultSink,
        captureSource: linuxCaptureSource,
        virtualSinkPresent: linuxVirtualSink,
        captureActive: linuxCaptureActive,
        driverLoaded: linuxDriverLoaded,
      ),
      onEvent: _onLinuxSysMonEvent,
      onTick: () => _toIso?.send({'cmd': 'linuxstatus'}),
    )..start();
    dbgLog('linux sysmon: started');
  }

  void _onLinuxSysMonEvent(SysMonEvent e) {
    dbgLog('linux sysmon: ${e.kind.name} ${e.detail}');
    _toIso?.send({'cmd': 'linuxstatus'});
    _notifyUi();
  }

  /// 链路对账后的设备刷新请求（2026-11-14）：applyPipelineChain
  /// 是模式/管线应用的唯一收口，在此异步补一次刷新+调和，刚切
  /// 完模式时下拉与默认确认即为最新真值。在飞/1.5 秒内刚刷过
  /// 则合并跳过，避免对账高频调用打爆 apo_inspect 子进程。
  void _requestDeviceRefreshAfterChain() {
    if (_testing || !PlatformProfile.supportsBridges) return;
    if (_deviceRefreshInFlight) return;
    final last = _lastDeviceRefreshAt;
    if (last != null &&
        DateTime.now().difference(last) <
            const Duration(milliseconds: 1500)) {
      return;
    }
    refreshAudioDevices();
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
      final rebootRequired = res.exitCode == 8;
      final scriptOk = res.exitCode == 0 || rebootRequired;
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
        if (rebootRequired) {
          // 退出码 8（随包 install_vaio.ps1）：驱动已装好，但旧
          // 驱动镜像尚在内存中（卸载时挂起删除、重启才卸载），
          // 新驱动重启后才生效——不是失败，不写 lastVaioError。
          dbgLog('vaio install: installed; reboot required for the '
              'new driver to take effect (exit 8)');
          postNotice('AuraVAIO 驱动已安装；旧驱动尚在内存中，请重启电脑使新驱动完全生效',
              level: NoticeLevel.warning);
        }
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
    _displayGen++; // S3：目标端点变更 → 显示合成可覆盖
    config.apoTargetEndpoint = endpoint;
    // 全面复审 S2（UI-5）：切换目标端点即按已知装机真值重算
    // apoAttached——此前须手动刷新才纠正，切到未附加端点时状态
    // 行与附加 chip 仍呈旧端点的「已附加」。
    apoAttached =
        apoInstalledEndpoints.any((e) => _apoEndpointMatches(e, endpoint));
    persistRoutingChange();
    // 跟随端点切换（第四十一轮）：telemetry 读者切到新端点的
    // 分块；解析不到全 id 时回落全局块（读者侧空目标口径）。
    _toIso?.send({'cmd': 'apotarget', 'endpointId': selectedApoEndpointId});
    _sendChCap();
    _notifyUi();
  }

  /// 选中 APO 端点在设备扫描表中的 mix 声道数（未知 = null）。
  int? _selectedApoEndpointCh() {
    final id = selectedApoEndpointId;
    for (final d in wasapiDevices) {
      if (d.id == id && d.ch > 0) return d.ch;
    }
    return null;
  }

  /// 设备值（id 或名称）在扫描表中的 mix 声道数；未知 = null。
  int? _scanChOf(String deviceValue) {
    final d = _resolveWasapiDevice(deviceValue);
    if (d == null || d.ch <= 0) return null;
    return d.ch;
  }

  /// 第四十五轮 S2：分模式声道能力（**设备事实**，状态侧唯一
  /// 权威计算点；user 裁定 2026-11-17）。返回 null = 状态侧无
  /// 确知量、不下发——由 isolate 侧真源决定（ASIO 起桥预置 /
  /// 本地泵 devCh 连续喂入）。非 Windows 恒 null（Linux 链不
  /// 消费 chcap，泵 devCh 自行喂入）。
  ///
  /// - sysapo：选中端点 mix 声道（未知 → 8 不钳）；
  /// - vbcallback：VB 协商声道（S3，未协商 → 8）；
  /// - 管线 capture 链（WASAPI 入 + WASAPI 出）：min{入， 出}
  ///   扫描声道，单侧未知取已知侧，全未知 → 8；
  /// - 管线 vaio 链：VAIO 本体 8，上限 = 其 WASAPI 输出端点
  ///   （vaioOutputEndpoint）扫描声道，未选/未知 → 8；
  /// - 管线 asio 链 / auto：null。
  int? _capabilityChForMode() {
    if (!PlatformProfile.isWindows) return null;
    if (audioMode == 'sysapo') return _selectedApoEndpointCh() ?? 8;
    if (audioMode == 'vbcallback') return vbNegotiatedCh ?? 8;
    if (modeCategory == AudioModes.categoryPipeline) {
      final chain = AudioModes.composeChain(
          input: config.pipelineInput, output: config.pipelineOutput);
      switch (chain) {
        case PipelineChain.capture:
          final i = _scanChOf(config.pipelineInputDevice);
          final o = _scanChOf(config.pipelineOutputDevice);
          if (i != null && o != null) return i < o ? i : o;
          return i ?? o ?? 8;
        case PipelineChain.vaio:
          final o = _scanChOf(config.vaioOutputEndpoint);
          if (o == null) return 8;
          return o < 8 ? o : 8;
        case PipelineChain.asio:
          return null;
      }
    }
    return null;
  }

  /// 把分模式能力发给 isolate 钳制器（第四十二轮 S1 立 chcap，
  /// 第四十五轮 S2 泛化到全模式）。触发集 = 模式/选择/扫描/
  /// 协商变化（各 setter、设备刷新、vbstatus、isolate ready）。
  void _sendChCap() {
    final cap = _capabilityChForMode();
    if (cap == null) return;
    _toIso?.send({'cmd': 'chcap', 'ch': cap});
  }

  // ── 第四十二轮 S3：显示声道数即时合成 ────────────────────
  // 主页电平布局/链输入门控等显示面只认 vizChannelCount，而它
  // 此前仅由 viz 事件（音频流动时）更新：静默改声道设置/端点
  // 改格式后显示纹丝不动、要等出声（user 实测）。现改为：流
  // 活跃（2 秒内有声道事件）用流真值，其余时刻由配置 + 设备
  // 格式 + S1 钳制即时合成，并经 _notifyUi 收敛推入。

  /// viz 声道事件到达时登记流真值（state_events 调用）。
  /// 登记的是经生效宽钳制后的显示宽（第四十六轮 S1），
  /// 不是原始流宽。
  void noteStreamChannelCount(int cc) {
    _streamCh = clampStreamChForDisplay(cc);
    _lastVizChAt = DateTime.now();
  }

  /// 第四十六轮 S1：流宽进显示前按生效宽钳制。APO 遥测的
  /// chCount 是端点流格式宽（设 5.1 放 7.1 仍报 8），主页
  /// 直认 vizChannelCount——不钳则显示跟着内容走，且播放
  /// 中改声道数量会被恒活跃的流真值钉死不变（user 实测
  /// 两例）。口径：手动 = min{流宽， clamp（设置， 能力）}；
  /// 自动 = min{流宽， 能力（已知时）}。原始流宽仍由事件
  /// 侧用于 stageCh 切片等来源真相用途，不经此处。
  int clampStreamChForDisplay(int cc) {
    if (cc <= 0) return cc;
    var eff = cc;
    final cap = _displayCapCh();
    if (channelsCountMode == 1) {
      var want = channelsCount;
      if (cap != null) want = clampChannelsToCapability(want, cap);
      if (eff > want) eff = want;
    } else if (cap != null && eff > cap) {
      eff = cap;
    }
    return _normCh(eff);
  }

  bool get _streamChLive =>
      _lastVizChAt != null &&
      _streamCh > 0 &&
      DateTime.now().difference(_lastVizChAt!) <
          const Duration(seconds: 2);

  static int _normCh(int ch) => ch >= 8 ? 8 : (ch >= 6 ? 6 : (ch >= 4 ? 4 : 2));

  /// 显示侧钳制能力：与 isolate 生效口径同源——直接取 S2 的
  /// 分模式能力计算（第四十五轮起单一真相；r44 版只覆盖
  /// sysapo 与管线输出侧，现含管线入侧 min 与 VAIO/VB）。
  /// 流活跃时 _streamCh 真值优先于一切合成（见
  /// displayChannelCount 首行）。
  int? _displayCapCh() => _capabilityChForMode();

  /// 显示用工作声道数（合成口径见上）。
  int get displayChannelCount {
    if (_streamChLive) return _streamCh;
    if (channelsCountMode == 1) {
      var want = channelsCount;
      final cap = _displayCapCh();
      if (cap != null) {
        want = clampChannelsToCapability(want, cap);
      }
      return _normCh(want);
    }
    if (audioMode == 'sysapo') {
      final devCh = _selectedApoEndpointCh();
      if (devCh != null) return _normCh(devCh);
    }
    return effectiveChannelCount;
  }

  /// 把合成值推入 vizChannelCount（流活跃时不推，免与真值打架）。
  ///
  /// 覆盖门（收口复验修正）：vizChannelCount 的现值若非零、且
  /// 从未有过流事件、且自上次合成以来无显示相关变更，则它
  /// 只能是外部刚写入的真值（如测试注入的流声道数），合成值
  /// 不得覆盖——合成只接管三类情形：从未写入（0）、流已停
  /// （有过流事件）、显示相关状态变更之后（代际递增）。
  void refreshDisplayChannelCount() {
    if (_streamChLive) return;
    if (vizChannelCount.value != 0 &&
        _lastVizChAt == null &&
        _displayGen == _displayGenConsumed) {
      return;
    }
    final d = displayChannelCount;
    if (vizChannelCount.value != d) vizChannelCount.value = d;
    _displayGenConsumed = _displayGen;
  }

  /// 存量目标值（全 id / 友好名 / 短 GUID 三种历史形状）→ 端点
  /// 全 id（第四十一轮）：先查 apo_config 枚举（id/name），再查
  /// 已附加清单。解析不到返回 ''（消费侧回落全局口径）。
  String resolveApoEndpointId(String stored) {
    if (stored.isEmpty) return '';
    final t = stored.toLowerCase();
    for (final e in apoKnownEndpoints) {
      final id = e['id']?.toString() ?? '';
      final name = e['name']?.toString() ?? '';
      if (id.toLowerCase() == t || name.toLowerCase() == t) return id;
      if (t.length >= 8 && id.toLowerCase().contains(t)) return id;
    }
    for (final e in apoInstalledEndpoints) {
      if (_apoEndpointMatches(e, stored)) {
        return e['EndpointId']?.toString() ?? '';
      }
    }
    return '';
  }

  /// 当前选中端点的全 id（解析不到为 ''）。
  String get selectedApoEndpointId =>
      resolveApoEndpointId(config.apoTargetEndpoint);

  /// 某端点（全 id / 名 / 短 GUID 均可）当前是否已附加。
  bool apoEndpointAttached(String target) =>
      apoInstalledEndpoints.any((e) => _apoEndpointMatches(e, target));

  /// 一键附加排队集的勾选切换（会话级，不落盘）。只对未附
  /// 加端点有意义：空 → 勾（排队）、勾 → 空（取消排队）。
  void toggleApoChecked(String endpointId, bool on) {
    if (on) {
      apoCheckedEndpoints.add(endpointId);
      // 勾选即选中（第五十六轮 S1，user 裁定）：电平/可视化
      // 跟随选中端点，勾上时顺带选中该端点；用户仍可点行改
      // 选其它端点。取消勾选不动选中。
      if (selectedApoEndpointId != endpointId) {
        setApoTargetEndpoint(endpointId);
      }
    } else {
      apoCheckedEndpoints.remove(endpointId);
    }
    _notifyUi();
  }

  /// 已附加端点锁定切换（第四十六轮 S3 立、第四十七轮 S1
  /// 改可逆）：暗勾点按 → 亮叉锁定，叉再点回暗勾（user 裁
  /// 定——r46 的「叉单向、仅卸载可解」被推翻）。未附加端
  /// 点不接受锁定切换；分离后锁定由调和自动遗忘。
  void toggleApoLocked(String endpointId) {
    if (!apoEndpointAttached(endpointId)) return;
    if (!apoLockedEndpoints.remove(endpointId)) {
      apoLockedEndpoints.add(endpointId);
    }
    _notifyUi();
  }

  void setMonitorMirroring(bool enabled) {
    // ASIO-2 补全（2026-11-14，业主裁定）：监听镜像已落地——
    // VAIO 桥内第二路 WASAPI 渲染把处理后音频分路到系统默认
    // 物理端点。值经 vaiomode/vaiorestart 载荷下发 isolate →
    // 桥 config 的 mirror 键消费；桥在跑则热重启生效（与
    // setVaioOutputEndpoint 同口径）。
    if (config.monitorMirroring == enabled) return;
    config.monitorMirroring = enabled;
    persistRoutingChange();
    if (vaioActive) {
      _toIso?.send({
        'cmd': 'vaiorestart',
        'outputEndpoint': config.vaioOutputEndpoint,
        'monitorMirror': enabled,
      });
    }
    _notifyUi();
  }

  // 全面复审 S6（UI-12)：旧 setApoAttached 已删——零调用方，且可
  // 绕过 apo_config 核验直接伪造 attached 态；附加真值只由
  // refreshAudioDevices 的装机扫描与 setApoTargetEndpoint 重算。

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
      // 声道档位镜像同步（ASIO-4）：非法/缺失与驱动同口径回落 2。
      final ch = registry.readDword(
        r'HKCU\SOFTWARE\AuraDSP\AsioDriver',
        'Channels',
      );
      asioDriverChannels =
          (ch != null && const {2, 4, 6, 8}.contains(ch)) ? ch : 2;
      // S3：汇后端端点以 config 为真相、注册表为驱动消费面——
      // 不一致时把 config 值推回注册表（覆盖新装/还原/手改注册
      // 表的漂移），驱动下次 Open 即按指定端点打开。
      final regEp = registry.readString(
        r'HKCU\SOFTWARE\AuraDSP\AsioDriver',
        'RenderEndpoint',
      );
      if ((regEp ?? '') != config.asioRenderEndpoint) {
        registry.writeString(
          r'HKCU\SOFTWARE\AuraDSP\AsioDriver',
          'RenderEndpoint',
          config.asioRenderEndpoint,
        );
      }
    } catch (e, st) {
      swallow(e, st);
      asioDriverInstalled = false;
    }
    _notifyUi();
  }

  /// 设置 AuraDSP 虚拟 ASIO 驱动的声道档位（全面复审 S3 / ASIO-4）。
  /// 写 HKCU 注册表值（驱动下次被 DAW 创建时读取生效）；成功返回
  /// true。档位外数值直接拒绝。
  bool setAsioDriverChannels(int ch) {
    if (!const {2, 4, 6, 8}.contains(ch)) return false;
    final ok = registry.writeDword(
      r'HKCU\SOFTWARE\AuraDSP\AsioDriver',
      'Channels',
      ch,
    );
    if (ok) {
      asioDriverChannels = ch;
      _notifyUi();
    }
    return ok;
  }

  /// 设置虚拟 ASIO 汇的后端渲染端点（S3）。[endpointId] 为端点
  /// id（'' = 跟随系统默认）。config 落盘 + 注册表同步写（驱动汇
  /// 下次 Open 时消费；DAW 正在运行时需重连才切换）。返回注册表
  /// 写入是否成功（config 本身恒已更新）。
  bool setAsioRenderEndpoint(String endpointId) {
    config.asioRenderEndpoint = endpointId;
    final ok = registry.writeString(
      r'HKCU\SOFTWARE\AuraDSP\AsioDriver',
      'RenderEndpoint',
      endpointId,
    );
    persistRoutingChange();
    _notifyUi();
    return ok;
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
      // 裁定必须与注册表复查一致（资源计划 Stage 0 / §8.4）：
      // 工具自报成功但复查无键不算注册成功——旧口径 toolOk 单
      // 独短路，脚本/驱动侧假成功时状态机对外说谎。
      final toolClaimedOk = res.toolOk ?? (res.exitCode == 0);
      final ok = toolClaimedOk && asioDriverInstalled;
      if (!ok) {
        lastAsioError = (res.toolOk == true && !asioDriverInstalled)
            ? 'ASIO 驱动注册未生效：脚本自报成功，但注册表复查未见 AuraDSP Driver 键'
            : 'ASIO 驱动注册未完成，请确认在 UAC 提权弹窗中选择“是”以授予管理员权限';
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
      // 同注册侧口径（Stage 0 / §8.4）：自报成功但键还在，
      // 就是没卸掉，必须如实报未生效而非成功。
      final toolClaimedOk = res.toolOk ?? (res.exitCode == 0);
      final ok = toolClaimedOk && !asioDriverInstalled;
      if (!ok) {
        lastAsioError = (res.toolOk == true && asioDriverInstalled)
            ? 'ASIO 驱动注销未生效：脚本自报成功，但注册表复查显示驱动仍在册'
            : 'ASIO 驱动注销未完成';
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

  /// 启动自动附加（第十二轮 B1）：恢复为 sysapo、记忆目标仍在
  /// 系统枚举中、且目标未附加时，启动后自动附加一次——开机自启
  /// 场景免于每次手动点附加。仅启动路径调用，一次性闩防重复；
  /// 附加走提权（UAC 由用户确认，系统硬要求）。结果走通知，
  /// 失败原因在 lastApoError（面板可见），不无声吞掉。
  Future<void> maybeAutoAttachApo() async {
    if (_apoAutoAttachTried) return;
    _apoAutoAttachTried = true;
    if (!PlatformProfile.supportsBridges) return;
    if (audioMode != 'sysapo') return;
    final target = config.apoTargetEndpoint;
    if (target.isEmpty) return;
    await checkApoStatus(silent: true);
    if (apoAttached) return;
    final t = target.toLowerCase();
    final exists = apoKnownEndpoints.any((e) {
      final id = e['id']?.toString().toLowerCase() ?? '';
      final name = e['name']?.toString().toLowerCase() ?? '';
      // 目标存值三种历史形状：端点全 ID / 友好名 / 短 GUID
      // （短 GUID 是全 ID 的子串，故有长度下限的子串匹配）。
      return id == t || name == t || (t.length >= 8 && id.contains(t));
    });
    if (!exists) {
      dbgLog('apo auto-attach: remembered target not present, skipped');
      return;
    }
    final ok = await attachSystemApo();
    if (ok) {
      postNotice('System APO 已自动附加到上次使用的设备');
    } else {
      postNotice(lastApoError ?? 'System APO 自动附加未完成，请在设置页手动附加',
          level: NoticeLevel.error);
    }
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
            // 全部端点枚举（第十二轮 B1）：键为 id/name/direction
            // 等（与 installed 的 EndpointId/DeviceName 形状不同，
            // 消费侧分开匹配，勿混用 _apoEndpointMatches）。
            final rawAll = data['endpoints'] as List?;
            if (rawAll != null) {
              apoKnownEndpoints = rawAll
                  .map((e) => Map<String, dynamic>.from(e as Map))
                  .toList();
            }
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

            // 三态集调和 + 选中回落：排队集只存未附加端点
            // （已附加者移出，第四十六轮 S3——旧「恒入复选集」
            // 口径会让分离后的端点以亮勾复活、且选中即排队，
            // 与三态状态机相悖）；锁定集只存已附加端点（分
            // 离即遗忘）；选中端点在枚举与已附加清单中均消
            // 失、且确有已附加端点时，回落到首个已附加端点
            // 并明示（裁定③）。枚举为空（设备抖动）时不回落。
            apoCheckedEndpoints.removeWhere(apoEndpointAttached);
            apoLockedEndpoints
                .removeWhere((id) => !apoEndpointAttached(id));
            final selId = selectedApoEndpointId;
            if (target.isNotEmpty &&
                selId.isEmpty &&
                apoKnownEndpoints.isNotEmpty &&
                installed.isNotEmpty) {
              final fb = installed.first;
              final fbId = fb['EndpointId']?.toString() ?? '';
              if (fbId.isNotEmpty) {
                config.apoTargetEndpoint = fbId;
                apoAttached = true;
                persistRoutingChange();
                _toIso?.send({'cmd': 'apotarget', 'endpointId': fbId});
                _sendChCap();
                postNotice(
                    '所选 APO 端点已消失，已回落到已附加端点'
                    '「${fb['DeviceName']?.toString() ?? fbId}」',
                    level: NoticeLevel.warning);
              }
            }
            // telemetry 跟随对账：枚举到达后选中端点可能首次可
            // 解析（启动时序），把跟随目标补发读者（幂等）。
            if (audioMode == 'sysapo') {
              _toIso?.send(
                  {'cmd': 'apotarget', 'endpointId': selectedApoEndpointId});
              // 声道能力对账（第四十二轮 S1）：端点改格式/回落
              // 后把最新 mix 声道数补发钳制器（幂等）。
              _sendChCap();
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

  /// 单端点附加本体（第四十一轮抽取）：工具调用 + 复查裁定。
  /// 身份令牌经 install --props 在同次提权内写入 FX 属性集
  /// （APO 实例 Initialize 时读回，多端点分座/分块靠它）。
  /// 第四十二轮 S2：声道覆写已废除（设置只剩全局一份），附加
  /// 时 props 恒传 clear——令牌照写，同时清掉 r41 时代可能残
  /// 留在该端点的 FX 覆写值，防其作为「初值」压过全局。
  Future<({bool ok, String? error})> _attachOneApoEndpoint(
    String target, {
    required bool composite,
    bool elevated = true,
  }) async {
    final script = _findApoConfigTool();
    if (script == null) {
      return (ok: false, error: '未找到 apo_config.exe 驱动管理工具');
    }
    final res = await windowsSystem.apoInstall(
      script,
      target: target,
      composite: composite,
      elevated: elevated,
      propsMode: 'clear',
      propsFill: 'clear',
    );
    // apo 操作留痕（Stage 0 / §8.2）：此前附加/卸载在主日志
    // 里完全无记录，真机排障只能靠结果文件残骸反推时序。
    dbgLog('apo attach: target=$target composite=$composite '
        'exit=${res.exitCode} toolOk=${res.toolOk} '
        'err=${res.toolError ?? res.toolMessage ?? ""}');
    // 工具自报失败（如端点匹配歧义/注册表写入失败）：原因
    // 就在结果通道里，直接呈现，不再走退出码猜层。工具经
    // --result-file 跨 UAC 边界回传 JSON 裁定（真机实证：
    // 手动运行工具全程正常，App 路径失败却只报 UAC）。
    if (res.toolOk == false) {
      return (
        ok: false,
        error:
            'System APO 附加失败：${res.toolMessage ?? res.toolError ?? '工具未报告原因'}'
      );
    }
    await Future.delayed(const Duration(milliseconds: 600));
    await checkApoStatus(timeout: 0.6, silent: true);
    // 裁定 = 工具自报与状态复查合取（细审 R-C M-2 的 App
    // 侧一半）：复查未见该端点附加时按层报未确认，不假报成功。
    final attachedNow =
        apoInstalledEndpoints.any((e) => _apoEndpointMatches(e, target));
    if (!attachedNow) {
      // 失败文案按层区分（旧版一律归咎 UAC，对真机实证的
      // 「提权已执行但工具侧失败」毫无诊断价值）：提权进程
      // 退出码非 0 = UAC 拒绝/拉起失败；退出码 0 但状态复查
      // 无附加记录 = 工具已运行但未完成附加。
      return (
        ok: false,
        error: res.exitCode != 0
            ? 'System APO 附加未生效：提权执行失败（退出码 ${res.exitCode}），请确认在 UAC 提权弹窗中选择“是”以授予管理员权限'
            : 'System APO 附加未生效：提权工具已执行，但未产生附加记录（端点匹配或注册表写入未完成）。可用管理员终端进入 driver 目录运行 apo_config.exe install 查看具体原因'
      );
    }
    return (ok: true, error: null);
  }

  /// 一键将 System APO 挂载到指定音频端点（支持 Windows UAC 提权授权，支持复合插槽）
  Future<bool> attachSystemApo({
    String? endpointNameOrId,
    bool? composite,
    bool elevated = true,
  }) async {
    if (!PlatformProfile.supportsBridges) return false;
    final target = (endpointNameOrId != null && endpointNameOrId.isNotEmpty)
        ? endpointNameOrId
        : config.apoTargetEndpoint;
    if (target.isEmpty) {
      lastApoError = '请先选择需要附加的音频端点';
      _notifyUi();
      return false;
    }
    isApoOperating = true;
    lastApoError = null;
    _notifyUi();
    try {
      final r = await _attachOneApoEndpoint(
        target,
        composite: composite ?? apoCompositeMode,
        elevated: elevated,
      );
      if (!r.ok) lastApoError = r.error;
      isApoOperating = false;
      _notifyUi();
      return r.ok;
    } catch (e) {
      lastApoError = 'System APO 附加异常: $e';
      isApoOperating = false;
      _notifyUi();
      return false;
    }
  }

  /// 一键附加全部复选端点（第四十一轮）：逐一附加未附加者，
  /// 单个失败不连带其余；结束统一复查并汇总通知。每个端点一
  /// 次提权（工具按端点执行），已附加的跳过不重复弹窗。
  Future<int> attachCheckedApoEndpoints() async {
    if (!PlatformProfile.supportsBridges || isApoOperating) return 0;
    final pending = apoCheckedEndpoints
        .where((id) => !apoEndpointAttached(id))
        .toList();
    if (pending.isEmpty) {
      postNotice('所勾选端点均已附加');
      return 0;
    }
    isApoOperating = true;
    lastApoError = null;
    _notifyUi();
    var okCount = 0;
    var failCount = 0;
    try {
      for (final id in pending) {
        final r = await _attachOneApoEndpoint(id, composite: apoCompositeMode);
        if (r.ok) {
          okCount++;
        } else {
          failCount++;
          dbgLog('apo attach-checked: $id failed: ${r.error}');
        }
      }
    } catch (e) {
      failCount++;
      dbgLog('apo attach-checked: exception $e');
    }
    await checkApoStatus(timeout: 0.6, silent: true);
    isApoOperating = false;
    if (failCount == 0) {
      postNotice('已附加 $okCount 个端点');
    } else {
      lastApoError = '一键附加：成功 $okCount 个，失败 $failCount 个';
      postNotice('一键附加完成：成功 $okCount 个，失败 $failCount 个',
          level: NoticeLevel.warning);
    }
    _notifyUi();
    return okCount;
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

      // 卸载对象口径（两段定罪）：第六轮项 3 定过「卸实际已
      // 附加的端点、不是下拉的当前选择」；Stage 0（§8.2）再
      // 定「无显式端点 = 全端点卸载」——中间实现只卸清单首个
      // 端点，而状态行是任一端点真值，多端点附加时一次点击
      // 数学上卸不干净（开发机实测 3 端点附加、卸后仍显已附
      // 加 + 心跳活跃，显示的全是真值）。工具无 target 时本
      // 就卸全部（台账 ∪ 实时扫描），裁定随之为复查清单空。
      await checkApoStatus(silent: true);
      final explicit =
          endpointNameOrId != null && endpointNameOrId.isNotEmpty;
      final target = explicit ? endpointNameOrId : '';
      final res = await windowsSystem.apoUninstall(
        script,
        target: target,
        elevated: elevated,
      );
      dbgLog('apo detach: target=${explicit ? target : "(all)"} '
          'exit=${res.exitCode} toolOk=${res.toolOk} '
          'err=${res.toolError ?? res.toolMessage ?? ""}');

      await Future.delayed(const Duration(milliseconds: 600));
      await checkApoStatus(timeout: 0.6);

      if (res.toolOk == false && lastApoError == null) {
        lastApoError =
            'System APO 卸载失败：${res.toolMessage ?? res.toolError ?? '工具未报告原因'}';
      }
      // 裁定与 attach 对称（细审 R-C M-1 的 App 侧一半）：
      // 工具自报（或退出码）成功且复查确认已摘除，才算卸载
      // 完成。显式单端点时查该端点；全端点卸载时查清单为空
      // （任一端点残留都算未完成——状态行正是任一端点真值）。
      final stillThere = explicit
          ? apoInstalledEndpoints.any((e) => _apoEndpointMatches(e, target))
          : apoInstalledEndpoints.isNotEmpty;
      final ok = (res.toolOk ?? (res.exitCode == 0)) && !stillThere;
      if (!ok && lastApoError == null) {
        lastApoError = stillThere
            ? 'System APO 卸载后复查仍有端点处于附加状态，请重试或检查工具返回明细'
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

  /// 一键卸载只卸带叉端点（第四十八轮 S2，user 裁定
  /// 2026-11-18）：三态口径定版——亮勾=待附加、暗勾=已
  /// 附加保持、亮叉=待卸载。本方法逐一卸载锁定集 ∩ 已
  /// 附加者，未标叉的已附加端点保持不动；单个失败不连
  /// 带其余，结束汇总通知。与 detachSystemApo() 无参全
  /// 卸口径分工：全卸只保留给模式切离的自动卸载（切离
  /// sysapo 必须卸净才能离开，见 _runApoDetachThenMode）。
  /// 一键卸载的目标集（S2）：锁定集 ∩ 已附加，纯函数供
  /// 单测与 detachLockedApoEndpoints 共用。
  List<String> apoDetachLockedTargets() =>
      apoLockedEndpoints.where(apoEndpointAttached).toList();

  Future<int> detachLockedApoEndpoints() async {
    if (!PlatformProfile.supportsBridges || isApoOperating) return 0;
    final targets = apoDetachLockedTargets();
    if (targets.isEmpty) {
      postNotice('没有标叉的端点可卸载：先把要卸载的已附加端点点成叉',
          level: NoticeLevel.warning);
      return 0;
    }
    var okCount = 0;
    var failCount = 0;
    for (final id in targets) {
      final ok = await detachSystemApo(endpointNameOrId: id);
      if (ok) {
        okCount++;
      } else {
        failCount++;
        dbgLog('apo detach-locked: $id failed: ${lastApoError ?? ''}');
      }
    }
    if (failCount == 0) {
      postNotice('已卸载 $okCount 个端点');
    } else {
      postNotice('一键卸载完成：成功 $okCount 个，失败 $failCount 个',
          level: NoticeLevel.warning);
    }
    _notifyUi();
    return okCount;
  }
}
