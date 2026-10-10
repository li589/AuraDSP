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
      final payload = {
        'version': 2,
        'savedAt': DateTime.now().toIso8601String(),
        'activePresetName': m.activePresetName,
        'locale': m.locale.languageCode,
        'themeId': m.themeId.name,
        'latencyMode': m.latencyMode,
        'channelsMode': m.channelsMode,
        'convIrPath': m.convIrPath,
        'ddcPath': m.ddcPath,
        'lpCode': m.lpCode,
        'pluginPath': m.pluginManager.activePlugin?.path,
        'pluginId': m.pluginManager.activePlugin?.id,
        'pluginBypass': m.pluginManager.isBypassed,
        'parameters': snapshot.params,
      };

      final content = const JsonEncoder.withIndent('  ').convert(payload);
      File(sessionPath).writeAsStringSync(content);
      return true;
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
      }
      if (session['lpCode'] is String) {
        m.lpCode = session['lpCode'] as String;
      }
      if (session['pluginPath'] is String) {
        m.savedPluginPath = session['pluginPath'] as String;
        m.savedPluginId = (session['pluginId'] as String?) ?? '';
        m.savedPluginBypass = (session['pluginBypass'] as bool?) ?? false;
      }

      final params = (session['parameters'] as Map<String, dynamic>?) ?? {};
      if (params.isEmpty) return;

      final dummyPreset = AuraPreset(
        name: '__restored__',
        createdAt: DateTime.now().toIso8601String(),
        params: params,
      );
      // 静默回填 model 内存字段
      PresetLibrary.apply(m, dummyPreset);
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
