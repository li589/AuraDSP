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
        });
      }

      final payload = {
        'version': 3,
        'savedAt': DateTime.now().toIso8601String(),
        'activePresetName': m.activePresetName,
        'locale': m.locale.languageCode,
        'themeId': m.themeId.name,
        'latencyMode': m.latencyMode,
        'channelsMode': m.channelsMode,
        'convIrPath': m.convIrPath,
        'ddcPath': m.ddcPath,
        'lpCode': m.lpCode,
        'pluginPath': m.pluginManager.getSlotPlugin(0)?.path,
        'pluginId': m.pluginManager.getSlotPlugin(0)?.id,
        'pluginBypass': m.pluginManager.isSlotBypassed(0),
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
      if (session['latencyMode'] is num) {
        m.latencyMode = (session['latencyMode'] as num).toInt();
      }
      if (session['channelsMode'] is num) {
        m.channelsMode = (session['channelsMode'] as num).toInt();
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

      final params = (session['parameters'] as Map<String, dynamic>?) ?? {};
      if (params.isEmpty) return;

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
