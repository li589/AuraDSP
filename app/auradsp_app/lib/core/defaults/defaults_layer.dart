// defaults_layer.dart — 配置/预设分层分发的默认层（资源计划
// Part D / P2.5）。
//
// 分发模型：安装目录放「默认的一堆配置信息、预设信息」，用户
// 的一切内容放用户配置文件夹。默认层实体 = <exeDir>/defaults/
//   config.default.json   代码默认值的导出（打包期由 App 自身
//                         代码生成，见 test/defaults_emit_test.dart，
//                         代码是唯一真相、生成物不入库）
//   presets/*.json        出厂预设分发面（与 Flutter 资产同源）
//   manifest.json         {version, defaultsVersion, files}
//
// 解析口径：有效值 = 用户值 ?? 默认层值 ?? 代码默认。本模块只
// 提供默认层读取与深合并；用户落盘仍为全量（稀疏落盘为后续步
// 骤，需 save→reload 等价性回归后再动）。默认层缺失/损坏 → 空
// 层，全链行为与分层前完全一致。

import 'dart:convert';
import 'dart:io';

import '../../platform/platform_profile.dart';
import '../error_sink.dart';

abstract final class DefaultsLayer {
  static bool _loaded = false;
  static Map<String, dynamic> _configDefaults = const {};
  static Map<String, String> _presetFiles = const {};
  static bool _presetsPresent = false;
  static int defaultsVersion = 0;
  static String appVersion = '';

  static String get dir {
    final sep = Platform.pathSeparator;
    return '${PlatformProfile.executableDir}${sep}defaults';
  }

  static void _ensureLoaded() {
    if (_loaded) return;
    _loaded = true;
    try {
      final sep = Platform.pathSeparator;
      final manifestFile = File('$dir${sep}manifest.json');
      if (manifestFile.existsSync()) {
        final m = jsonDecode(manifestFile.readAsStringSync());
        if (m is Map) {
          defaultsVersion = (m['defaultsVersion'] as num?)?.toInt() ?? 0;
          appVersion = m['version']?.toString() ?? '';
        }
      }
      final cfgFile = File('$dir${sep}config.default.json');
      if (cfgFile.existsSync()) {
        final decoded = jsonDecode(cfgFile.readAsStringSync());
        if (decoded is Map<String, dynamic>) _configDefaults = decoded;
      }
      final presetsDir = Directory('$dir${sep}presets');
      _presetsPresent = presetsDir.existsSync();
      if (_presetsPresent) {
        final out = <String, String>{};
        for (final e in presetsDir.listSync().whereType<File>()) {
          if (!e.path.toLowerCase().endsWith('.json')) continue;
          out[e.uri.pathSegments.last] = e.readAsStringSync();
        }
        _presetFiles = out;
      }
    } catch (e, st) {
      swallow(e, st);
      _configDefaults = const {};
      _presetFiles = const {};
      _presetsPresent = false;
    }
  }

  /// 默认层配置（键集与 AppConfig.toJson 同构）；无默认层为空。
  static Map<String, dynamic> configDefaults() {
    _ensureLoaded();
    return _configDefaults;
  }

  /// 默认层预设：文件名 → 内容（与出厂资产同为 JSON 文本）。
  static Map<String, String> presetFiles() {
    _ensureLoaded();
    return _presetFiles;
  }

  /// 默认层 presets 目录是否存在（对账删除的启用门：不存在时
  /// factory 目录可能含开发/历史内容，不做删除对账）。
  static bool get presetsPresent {
    _ensureLoaded();
    return _presetsPresent;
  }

  static bool get isEmpty {
    _ensureLoaded();
    return _configDefaults.isEmpty && _presetFiles.isEmpty;
  }

  /// 深合并：overlay 的叶子覆盖 base；两侧同为 Map 时递归合并；
  /// 列表与标量整体替换。返回新 Map，不修改入参。
  static Map<String, dynamic> deepMergeUnder(
    Map<String, dynamic> base,
    Map<String, dynamic> overlay,
  ) {
    final out = <String, dynamic>{...base};
    overlay.forEach((key, value) {
      final baseValue = out[key];
      if (value is Map<String, dynamic> && baseValue is Map<String, dynamic>) {
        out[key] = deepMergeUnder(baseValue, value);
      } else {
        out[key] = value;
      }
    });
    return out;
  }
}
