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
// 解析口径：有效值 = 用户值 ?? 默认层值 ?? 代码默认。本模块
// 提供默认层读取、深合并与稀疏差分（用户落盘只写与基线不同
// 的键，2026-11-12 落地，等价性由 config_sparse_save_test 的
// save→reload 回归钉死）。默认层缺失/损坏 → 空层，基线回落
// 代码默认，全链行为与分层前完全一致。

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

  /// JSON 值域深相等：Map 按键集递归比对，List 按序比对，num
  /// 跨 int/double 按值比（Dart num == 本就如此，如 1 == 1.0）。
  static bool jsonDeepEqual(Object? a, Object? b) {
    if (a is Map && b is Map) {
      if (a.length != b.length) return false;
      for (final key in a.keys) {
        if (!b.containsKey(key) || !jsonDeepEqual(a[key], b[key])) {
          return false;
        }
      }
      return true;
    }
    if (a is List && b is List) {
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (!jsonDeepEqual(a[i], b[i])) return false;
      }
      return true;
    }
    return a == b;
  }

  /// 稀疏差分：求最小 overlay，使 deepMergeUnder(baseline,
  /// overlay) 与 [full] 深相等。规则与合并语义严格对偶：
  /// - 与基线深相等的叶子/子树整体省略（重读时由基线供给，
  ///   这正是「未改过的键自动跟随默认层升级」的机制）；
  /// - 两侧同为 Map 时逐键递归，只收有差异的键；
  /// - List/标量/null 任一侧类型不同或值不同 → 整值收录
  ///   （合并对 List 是整体替换，无法部分表达）；
  /// - 仅 full 有的键整值收录；仅基线有的键省略。
  /// [forceKeep] 的顶层键无条件收录（如 version：load 的迁移
  /// 判定读用户原始档，稀疏掉会被误判远古档而重复迁移）。
  ///
  /// 前置不变量：[full] 须是 load 可产生的有效配置（每个 Map
  /// 层的键集 ⊇ 基线同层键集）——AppConfig.toJson 恒全量发键、
  /// load 又以合并为起点，该不变量由构造保证；合并语义无法
  /// 表达「删掉基线的某个键」，此类状态本就不可达。
  static Map<String, dynamic> sparseDiff(
    Map<String, dynamic> baseline,
    Map<String, dynamic> full, {
    Set<String> forceKeep = const {},
  }) {
    final out = <String, dynamic>{};
    full.forEach((key, value) {
      if (forceKeep.contains(key) || !baseline.containsKey(key)) {
        out[key] = value;
        return;
      }
      final baseValue = baseline[key];
      if (value is Map<String, dynamic> &&
          baseValue is Map<String, dynamic>) {
        final sub = sparseDiff(baseValue, value);
        if (sub.isNotEmpty) out[key] = sub;
      } else if (!jsonDeepEqual(baseValue, value)) {
        out[key] = value;
      }
    });
    return out;
  }
}
