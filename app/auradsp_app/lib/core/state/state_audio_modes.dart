// part of state.dart —— P6 按区拆分，extension 包装零逻辑改动。
part of '../state.dart';

/// 音频处理模式/管线 + 设备枚举 + VAIO 驱动 + ASIO 注册 + System APO 运维。
///
/// 方法体逐字保留自 AppModel 类体（notifyListeners() 按 P2 约定改调
/// _notifyUi()）。

extension AudioModesState on AppModel {

  // ---- 模式与管线 ----

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
      config.pipelineOutput =
          AudioModes.pipelineOutputForMode(valid, config.pipelineOutput);
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
    ConfigManager.save(config);
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
      _toIso?.send({
        'cmd': 'vaiomode',
        'on': isVaio,
        'outputEndpoint': config.vaioOutputEndpoint,
      });
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
    ConfigManager.save(config);
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
    ConfigManager.save(config);
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
    ConfigManager.save(config);
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
      ConfigManager.save(config);
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
        // 漂移对账：模式未变时旧实现只落盘，但 UI 模式与 isolate
        // 桥状态可能已漂移（如持久化模式与就绪恢复不一致、桥启动
        // 曾失败）——用户点遍输入输出都无声无 viz，唯独某次真
        // 模式切换才把桥带起来（真机报告 2026-11-09 阶段 1-3）。
        // 当前模式的桥未在运行时补发一次启动命令（isolate 侧
        // 启动幂等），让漂移自愈。
        if (PlatformProfile.supportsBridges) {
          if (composed == 'vaio' && !vaioActive) {
            dbgLog('pipeline.reconcile: resend vaiomode (vaioActive=false)');
            _toIso?.send({
              'cmd': 'vaiomode',
              'on': true,
              'outputEndpoint': config.vaioOutputEndpoint,
            });
          } else if (composed == 'asio' && !asioActive) {
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
        ConfigManager.save(config);
        _notifyUi();
      }
    } else {
      ConfigManager.save(config);
      _notifyUi();
    }
  }

  /// ADR-009: 切换管线输入源（Virtual ASIO / AuraVAIO / WASAPI）
  void setPipelineInput(String inType) {
    config.pipelineInput = inType;
    ConfigManager.save(config);
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
        ConfigManager.save(config);
        _notifyUi();
      }
    } else {
      ConfigManager.save(config);
      _notifyUi();
    }
  }

  void setPipelineInputDevice(String device) {
    config.pipelineInputDevice = device;
    ConfigManager.save(config);
    _notifyUi();
  }

  void setPipelineOutputDevice(String device) {
    config.pipelineOutputDevice = device;
    ConfigManager.save(config);
    _notifyUi();
  }

  void setPipelineInputEnabled(bool enabled) {
    config.pipelineInputEnabled = enabled;
    ConfigManager.save(config);
    _notifyUi();
  }

  void setPipelineOutputEnabled(bool enabled) {
    config.pipelineOutputEnabled = enabled;
    ConfigManager.save(config);
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
          }
        } else {
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
        lastVaioError =
            'AuraVAIO 安装未完成 (退出码: ${res.exitCode})，请在 UAC 弹窗中选择允许提权';
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
      if (ok) lastVaioError = null;
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
    ConfigManager.save(config);
    _notifyUi();
  }

  void setMonitorMirroring(bool enabled) {
    config.monitorMirroring = enabled;
    ConfigManager.save(config);
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
  Future<void> checkApoStatus({double timeout = 0.4, bool silent = false}) async {
    if (!PlatformProfile.supportsBridges) {
      apoAttached = false;
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

            final target = config.apoTargetEndpoint;
            if (target.isEmpty) {
              apoAttached = installed.isNotEmpty;
            } else {
              apoAttached = installed.any((e) {
                final short = e['short_guid']?.toString().toLowerCase() ?? '';
                final name = e['DeviceName']?.toString().toLowerCase() ?? '';
                final id = e['EndpointId']?.toString().toLowerCase() ?? '';
                final t = target.toLowerCase();
                return short.contains(t) ||
                    name.contains(t) ||
                    id.contains(t) ||
                    t.contains(short);
              });
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

      final ok = res.toolOk == true || ((res.exitCode == 0) && apoAttached);
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

      final target = (endpointNameOrId != null && endpointNameOrId.isNotEmpty)
          ? endpointNameOrId
          : config.apoTargetEndpoint;
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
      final ok = res.toolOk == true || (res.exitCode == 0 && res.toolOk == null);
      if (!ok && lastApoError == null) {
        lastApoError = 'System APO 卸载未完成，请确认在 UAC 提权弹窗中选择“是”';
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
