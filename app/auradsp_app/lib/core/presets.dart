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
import '../engine/debug_log.dart';
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
  ///
  /// 注意：pubspec 按**目录**打包该资产，故清单与目录是两套真相——只往目录
  /// 放文件而不登记，编译仍通过但永不落盘（静默不出现）。两侧一致性由
  /// `test/preset_defaults_contract_test.dart` 门禁钉住。
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

  /// 出厂预设资产清单的只读视图（供一致性门禁比对目录内容）。
  static List<String> get factoryAssetFiles =>
      List.unmodifiable(_factoryAssetFiles);

  /// 当前预设 schema 版本（`snapshot` 写入、`importFromFile` 校验的唯一真源）。
  static const int schemaVersionCurrent = 3;

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

  /// 名称的稳定短哈希（FNV-1a 32 位 → 8 位十六进制），仅用于文件名去碰撞。
  static String _nameHash(String name) {
    var h = 0x811c9dc5;
    for (final c in name.codeUnits) {
      h ^= c;
      h = (h * 0x01000193) & 0xFFFFFFFF;
    }
    return h.toRadixString(16).padLeft(8, '0');
  }

  /// 定位某个预设名对应的落盘文件（不含出厂预设）。
  ///
  /// 文件名来自 [_safeFileName]，而它**会碰撞**（`My Song` 与 `My_Song` 都得到
  /// `my_song.json`）——所以不能只凭文件名判断，必须读回 JSON 里的 name 对账。
  /// 冲突副本的文件名带 [_nameHash] 后缀；另外兼容 v1 落在根目录的历史形态。
  static File? _findUserPresetFile(String name) {
    final sep = Platform.pathSeparator;
    final base = _safeFileName(name);
    final hashed = '${base}_${_nameHash(name)}.json';
    final candidates = <String>[
      '$userDir$sep$base.json',
      '$userDir$sep$hashed',
      '$baseDir$sep$base.json',
      '$baseDir$sep$hashed',
    ];
    for (final p in candidates) {
      final f = File(p);
      if (!f.existsSync()) continue;
      try {
        final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
        if ((j['name'] as String?) == name) return f;
      } catch (e, st) { swallow(e, st); }
    }
    return null;
  }

  /// 同名去重用的可用名称：`Name` → `Name (2)` → `Name (3)` …
  /// 后缀是纯数字，语言无关（不需要 l10n 词条）。
  static String _uniqueUserName(String base) {
    final taken = <String>{};
    for (final p in listAll()) {
      if (!p.isFactory) taken.add(p.name.toLowerCase());
    }
    if (!taken.contains(base.toLowerCase())) return base;
    for (var i = 2; i < 1000; i++) {
      final cand = '$base ($i)';
      if (!taken.contains(cand.toLowerCase())) return cand;
    }
    return '$base (${DateTime.now().millisecondsSinceEpoch})';
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

    // 兼顾历史 v1 存放于根目录的旧预设。
    // 2026-10-31 审查修复：根目录同时住着 config.json / session_state.json /
    // file_paths.json，旧实现把**所有** *.json 当预设 → 生成删不掉的
    // "Unnamed" 幽灵条目，点一下 params 为空 → 全量复写 = 静默恢复出厂。
    // 只接受「有 name + parameters/params」的预设形态。
    try {
      final rDir = Directory(baseDir);
      if (rDir.existsSync()) {
        for (final f in rDir.listSync().whereType<File>()) {
          if (!f.path.toLowerCase().endsWith('.json')) continue;
          try {
            final json = jsonDecode(f.readAsStringSync());
            if (json is! Map<String, dynamic>) continue;
            final name = json['name'];
            final params = json['parameters'] ?? json['params'];
            if (name is! String ||
                name.isEmpty ||
                params is! Map ||
                params.isEmpty) {
              continue; // 非预设文件（配置文件/会话/路径记忆等）
            }
            list.add(AuraPreset.fromJson(json));
          } catch (e, st) { swallow(e, st); }
        }
      }
    } catch (e, st) { swallow(e, st); }

    // 顺序确定性（2026-10-28）：listSync 给的是文件系统序，增删文件后会漂，
    // 预设 chip 的位置随之跳变。出厂在前、用户在后，各自按名称不区分大小写。
    list.sort((a, b) {
      if (a.isFactory != b.isFactory) return a.isFactory ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return list;
  }

  /// 保存为用户预设。
  ///
  /// 落盘名由名称归一化而来，而归一化会碰撞（`My Song` / `My_Song` →
  /// 同一个 `my_song.json`）。故：① 先按**内容对账**找已存在的同名预设，
  /// 命中即原地覆盖；② 没找到但首选文件名已被别的预设占用 → 追加名称短哈希，
  /// 绝不静默覆盖他人数据。
  static bool saveUserPreset(AuraPreset preset) {
    try {
      final existing = _findUserPresetFile(preset.name);
      final String path;
      if (existing != null) {
        path = existing.path;
      } else {
        final base = _safeFileName(preset.name);
        final preferred = '$userDir${Platform.pathSeparator}$base.json';
        path = File(preferred).existsSync()
            ? '$userDir${Platform.pathSeparator}'
                '${base}_${_nameHash(preset.name)}.json'
            : preferred;
      }
      return ConfigManager.writeJsonFile(path, preset.toJson());
    } catch (e, st) {
      swallow(e, st);
      return false;
    }
  }

  /// 删除预设（仅限用户预设，出厂预设禁止删除）
  static bool deletePreset(AuraPreset preset) {
    if (preset.isFactory) return false;
    try {
      final f = _findUserPresetFile(preset.name);
      if (f == null) return false;
      f.deleteSync();
      return true;
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

  /// 从外部文件导入预设。
  ///
  /// 两道闸门（2026-10-28）：
  /// - **版本闸门**：高于 [schemaVersionCurrent] 的文件来自更新版本的应用，
  ///   本版本读不懂它的节 —— 静默「导入了但什么也没发生」比拒绝更糟，直接返回 null；
  /// - **同名不覆盖**：导入是外部来源，覆盖用户已有预设属数据丢失，改名加序号。
  static AuraPreset? importFromFile(String srcPath) {
    try {
      final file = File(srcPath);
      if (!file.existsSync()) return null;
      final content = file.readAsStringSync();
      final json = jsonDecode(content) as Map<String, dynamic>;
      final preset = AuraPreset.fromJson(json);
      if (preset.schemaVersion < 1 ||
          preset.schemaVersion > schemaVersionCurrent) {
        return null;
      }
      // 导入后存入用户预设（出厂同名不受影响：出厂只读，改名只针对用户侧）
      final userPreset = AuraPreset(
        schemaVersion: preset.schemaVersion,
        name: _uniqueUserName(preset.name),
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
      // 会话级参数（sessionOnly，如 routing 的设备端点/ASIO 配置）不入预设：
      // 它们只随 SessionMemory 走（该文件有同名的显式字段持久化），避免
      // 「载入预设 → 用户的输出设备/ASIO 设置被清空并落盘」。
      if (_isSessionOnlySection(section)) continue;
      final secMap = <String, dynamic>{};
      for (final spec in section.specs) {
        if (!spec.isPresetSerializable) continue;
        if (spec.isSessionOnly) continue;
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
      schemaVersion: schemaVersionCurrent,
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
  /// 有意不复写的例外：
  /// - chainOrder（全局路由选择）；
  /// - 会话级参数（`sessionOnly`，全部 routing 设备/ASIO/模式镜像）——整节
  ///   跳过，预设不携带也不复写（2026-10-28：此前该标志无消费方，导致载入
  ///   预设会清空输出设备与 ASIO 缓冲并即时落盘）。
  static void apply(AppModel m, AuraPreset preset, {bool fullRewrite = true}) {
    final p = fullRewrite ? _mergeDefaults(preset.params) : preset.params;

    for (final section in ParamRegistry.sections) {
      if (_isSessionOnlySection(section)) continue;
      // 可视化偏好节（2026-10-31）：只在**用户预设显式携带**时应用。
      // 出厂预设 / 旧版预设的 visualizer 段是生成基线时补进去的出厂值，
      // 让它们覆盖用户已定制的风格/配色/歌词源会导致「载入音效预设 =
      // 视觉风格被重置」，与 theme/locale（只随 config）的口径不一致。
      if (section.name == 'visualizer' &&
          (preset.isFactory || !preset.params.containsKey('visualizer'))) {
        continue;
      }
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
        if (spec.isSessionOnly) continue;
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
    // 应用即归零（2026-10-28）：此前要等下一次防抖 evaluatePresetDirty
    // 才清，界面上「自定义（未保存）」徽标会多挂一个防抖窗口。
    m.presetDirty = false;
  }

  /// 整节都是会话级参数（`sessionOnly`）→ 该节与预设系统完全无关。
  static bool _isSessionOnlySection(ParamSection s) =>
      s.specs.isNotEmpty && s.specs.every((x) => x.isSessionOnly);

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
    if (raw == null || raw.isEmpty) {
      // 降级留痕（2026-10-28）：资产未预载/缺失时 _mergeDefaults 会原样返回，
      // 语义从「全部复写」悄悄退回「缺节不碰」。此前无任何留痕，排障只能靠猜。
      if (!_defaultsMissingReported) {
        _defaultsMissingReported = true;
        dbgLog('[PresetLibrary] defaults.json 未预载：fullRewrite 退化为合并且不复位缺失键');
      }
      return {};
    }
    try {
      final obj = jsonDecode(raw) as Map<String, dynamic>;
      final params = obj['params'];
      if (params is Map<String, dynamic>) return params;
      if (params is Map) return Map<String, dynamic>.from(params);
    } catch (e, st) { swallow(e, st); }
    return {};
  }

  static bool _defaultsMissingReported = false;

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
