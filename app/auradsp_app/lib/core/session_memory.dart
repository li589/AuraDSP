/*
 * session_memory.dart — AuraDSP 持久化会话记忆引擎
 *
 * 职责：在用户调音与参数变动时，防抖自动保存全局状态快照到
 * %APPDATA%/AuraDSP/session_state.json。
 * 启动时自动读取并无缝重放下发，实现“退出即保存，打开即恢复”。
 */

import 'dart:convert';
import 'dart:io';

import 'config.dart';
import 'audio_modes.dart';
import 'plugin_manager.dart';
import 'presets.dart';
import 'state.dart';

abstract final class SessionMemory {
  static String get sessionPath =>
      '${ConfigManager.baseDir}${Platform.pathSeparator}session_state.json';

  /// 保存会话快照
  static bool save(AppModel m) {
    try {
      final dir = Directory(ConfigManager.baseDir);
      if (!dir.existsSync()) dir.createSync(recursive: true);

      final snapshot = PresetLibrary.snapshot(m, name: '__session_memory__');
      final slotSnapshots = <Map<String, dynamic>>[];
      for (var s = 0; s < PluginManager.kMaxSlots; s++) {
        final p = m.pluginManager.getSlotPlugin(s);
        slotSnapshots.add({
          'slot': s,
          'path': p?.path,
          'id': p?.id,
          'bypassed': m.pluginManager.isSlotBypassed(s),
          'stage': m.pluginManager.getSlotStage(s),
          'channels': m.pluginManager.getSlotChannels(s),
        });
      }

      // 脏跟踪（决策 #3）：保存前统一重算一次（防抖后的低频路径），
      // 顺带把「自定义（未保存）」徽标刷给 UI。
      m.evaluatePresetDirty();

      final payload = {
        // v5：+ appliedPresetFingerprint / presetDirty —— 未保存的自定义态
        // 随会话记忆，重启后仍显示「自定义（未保存）」（决策 #3）。
        'version': 6,
        'savedAt': DateTime.now().toIso8601String(),
        'activePresetName': m.activePresetName,
        'appliedPresetFingerprint': m.appliedPresetFingerprint,
        'presetDirty': m.presetDirty,
        'locale': m.locale.languageCode,
        'themeId': m.themeId.name,
        'channelsMode': m.channelsMode,
        'audioMode': m.audioMode,
        'modeCategory': m.modeCategory,
        'attachmentMode': m.attachmentMode,
        'pipelineInput': m.pipelineInput,
        'pipelineOutput': m.pipelineOutput,
        'pipelineInputDevice': m.pipelineInputDevice,
        'pipelineOutputDevice': m.pipelineOutputDevice,
        'pipelineInputEnabled': m.pipelineInputEnabled,
        'pipelineOutputEnabled': m.pipelineOutputEnabled,
        'asioDriver': m.config.asioDriver,
        'asioBufSize': m.config.asioBufSize,
        'asioOutPair': m.config.asioOutPair,
        'vaioOutputEndpoint': m.config.vaioOutputEndpoint,
        'apoTargetEndpoint': m.config.apoTargetEndpoint,
        'monitorMirroring': m.monitorMirroring,
        'source51Mode': m.source51Mode,
        'convIrPath': m.convIrPath,
        'ddcPath': m.ddcPath,
        'lpCode': m.lpCode,
        'arbmagString': m.arbmagString,
        'pluginPath': m.pluginManager.getSlotPlugin(0)?.path,
        'pluginId': m.pluginManager.getSlotPlugin(0)?.id,
        'pluginBypass': m.pluginManager.isSlotBypassed(0),
        'pluginPdc': m.pluginManager.pdcEnabled,
        'slots': slotSnapshots,
        'parameters': snapshot.params,
      };

      return ConfigManager.writeJsonFile(sessionPath, payload);
    } catch (_) {
      return false;
    }
  }

  /// 读取会话快照
  static Map<String, dynamic>? load() {
    try {
      final file = File(sessionPath);
      if (!file.existsSync()) return null;
      final content = file.readAsStringSync();
      return jsonDecode(content) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// 恢复内存镜像（UI 启动初期，引擎未连接前）
  static void restoreMemoryImage(AppModel m, Map<String, dynamic> session) {
    try {
      if (session['activePresetName'] is String) {
        m.activePresetName = session['activePresetName'] as String;
      }
      if (session['channelsMode'] is num) {
        m.channelsMode = (session['channelsMode'] as num).toInt();
      }
      if (session['audioMode'] is String) {
        m.audioMode = AudioModes.normalize(session['audioMode'] as String);
        m.config.audioMode = m.audioMode;
        m.config.modeCategory = AudioModes.categoryForMode(m.audioMode);
        if (m.config.modeCategory == AudioModes.categoryAttachment) {
          m.config.attachmentMode = (m.audioMode == 'vbcallback')
              ? AudioModes.attachVoicemeeterApi
              : AudioModes.attachSysApo;
        } else {
          m.config.pipelineOutput = (m.audioMode == 'asio')
              ? AudioModes.outputAsioClient
              : (m.audioMode == 'vaio' ? AudioModes.outputVaio : AudioModes.outputWasapi);
        }
      }
      if (session['modeCategory'] is String) {
        m.config.modeCategory = session['modeCategory'] as String;
      }
      if (session['attachmentMode'] is String) {
        m.config.attachmentMode = session['attachmentMode'] as String;
      }
      if (session['pipelineInput'] is String) {
        m.config.pipelineInput = session['pipelineInput'] as String;
      }
      if (session['pipelineOutput'] is String) {
        m.config.pipelineOutput = session['pipelineOutput'] as String;
      }
      if (session['pipelineInputDevice'] is String) {
        m.config.pipelineInputDevice = session['pipelineInputDevice'] as String;
      }
      if (session['pipelineOutputDevice'] is String) {
        m.config.pipelineOutputDevice = session['pipelineOutputDevice'] as String;
      }
      if (session['pipelineInputEnabled'] is bool) {
        m.config.pipelineInputEnabled = session['pipelineInputEnabled'] as bool;
      }
      if (session['pipelineOutputEnabled'] is bool) {
        m.config.pipelineOutputEnabled = session['pipelineOutputEnabled'] as bool;
      }
      if (session['asioDriver'] is String) {
        m.config.asioDriver = session['asioDriver'] as String;
      }
      if (session['asioBufSize'] is num) {
        m.config.asioBufSize = (session['asioBufSize'] as num).toInt();
      }
      if (session['asioOutPair'] is num) {
        m.config.asioOutPair = (session['asioOutPair'] as num).toInt();
      }
      if (session['vaioOutputEndpoint'] is String) {
        m.config.vaioOutputEndpoint = session['vaioOutputEndpoint'] as String;
      }
      if (session['apoTargetEndpoint'] is String) {
        m.config.apoTargetEndpoint = session['apoTargetEndpoint'] as String;
      }
      if (session['monitorMirroring'] is bool) {
        m.config.monitorMirroring = session['monitorMirroring'] as bool;
      }
      if (session['source51Mode'] is num) {
        m.source51Mode = (session['source51Mode'] as num).toInt().clamp(0, 1);
      }
      if (session['convIrPath'] is String) {
        m.convIrPath = session['convIrPath'] as String;
      }
      if (session['ddcPath'] is String) {
        m.ddcPath = session['ddcPath'] as String;
        m.parseVdcMetadata(m.ddcPath!);
      }
      if (session['lpCode'] is String) {
        m.lpCode = session['lpCode'] as String;
      }
      if (session['arbmagString'] is String) {
        m.arbmagString = session['arbmagString'] as String;
      }

      // 多插槽恢复
      m.savedPluginSlots.clear();
      if (session['slots'] is List) {
        for (final item in (session['slots'] as List)) {
          if (item is Map) {
            final path = item['path'] as String?;
            if (path != null && path.isNotEmpty) {
              m.savedPluginSlots.add(SavedPluginSlot(
                slot: (item['slot'] as num?)?.toInt() ?? 0,
                path: path,
                id: (item['id'] as String?) ?? '',
                bypass: (item['bypassed'] as bool?) ?? false,
                stage: (item['stage'] as num?)?.toInt() ?? PluginInsertStage.defaultStage,
                channels: (item['channels'] as num?)?.toInt() ?? 0xFF,
              ));
            }
          }
        }
      }
      if (m.savedPluginSlots.isEmpty && session['pluginPath'] is String) {
        m.savedPluginPath = session['pluginPath'] as String;
        m.savedPluginId = (session['pluginId'] as String?) ?? '';
        m.savedPluginBypass = (session['pluginBypass'] as bool?) ?? false;
        m.savedPluginSlots.add(SavedPluginSlot(
          slot: 0,
          path: m.savedPluginPath!,
          id: m.savedPluginId,
          bypass: m.savedPluginBypass,
          stage: PluginInsertStage.defaultStage,
        ));
      }
      if (session['pluginPdc'] is bool) {
        m.savedPluginPdc = session['pluginPdc'] as bool;
      }

      final params = (session['parameters'] as Map<String, dynamic>?) ?? {};
      if (params.isNotEmpty) {
        // PresetLibrary.apply() 末尾会执行 `m.activePresetName = preset.name`。
        // 会话恢复不是「加载某个预设」，所以这里在 apply 之后把名字还原成
        // 会话里存的那个（上面已从 session['activePresetName'] 恢复）。
        // 否则每次启动 activePresetName 都会被覆盖成 '__restored__'，
        // 效果页的预设高亮（比较 m.activePresetName == item.name）永远不命中。
        final restoredPresetName = m.activePresetName;
        final dummyPreset = AuraPreset(
          name: '__restored__',
          createdAt: DateTime.now().toIso8601String(),
          params: params,
        );
        // 静默回填 model 内存字段
        PresetLibrary.apply(m, dummyPreset);
        m.activePresetName = restoredPresetName;
      }

      // 脏态随会话恢复（决策 #3）：即使未保存为文件的自定义态，重启后
      // 仍显示「自定义（未保存）」。apply 上面把指纹锚到了回放后的状态，
      // 这里必须用会话里存的锚点/脏标记覆盖，否则脏态被误清。
      // 旧版（v4 及更早）会话无这两个键 → 保持默认（无锚点、不脏），平滑升级。
      if (session['appliedPresetFingerprint'] is String) {
        m.appliedPresetFingerprint =
            session['appliedPresetFingerprint'] as String;
      }
      if (session['presetDirty'] is bool) {
        m.presetDirty = session['presetDirty'] as bool;
      }
    } catch (_) {}
  }

  /// 清除会话记忆
  static bool clear() {
    try {
      final file = File(sessionPath);
      if (file.existsSync()) file.deleteSync();
      return true;
    } catch (_) {
      return false;
    }
  }
}
