/*
 * presets.dart — AuraDSP 预设系统 v2
 *
 * 规范：统一 Schema v2，区分出厂预设 (只读) 与用户预设。
 * 覆盖全部 8 大效果卡片完整参数（包含交互式 EQ 曲线、低音谐波、电子管饱和度等）。
 * 存储路径：%APPDATA%/AuraDSP/presets/
 */

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;

import 'config.dart';
import 'param_schema.dart';
import 'state.dart';

import 'error_sink.dart';
class AuraPreset {
  final int schemaVersion;
  final String name;
  final String category;
  final String description;
  final String author;
  final String createdAt;
  final bool isFactory;
  final Map<String, dynamic> params;

  AuraPreset({
    this.schemaVersion = 2,
    required this.name,
    this.category = 'General',
    this.description = '',
    this.author = 'AuraDSP',
    required this.createdAt,
    this.isFactory = false,
    required this.params,
  });

  factory AuraPreset.fromJson(Map<String, dynamic> json) {
    return AuraPreset(
      schemaVersion: (json['schemaVersion'] as num?)?.toInt() ?? 1,
      name: (json['name'] as String?) ?? 'Unnamed',
      category: (json['category'] as String?) ?? 'General',
      description: (json['description'] as String?) ?? '',
      author: (json['author'] as String?) ?? 'User',
      createdAt: (json['createdAt'] as String?) ?? DateTime.now().toIso8601String(),
      isFactory: (json['isFactory'] as bool?) ?? false,
      params: (json['parameters'] as Map<String, dynamic>?) ??
          (json['params'] as Map<String, dynamic>?) ??
          {},
    );
  }

  Map<String, dynamic> toJson() => {
        'schemaVersion': schemaVersion,
        'name': name,
        'category': category,
        'description': description,
        'author': author,
        'createdAt': createdAt,
        'isFactory': isFactory,
        'parameters': params,
      };
}

abstract final class PresetLibrary {
  static String get baseDir =>
      '${ConfigManager.baseDir}${Platform.pathSeparator}presets';
  static String get factoryDir =>
      '$baseDir${Platform.pathSeparator}factory';
  static String get userDir =>
      '$baseDir${Platform.pathSeparator}user';

  /// 出厂预设资产清单（assets/presets/factory/）。代码中不存任何预设内容，
  /// 只存文件名索引；内容一律来自 JSON 资产（2026-10-16 决策）。
  static const List<String> _factoryAssetFiles = [
    'Pop Vocal Clarity.json',
    'Rock Bass Impact.json',
    'Symphonic Concert Hall.json',
    'Vintage Vinyl Tube.json',
    'V-Shape Smile Hi-Fi.json',
    'Studio Flat Monitor.json',
  ];

  static final Map<String, String> _factoryAssetCache = {};
  static String? _defaultsJson;

  /// 预载出厂预设与默认基线资产（异步）。rootBundle 仅提供异步 API，
  /// 而 ensureInitialized/apply 在同步路径上——故 main 启动时预载一次
  /// 进内存缓存，同步路径直接消费。未预载时 ensureInitialized 跳过写盘、
  /// apply 退化为「原样应用」（不合并基线）。
  static Future<void> preloadFactoryAssets() async {
    for (final f in _factoryAssetFiles) {
      try {
        _factoryAssetCache[f] =
            await rootBundle.loadString('assets/presets/factory/$f');
      } catch (e, st) { swallow(e, st); }
    }
    try {
      _defaultsJson = await rootBundle.loadString('assets/presets/defaults.json');
    } catch (e, st) { swallow(e, st); }
  }

  /// 确保出厂预设目录及文件已初始化。
  /// 版本化写盘：磁盘文件与资产内容**不一致即重写**——修复旧版
  /// 「只在文件不存在时写、出厂预设永远无法热更新」缺陷。
  static void ensureInitialized() {
    try {
      final fDir = Directory(factoryDir);
      if (!fDir.existsSync()) fDir.createSync(recursive: true);
      final uDir = Directory(userDir);
      if (!uDir.existsSync()) uDir.createSync(recursive: true);

      if (_factoryAssetCache.isEmpty) {
        for (final name in _factoryAssetFiles) {
          final diskFile = File('assets/presets/factory/$name');
          if (diskFile.existsSync()) {
            _factoryAssetCache[name] = diskFile.readAsStringSync();
          }
        }
      }
      if (_factoryAssetCache.isEmpty) return; // 资产未预载
      for (final name in _factoryAssetFiles) {
        final content = _factoryAssetCache[name];
        if (content == null) continue;
        final f = File(
            '$factoryDir${Platform.pathSeparator}${_safeFileName(name)}');
        if (f.existsSync()) {
          try {
            if (f.readAsStringSync() == content) continue; // 一致，跳过
          } catch (e, st) { swallow(e, st); }
        }
        f.writeAsStringSync(content);
      }
    } catch (e, st) { swallow(e, st); }
  }

  static String _safeFileName(String name) {
    return name
        .replaceAll(RegExp(r'[\\/:*?"<>|\s]'), '_')
        .toLowerCase();
  }

  /// 获取所有预设（出厂预设排在前，用户预设排在后）
  static List<AuraPreset> listAll() {
    ensureInitialized();
    final list = <AuraPreset>[];

    // 读取出厂预设
    try {
      final fDir = Directory(factoryDir);
      if (fDir.existsSync()) {
        for (final f in fDir.listSync().whereType<File>()) {
          if (f.path.toLowerCase().endsWith('.json')) {
            try {
              final json = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
              list.add(AuraPreset.fromJson(json));
            } catch (e, st) { swallow(e, st); }
          }
        }
      }
    } catch (e, st) { swallow(e, st); }

    // 读取用户预设
    try {
      final uDir = Directory(userDir);
      if (uDir.existsSync()) {
        for (final f in uDir.listSync().whereType<File>()) {
          if (f.path.toLowerCase().endsWith('.json')) {
            try {
              final json = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
              list.add(AuraPreset.fromJson(json));
            } catch (e, st) { swallow(e, st); }
          }
        }
      }
    } catch (e, st) { swallow(e, st); }

    // 兼顾历史 v1 存放于根目录的旧预设
    try {
      final rDir = Directory(baseDir);
      if (rDir.existsSync()) {
        for (final f in rDir.listSync().whereType<File>()) {
          if (f.path.toLowerCase().endsWith('.json')) {
            try {
              final json = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
              list.add(AuraPreset.fromJson(json));
            } catch (e, st) { swallow(e, st); }
          }
        }
      }
    } catch (e, st) { swallow(e, st); }

    return list;
  }

  /// 保存为用户预设
  static bool saveUserPreset(AuraPreset preset) {
    try {
      final filename = '${_safeFileName(preset.name)}.json';
      return ConfigManager.writeJsonFile(
          '$userDir${Platform.pathSeparator}$filename', preset.toJson());
    } catch (e, st) {
      swallow(e, st);
      return false;
    }
  }

  /// 删除预设（仅限用户预设，出厂预设禁止删除）
  static bool deletePreset(AuraPreset preset) {
    if (preset.isFactory) return false;
    try {
      final filename = '${_safeFileName(preset.name)}.json';
      final file = File('$userDir${Platform.pathSeparator}$filename');
      if (file.existsSync()) {
        file.deleteSync();
        return true;
      }
      // 检查历史目录
      final legacy = File('$baseDir${Platform.pathSeparator}$filename');
      if (legacy.existsSync()) {
        legacy.deleteSync();
        return true;
      }
      return false;
    } catch (e, st) {
      swallow(e, st);
      return false;
    }
  }

  /// 导出预设为文件
  static bool exportToFile(AuraPreset preset, String destPath) {
    try {
      return ConfigManager.writeJsonFile(destPath, preset.toJson());
    } catch (e, st) {
      swallow(e, st);
      return false;
    }
  }

  /// 从外部文件导入预设
  static AuraPreset? importFromFile(String srcPath) {
    try {
      final file = File(srcPath);
      if (!file.existsSync()) return null;
      final content = file.readAsStringSync();
      final json = jsonDecode(content) as Map<String, dynamic>;
      final preset = AuraPreset.fromJson(json);
      // 导入后存入用户预设
      final userPreset = AuraPreset(
        schemaVersion: preset.schemaVersion,
        name: preset.name,
        category: preset.category,
        description: preset.description,
        author: preset.author.isEmpty ? 'Imported' : preset.author,
        createdAt: DateTime.now().toIso8601String(),
        isFactory: false,
        params: preset.params,
      );
      saveUserPreset(userPreset);
      return userPreset;
    } catch (e, st) {
      swallow(e, st);
      return null;
    }
  }

  /* ---- 全量快照与应用 ---- */

  static AuraPreset snapshot(
    AppModel m, {
    required String name,
    String category = 'Custom',
    String description = '',
  }) {
    final paramsMap = <String, dynamic>{};

    for (final section in ParamRegistry.sections) {
      final secMap = <String, dynamic>{};
      for (final spec in section.specs) {
        if (!spec.isPresetSerializable) continue;
        final val = spec.read(m);
        if (spec.subSection != null) {
          final subMap = secMap.putIfAbsent(
              spec.subSection!, () => <String, dynamic>{});
          subMap[spec.key] = val is List ? List.of(val) : val;
        } else {
          secMap[spec.key] = val is List ? List.of(val) : val;
        }
      }
      if (section.customSnapshot != null) {
        section.customSnapshot!(m, secMap);
      }
      if (secMap.isNotEmpty) {
        paramsMap[section.name] = secMap;
      }
    }

    if (m.graphOrder != null) {
      paramsMap['chainOrder'] = m.graphOrder;
    }

    return AuraPreset(
      schemaVersion: 3,
      name: name,
      category: category,
      description: description,
      author: 'User',
      createdAt: DateTime.now().toIso8601String(),
      isFactory: false,
      params: paramsMap,
    );
  }

  /// 应用预设。2026-10-16 语义定版：
  /// - fullRewrite=true（全局预设，默认）：**全部复写**——预设未携带的
  ///   节/键一律取默认基线值，取代旧「缺节不碰」合并语义；
  /// - fullRewrite=false（效果器自有预设）：只应用预设实际携带的节，
  ///   每节内部同样以基线补齐缺失键（只覆盖自己的所有配置）。
  /// 有意不复写的例外：chainOrder（全局路由选择）。
  static void apply(AppModel m, AuraPreset preset, {bool fullRewrite = true}) {
    final p = fullRewrite ? _mergeDefaults(preset.params) : preset.params;

    for (final section in ParamRegistry.sections) {
      final secData = (p[section.name] as Map<String, dynamic>?) ?? {};
      if (secData.isEmpty) continue;

      if (section.customApplyOnly) {
        if (section.postApply != null) {
          section.postApply!(m, secData, fullRewrite);
        }
        continue;
      }

      // 1. 将 specs 按 order 分组：常规参数 (order < 100) 先设，总开关 (order >= 100) 后开
      final preSpecs = <ParamSpec>[];
      final postSpecs = <ParamSpec>[];
      for (final spec in section.specs) {
        if (!spec.isPresetSerializable) continue;
        if (spec.isDerivation) continue;
        if (spec.order >= 100) {
          postSpecs.add(spec);
        } else {
          preSpecs.add(spec);
        }
      }
      preSpecs.sort((a, b) => a.order.compareTo(b.order));
      postSpecs.sort((a, b) => a.order.compareTo(b.order));

      // 2. 依次应用常规参数
      for (final spec in preSpecs) {
        _applySpec(m, spec, secData);
      }

      // 3. 节级拦截钩子 (如 EQ 曲线重采样、混响预设与自定义参数互斥保护)
      if (section.postApply != null) {
        section.postApply!(m, secData, fullRewrite);
      }

      // 4. 依次应用开关参数 (确保模块在所有系数就绪后再激活，防止切预设时爆音)
      for (final spec in postSpecs) {
        _applySpec(m, spec, secData);
      }
    }

    // 路由链顺序 (顶层非标属性)
    if (p['chainOrder'] is String) {
      m.setGraphOrder(p['chainOrder'] as String);
    }

    m.activePresetName = preset.name;
    // 脏跟踪锚点（2026-10-16 决策 #3）：应用成功后把当前状态记为
    // 「不脏」的基准；之后任意参数偏离都会使 fingerprintOf 失配
    // → 进入自定义/未保存态。会话恢复路径（restoreMemoryImage）随后
    // 会用会话里存的锚点覆盖本值，见 session_memory.dart。
    m.appliedPresetFingerprint = fingerprintOf(m);
  }

  static void _applySpec(
      AppModel m, ParamSpec spec, Map<String, dynamic> secData) {
    dynamic raw;
    if (spec.subSection != null) {
      final sub = secData[spec.subSection!] as Map<String, dynamic>?;
      raw = sub?[spec.key];
    } else {
      raw = secData[spec.key];
    }
    if (raw != null) {
      spec.write(m, spec.cast(raw));
    }
  }

  /* ---- 脏跟踪指纹（2026-10-16 决策 #3）---- */

  /// 模型当前参数状态的规范化指纹：snapshot params 的 JSON 编码。
  /// snapshot 构建顺序确定 → 同一状态两次编码逐字节一致；
  /// 与 [AppModel.appliedPresetFingerprint] 失配即「偏离预设」。
  /// 开销：一次完整 snapshot（22 节），仅在 apply 与防抖保存回调中调用，
  /// 不在 setter 热路径上（用户快速频繁改动时只花防抖间隔一次的开销）。
  static String fingerprintOf(AppModel m) =>
      jsonEncode(snapshot(m, name: '__fingerprint__').params);

  /* ---- 出厂预设内容外置 + 默认基线（2026-10-16）----
   * _builtInPresets 已删除：预设内容全部移至 assets/presets/（JSON 资产）。
   * 出厂 JSON 经 ensureInitialized 版本化落盘，listAll 从磁盘读回。
   * 默认基线（apply 全量复写的数据源）：assets/presets/defaults.json。
   * 生成/再生成方式：test/zz_gen_factory_presets.dart（一次性工具）。 */

  /// 全量复写合并：基线为底、预设键优先（深合并，逐键）。
  /// 基线不可得（资产未预载）时原样返回，退化为旧语义。
  static Map<String, dynamic> _mergeDefaults(Map<String, dynamic> src) {
    final base = _defaultsParams();
    if (base.isEmpty) return src;
    return _deepMergeMaps(base, src);
  }

  static Map<String, dynamic> _defaultsParams() {
    final raw = _defaultsJson;
    if (raw == null || raw.isEmpty) return {};
    try {
      final obj = jsonDecode(raw) as Map<String, dynamic>;
      final params = obj['params'];
      if (params is Map<String, dynamic>) return params;
      if (params is Map) return Map<String, dynamic>.from(params);
    } catch (e, st) { swallow(e, st); }
    return {};
  }

  static Map<String, dynamic> _deepMergeMaps(
      Map<String, dynamic> base, Map<String, dynamic> over) {
    final out = Map<String, dynamic>.of(base);
    over.forEach((k, v) {
      final b = out[k];
      if (v is Map && b is Map) {
        out[k] = _deepMergeMaps(
            Map<String, dynamic>.from(b), Map<String, dynamic>.from(v));
      } else {
        out[k] = v;
      }
    });
    return out;
  }
}
