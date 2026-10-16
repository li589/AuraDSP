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
import 'state.dart';

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
      } catch (_) {}
    }
    try {
      _defaultsJson = await rootBundle.loadString('assets/presets/defaults.json');
    } catch (_) {}
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
          } catch (_) {}
        }
        f.writeAsStringSync(content);
      }
    } catch (_) {}
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
            } catch (_) {}
          }
        }
      }
    } catch (_) {}

    // 读取用户预设
    try {
      final uDir = Directory(userDir);
      if (uDir.existsSync()) {
        for (final f in uDir.listSync().whereType<File>()) {
          if (f.path.toLowerCase().endsWith('.json')) {
            try {
              final json = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
              list.add(AuraPreset.fromJson(json));
            } catch (_) {}
          }
        }
      }
    } catch (_) {}

    // 兼顾历史 v1 存放于根目录的旧预设
    try {
      final rDir = Directory(baseDir);
      if (rDir.existsSync()) {
        for (final f in rDir.listSync().whereType<File>()) {
          if (f.path.toLowerCase().endsWith('.json')) {
            try {
              final json = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
              list.add(AuraPreset.fromJson(json));
            } catch (_) {}
          }
        }
      }
    } catch (_) {}

    return list;
  }

  /// 保存为用户预设
  static bool saveUserPreset(AuraPreset preset) {
    try {
      final filename = '${_safeFileName(preset.name)}.json';
      return ConfigManager.writeJsonFile(
          '$userDir${Platform.pathSeparator}$filename', preset.toJson());
    } catch (_) {
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
    } catch (_) {
      return false;
    }
  }

  /// 导出预设为文件
  static bool exportToFile(AuraPreset preset, String destPath) {
    try {
      return ConfigManager.writeJsonFile(destPath, preset.toJson());
    } catch (_) {
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
    } catch (_) {
      return null;
    }
  }

  /* ---- 全量快照与应用 ---- */

  /// 脚本全文指纹（FNV-1a 32 位）：预设/会话只存 hash 不存全文，
  /// apply 时校验编辑器代码是否与存档时一致。空代码 → ''。
  static String _lpCodeHash(String? code) {
    if (code == null || code.isEmpty) return '';
    var h = 0x811C9DC5;
    for (var i = 0; i < code.length; i++) {
      h ^= code.codeUnitAt(i);
      h = (h * 0x01000193) & 0xFFFFFFFF;
    }
    return h.toRadixString(16).padLeft(8, '0');
  }

  static AuraPreset snapshot(
    AppModel m, {
    required String name,
    String category = 'Custom',
    String description = '',
  }) {
    return AuraPreset(
      schemaVersion: 3,
      name: name,
      category: category,
      description: description,
      author: 'User',
      createdAt: DateTime.now().toIso8601String(),
      isFactory: false,
      params: {        // 输入门控（钉死首位）
        'input': {
          'gain': m.inputGain,
          'balanceL': m.inputBalanceL,
          'balanceR': m.inputBalanceR,
        },
        // 低音增强
        'bass': {
          'enable': m.bassOn,
          'intensity': m.bassIntensity,
          'mode': m.bassMode,
          'cutoff': m.bassCutoff,
          'harmonics': m.bassHarmonics,
          'harmonicBlend': m.bassHarmonicBlend,
          'subFloor': m.bassSubFloor,
          'gain': m.bassGain,
          'autoGain': m.bassAutoGain,
          'outputGain': m.bassOutputGain,
        },
        // 空间混响
        'reverb': {
          'enable': m.isSpatialReverbOn,
          'preset': m.reverbPreset,
          'decay': m.fvDecay,
          'damp': m.fvDamp,
          'wet': m.fvWet,
          'dry': m.fvDry,
          'roomSize': m.fvRoomSize,
          'stereoWidth': m.fvWidth,
          'autoGain': m.reverbAutoGain,
          'outputGain': m.reverbOutputGain,
        },
        // 电子管模拟器
        'tube': {
          'enable': m.tubeOn,
          'gain': m.tubeGain,
          'style': m.tubeStyle,
          'compensation': m.tubeCompensation,
          'mix': m.tubeMix,
          'autoGain': m.tubeAutoGain,
          'outputGain': m.tubeOutputGain,
        },
        // 多段图形均衡器
        // 注意：快照必须深拷贝列表。直接存 m.eqFrequencies 这类活引用，
        // 后续任何一次 setEqBandGain/setEqBandQ 都会把“快照”一起改掉，
        // 快照就不再是快照（已用回归测试钉住）。
        'eq': {
          'enable': m.eqOn,
          'bandsCount': m.eqBandsCount,
          'frequencies': List<double>.of(m.eqFrequencies),
          'gains': List<double>.of(m.eqGains),
          'qs': List<double>.of(m.eqQs),
          'q': m.eqQ,
          'filter': m.eqFilter,
          'interp': m.eqInterp,
          'presetName': m.eqPresetName,
          'bypass': m.eqBypass,
          'autoGain': m.eqAutoGain,
          'outputGain': m.eqOutputGain,
        },
        // 立体声展宽
        'stereo': {
          'on': m.stereoOn,
          'mix': m.stereoMix,
          'bandUsed': m.stereoBandUsed,
          'bands': List<double>.of(m.stereoBands),
        },
        // 低频搁架
        'shelf': {
          'enable': m.shelfOn,
          'freq': m.shelfFreq,
          'gain': m.shelfGain,
        },
        // 低频单声道化（链头）
        'bassmono': {
          'enable': m.bassmonoOn,
          'freq': m.bassmonoFreq,
        },
        // Haas 差分环绕（stereo 后 / reverb 前）
        'haas': {
          'enable': m.haasOn,
          'delay': m.haasDelayMs,
          'mix': m.haasMix,
          'side': m.haasSide,
        },
        // 激励器（Haas 后 / reverb 前）
        'exciter': {
          'enable': m.exciterOn,
          'amount': m.exciterAmount,
          'hifreq': m.exciterHifreq,
        },
        // 噪声门（链头）+ Deesser
        'gate': {
          'enable': m.gateOn,
          'threshold': m.gateThreshold,
          'attack': m.gateAttackMs,
          'release': m.gateReleaseMs,
          'autoGain': m.gateAutoGain,
        },
        'deesser': {
          'enable': m.deesserOn,
          'freq': m.deesserFreq,
          'amount': m.deesserAmount,
        },
        // 全参数动态EQ（3 段；参数先行，enable 最后——apply 侧同序）
        'dyneq': {
          'enable': m.dyneqOn,
          'attack': m.dyneqAttackMs,
          'release': m.dyneqReleaseMs,
          'low': {
            'enable': m.dyneqLowOn,
            'freq': m.dyneqLowFreq,
            'q': m.dyneqLowQ,
            'gain': m.dyneqLowGain,
            'range': m.dyneqLowRange,
            'threshold': m.dyneqLowThreshold,
          },
          'mid': {
            'enable': m.dyneqMidOn,
            'freq': m.dyneqMidFreq,
            'q': m.dyneqMidQ,
            'gain': m.dyneqMidGain,
            'range': m.dyneqMidRange,
            'threshold': m.dyneqMidThreshold,
          },
          'high': {
            'enable': m.dyneqHighOn,
            'freq': m.dyneqHighFreq,
            'q': m.dyneqHighQ,
            'gain': m.dyneqHighGain,
            'range': m.dyneqHighRange,
            'threshold': m.dyneqHighThreshold,
          },
        },
        // 响度补偿（Stage 3 后 / 安全钳位前）
        'loudness': {
          'enable': m.loudnessOn,
          'amount': m.loudnessAmount,
        },
        // 独立滤波器（gate 后 / bassmono 前）
        'filter': {
          'enable': m.filterOn,
          'type': m.filterType,
          'freq': m.filterFreq,
          'q': m.filterQ,
        },
        // 脉冲卷积与校正
        'convolver': {
          'enable': m.convEnabled && m.convReady,
          'mix': m.convMix,
        },
        'ddc': {
          'enable': m.ddcOn,
        },
        // 动态压限器
        'comp': {
          'enable': m.compOn,
          'timeconstant': m.compTimeconstant,
          'granularity': m.compGranularity,
          'tfresolution': m.compTfresolution,
          'autoGain': m.compAutoGain,
          'outputGain': m.compOutputGain,
        },
        // 任意响应 EQ（ArbMag）
        'arbmag': {
          'enable': m.arbmagOn && m.arbmagReady,
          'string': m.arbmagString,
          'autoGain': m.arbmagAutoGain,
          'outputGain': m.arbmagOutputGain,
        },
        // 交叉反馈与输出限幅
        'crossfeed': {
          'enable': m.xfeedOn,
          'mode': m.xfeedMode,
          'fcut': m.xfeedFcut,
          'feed': m.xfeedFeed,
        },
        // 脚本（v2：只存使能与滑块；全文不在预设里，走脚本库/会话引用；
        // codeHash 供 apply 校验当前编辑器代码是否与存档时一致）
        'liveprog': {
          'enabled': m.lpEnabled,
          'params': List<double>.of(m.lpParams),
          'codeHash': _lpCodeHash(m.lpCode),
        },
        'post': {
          'gain': m.postGain,
          'limiterEnable': m.limiterOn,
        },
        // 处理链顺序
        if (m.graphOrder != null) 'chainOrder': m.graphOrder,
        // 音频路由与设备记忆（接入预设系统）
        'routing': {
          'modeCategory': m.config.modeCategory,
          'attachmentMode': m.config.attachmentMode,
          'pipelineInput': m.config.pipelineInput,
          'pipelineOutput': m.config.pipelineOutput,
          'pipelineInputDevice': m.config.pipelineInputDevice,
          'pipelineOutputDevice': m.config.pipelineOutputDevice,
          'pipelineInputEnabled': m.config.pipelineInputEnabled,
          'pipelineOutputEnabled': m.config.pipelineOutputEnabled,
          'asioDriver': m.config.asioDriver,
          'asioBufSize': m.config.asioBufSize,
          'asioOutPair': m.config.asioOutPair,
          'vaioOutputEndpoint': m.config.vaioOutputEndpoint,
          'apoTargetEndpoint': m.config.apoTargetEndpoint,
          'monitorMirroring': m.config.monitorMirroring,
        },
      },
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

    // 0. 输入门控
    final input = (p['input'] as Map<String, dynamic>?) ?? {};
    if (input.isNotEmpty) {
      if (input['gain'] != null) {
        m.setInputGain((input['gain'] as num).toDouble());
      }
      if (input['balanceL'] != null) {
        m.setInputBalanceL((input['balanceL'] as num).toDouble());
      }
      if (input['balanceR'] != null) {
        m.setInputBalanceR((input['balanceR'] as num).toDouble());
      }
    }

    // 1. 低音增强
    final bass = (p['bass'] as Map<String, dynamic>?) ?? {};
    if (bass.isNotEmpty) {
      if (bass['intensity'] != null) {
        m.setBassIntensity((bass['intensity'] as num).toDouble());
      }
      if (bass['mode'] != null) {
        m.setBassMode((bass['mode'] as num).toInt());
      }
      if (bass['cutoff'] != null) {
        m.setBassCutoff((bass['cutoff'] as num).toDouble());
      }
      if (bass['harmonics'] != null) {
        m.setBassHarmonics((bass['harmonics'] as num).toDouble());
      }
      if (bass['harmonicBlend'] != null) {
        m.setBassHarmonicBlend((bass['harmonicBlend'] as num).toDouble());
      }
      if (bass['subFloor'] != null) {
        m.setBassSubFloor((bass['subFloor'] as num).toDouble());
      }
      if (bass['autoGain'] != null) {
        m.setBassAutoGain(bass['autoGain'] as bool);
      }
      if (bass['outputGain'] != null) {
        m.setBassOutputGain((bass['outputGain'] as num).toDouble());
      }
      if (bass['enable'] != null) {
        m.setInt('bass.enable', (bass['enable'] as bool) ? 1 : 0);
      }
    }

    // 2. 空间混响
    final rev = (p['reverb'] as Map<String, dynamic>?) ?? {};
    if (rev.isNotEmpty) {
      final pr = (rev['preset'] as num?)?.toInt() ?? -1;
      if (pr >= 0) {
        m.setReverbPreset(pr);
      } else {
        // 仅在预设显式携带该键时才写；缺键 = 不碰用户现值。
        // 史：旧代码用 ?? 硬编码兜底，「关混响」的出厂预设
        // （reverb 节只有 enable+preset=-1）也会把用户自调的
        // decay/wet/roomSize 等 6 个参数抹成默认值。
        if (rev['decay'] != null) {
          m.setReverbCustomParam('decay', (rev['decay'] as num).toDouble());
        }
        if (rev['damp'] != null) {
          m.setReverbCustomParam('damp', (rev['damp'] as num).toDouble());
        }
        if (rev['wet'] != null) {
          m.setReverbCustomParam('wet', (rev['wet'] as num).toDouble());
        }
        if (rev['dry'] != null) {
          m.setReverbCustomParam('dry', (rev['dry'] as num).toDouble());
        }
        if (rev['roomSize'] != null) {
          m.setReverbCustomParam('roomSize', (rev['roomSize'] as num).toDouble());
        }
        if (rev['stereoWidth'] != null) {
          m.setReverbCustomParam('width', (rev['stereoWidth'] as num).toDouble());
        }
      }
      if (rev['autoGain'] != null) {
        m.setReverbAutoGain(rev['autoGain'] as bool);
      }
      if (rev['outputGain'] != null) {
        m.setReverbOutputGain((rev['outputGain'] as num).toDouble());
      }
      if (rev['enable'] != null) {
        m.setSpatialReverbEnabled(rev['enable'] as bool);
      }
    }

    // 3. 电子管模拟器
    final tube = (p['tube'] as Map<String, dynamic>?) ?? {};
    if (tube.isNotEmpty) {
      if (tube['gain'] != null) {
        m.setTubeGain((tube['gain'] as num).toDouble());
      }
      if (tube['style'] != null) {
        m.setTubeStyle((tube['style'] as num).toInt());
      }
      // 注：老预设里的 tube.oversampling 已废弃（引擎无此参数），读到直接忽略。
      if (tube['compensation'] != null) {
        m.setTubeCompensation((tube['compensation'] as num).toDouble());
      }
      if (tube['mix'] != null) {
        m.setTubeMix((tube['mix'] as num).toDouble());
      }
      if (tube['autoGain'] != null) {
        m.setTubeAutoGain(tube['autoGain'] as bool);
      }
      if (tube['outputGain'] != null) {
        m.setTubeOutputGain((tube['outputGain'] as num).toDouble());
      }
      if (tube['enable'] != null) {
        m.setInt('tube.enable', (tube['enable'] as bool) ? 1 : 0);
      }
    }

    // 4. 多段图形均衡器
    final eq = (p['eq'] as Map<String, dynamic>?) ?? {};
    if (eq.isNotEmpty) {
      if (eq['bandsCount'] != null) {
        m.setEqBandsCount((eq['bandsCount'] as num).toInt());
      }
      // 新格式按频点恢复每点 Q；旧格式只有标量 q，按全频带填充。
      final presetFreqs = (eq['frequencies'] as List?)
          ?.map((e) => (e as num).toDouble())
          .toList();
      if (eq['qs'] is List) {
        final qs =
            (eq['qs'] as List).map((e) => (e as num).toDouble()).toList();
        m.applyEqQs(presetFreqs, qs);
      } else if (eq['q'] != null) {
        m.fillEqQ((eq['q'] as num).toDouble());
      }
      if (eq['filter'] != null) {
        m.setEqFilter((eq['filter'] as num).toInt());
      }
      if (eq['interp'] != null) {
        m.setEqInterp((eq['interp'] as num).toInt());
      }
      if (eq['gains'] is List) {
        final list = (eq['gains'] as List).map((e) => (e as num).toDouble()).toList();
        /* C4：snapshot 写了 'frequencies'，apply 却一直只按 bandsCount 重建网格
         * 再按下标灌 gains。跨采样率/跨段数时这会把增益贴到错误的频点上 ——
         * 预设保存时的网格与载入时的网格只要不完全一致，整条曲线就错位。
         *
         * 正确做法是**按频率**重映射：新网格的每个频点，取预设里最接近的
         * 那个频点上的增益。这样采样率、段数变化都只影响取样密度，
         * 曲线形状保持不变。 */
        final freqs = (eq['frequencies'] as List?)
                ?.map((e) => (e as num).toDouble()).toList();
        if (freqs != null && freqs.length == list.length && freqs.isNotEmpty) {
          m.applyEqCurve(freqs, list);
        } else {
          // 老预设没有频率信息，只能按段数 + 下标还原（保持向后兼容）
          m.applyEqGains(list);
        }
      }
      if (eq['presetName'] != null) {
        m.eqPresetName = eq['presetName'] as String;
      }
      if (eq['autoGain'] != null) {
        m.setEqAutoGain(eq['autoGain'] as bool);
      }
      if (eq['outputGain'] != null) {
        m.setEqOutputGain((eq['outputGain'] as num).toDouble());
      }
      if (eq['enable'] != null) {
        m.setInt('eq.enable', (eq['enable'] as bool) ? 1 : 0);
      }
    }

    // 5. 立体声扩展（按 Master-Macro 乘数联动架构还原）
    final st = (p['stereo'] as Map<String, dynamic>?) ?? {};
    if (st.isNotEmpty) {
      final mixVal = (st['mix'] as num?)?.toDouble();
      if (st['on'] != null) {
        m.stereoOn = st['on'] as bool;
      } else if (mixVal != null) {
        // 旧快照无开关位：沿用旧语义（mix>0 视为开），避免恢复后有值无声。
        m.stereoOn = mixVal > 0.0;
      }
      if (st['bands'] is List) {
        final bands = (st['bands'] as List).map((e) => (e as num).toDouble()).toList();
        for (var i = 0; i < bands.length && i < 5; i++) {
          m.stereoBands[i] = bands[i].clamp(0.0, 1.0);
        }
      }
      if (st['mix'] != null) {
        m.setStereoMix((st['mix'] as num).toDouble());
      } else if (st['bands'] is List) {
        for (var i = 0; i < 5; i++) {
          m.setStereoBand(i, m.stereoBands[i]);
        }
      }
      // bandUsed 必须读回：上面的 setStereoMix/setStereoBand 自带
      // bandUsed=true 副作用（保持旧 _mirror 行为），若不让快照值覆盖，
      // 「从未调过分带」的快照恢复后也被切成 per-band 展宽模式
      // （engine_chain 按 stereo_band_used 二选一），与全新安装行为不一致。
      if (st['bandUsed'] != null) {
        m.stereoBandUsed = st['bandUsed'] as bool;
      }
    }

    // 6. 后级增益与限幅
    final post = (p['post'] as Map<String, dynamic>?) ?? {};
    if (post.isNotEmpty) {
      if (post['gain'] != null) {
        m.setFloat('post.gain', (post['gain'] as num).toDouble());
      }
      if (post['limiterEnable'] != null) {
        m.setInt('limiter.enable', (post['limiterEnable'] as bool) ? 1 : 0);
      }
    }

    // 7. 处理链顺序
    if (p['chainOrder'] is String) {
      m.setGraphOrder(p['chainOrder'] as String);
    }

    // 8. 低频搁架 —— snapshot 会写这节，apply 必须对称读回，
    //否则「Studio Flat Monitor」这类平直预设关不掉已开启的搁架。
    final shelf = (p['shelf'] as Map<String, dynamic>?) ?? {};
    if (shelf.isNotEmpty) {
      if (shelf['freq'] != null) {
        m.setFloat('shelf.freq', (shelf['freq'] as num).toDouble());
      }
      if (shelf['gain'] != null) {
        m.setFloat('shelf.gain', (shelf['gain'] as num).toDouble());
      }
      // enable 必须最后下发：引擎侧先按 freq/gain 重算系数，再由它决定是否旁路
      if (shelf['enable'] != null) {
        m.setInt('shelf.enable', (shelf['enable'] as bool) ? 1 : 0);
      }
    }

    // 8.5 低频单声道化（freq 先行，enable 最后）
    final bm = (p['bassmono'] as Map<String, dynamic>?) ?? {};
    if (bm.isNotEmpty) {
      if (bm['freq'] != null) {
        m.setBassmonoFreq((bm['freq'] as num).toDouble());
      }
      if (bm['enable'] != null) {
        m.setBassmonoEnabled(bm['enable'] as bool);
      }
    }

    // 8.6 Haas 差分环绕（delay/mix 先行，enable 最后）
    final hs = (p['haas'] as Map<String, dynamic>?) ?? {};
    if (hs.isNotEmpty) {
      if (hs['delay'] != null) {
        m.setHaasDelay((hs['delay'] as num).toDouble());
      }
      if (hs['mix'] != null) {
        m.setHaasMix((hs['mix'] as num).toDouble());
      }
      if (hs['side'] != null) {
        m.setHaasSide((hs['side'] as num).toInt());
      }
      if (hs['enable'] != null) {
        m.setHaasEnabled(hs['enable'] as bool);
      }
    }

    // 8.7 激励器（amount/hifreq 先行，enable 最后）
    final ex = (p['exciter'] as Map<String, dynamic>?) ?? {};
    if (ex.isNotEmpty) {
      if (ex['amount'] != null) {
        m.setExciterAmount((ex['amount'] as num).toDouble());
      }
      if (ex['hifreq'] != null) {
        m.setExciterHifreq((ex['hifreq'] as num).toDouble());
      }
      if (ex['enable'] != null) {
        m.setExciterEnabled(ex['enable'] as bool);
      }
    }

    // 8.8 噪声门（参数先行，enable 最后）
    final gt = (p['gate'] as Map<String, dynamic>?) ?? {};
    if (gt.isNotEmpty) {
      if (gt['threshold'] != null) m.setGateThreshold((gt['threshold'] as num).toDouble());
      if (gt['attack'] != null) m.setGateAttack((gt['attack'] as num).toDouble());
      if (gt['release'] != null) m.setGateRelease((gt['release'] as num).toDouble());
      if (gt['autoGain'] != null) m.setGateAutoGain(gt['autoGain'] as bool);
      if (gt['enable'] != null) m.setGateEnabled(gt['enable'] as bool);
    }

    // 8.9 Deesser（参数先行，enable 最后）
    final ds = (p['deesser'] as Map<String, dynamic>?) ?? {};
    if (ds.isNotEmpty) {
      if (ds['freq'] != null) m.setDeesserFreq((ds['freq'] as num).toDouble());
      if (ds['amount'] != null) m.setDeesserAmount((ds['amount'] as num).toDouble());
      if (ds['enable'] != null) m.setDeesserEnabled(ds['enable'] as bool);
    }

    // 8.10 全参数动态EQ（参数先行，段 enable 随后，总 enable 最后）
    final dq = (p['dyneq'] as Map<String, dynamic>?) ?? {};
    if (dq.isNotEmpty) {
      if (dq['attack'] != null) m.setDyneqAttack((dq['attack'] as num).toDouble());
      if (dq['release'] != null) m.setDyneqRelease((dq['release'] as num).toDouble());
      void applyBand(String key, void Function(bool) setEn, void Function(double) setF,
          void Function(double) setQ, void Function(double) setG,
          void Function(double) setR, void Function(double) setT) {
        final b = (dq[key] as Map<String, dynamic>?) ?? {};
        if (b.isEmpty) return;
        if (b['freq'] != null) setF((b['freq'] as num).toDouble());
        if (b['q'] != null) setQ((b['q'] as num).toDouble());
        if (b['gain'] != null) setG((b['gain'] as num).toDouble());
        if (b['range'] != null) setR((b['range'] as num).toDouble());
        if (b['threshold'] != null) setT((b['threshold'] as num).toDouble());
        if (b['enable'] != null) setEn(b['enable'] as bool);
      }
      applyBand('low', m.setDyneqLowEnabled, m.setDyneqLowFreq, m.setDyneqLowQ,
          m.setDyneqLowGain, m.setDyneqLowRange, m.setDyneqLowThreshold);
      applyBand('mid', m.setDyneqMidEnabled, m.setDyneqMidFreq, m.setDyneqMidQ,
          m.setDyneqMidGain, m.setDyneqMidRange, m.setDyneqMidThreshold);
      applyBand('high', m.setDyneqHighEnabled, m.setDyneqHighFreq, m.setDyneqHighQ,
          m.setDyneqHighGain, m.setDyneqHighRange, m.setDyneqHighThreshold);
      if (dq['enable'] != null) m.setDyneqEnabled(dq['enable'] as bool);
    }

    // 8.11 响度补偿
    final ld = (p['loudness'] as Map<String, dynamic>?) ?? {};
    if (ld.isNotEmpty) {
      if (ld['amount'] != null) m.setLoudnessAmount((ld['amount'] as num).toDouble());
      if (ld['enable'] != null) m.setLoudnessEnabled(ld['enable'] as bool);
    }

    // 8.10 独立滤波器（参数先行，enable 最后）
    final ft = (p['filter'] as Map<String, dynamic>?) ?? {};
    if (ft.isNotEmpty) {
      if (ft['type'] != null) m.setFilterType((ft['type'] as num).toInt());
      if (ft['freq'] != null) m.setFilterFreq((ft['freq'] as num).toDouble());
      if (ft['q'] != null) m.setFilterQ((ft['q'] as num).toDouble());
      if (ft['enable'] != null) m.setFilterEnabled(ft['enable'] as bool);
    }

    // 9. 脉冲卷积（IR 路径由 convIrPath / 会话层负责重载，这里只恢复使能与混合比）
    final conv = (p['convolver'] as Map<String, dynamic>?) ?? {};
    if (conv.isNotEmpty) {
      if (conv['mix'] != null) {
        m.setFloat('convolver.mix', (conv['mix'] as num).toDouble());
      }
      if (conv['enable'] != null) {
        m.setConvolverEnabled(conv['enable'] as bool);
      }
    }

    // 10. VDC（扬声器校正）
    final ddc = (p['ddc'] as Map<String, dynamic>?) ?? {};
    if (ddc.isNotEmpty && ddc['enable'] != null) {
      m.setDdcEnabled(ddc['enable'] as bool);
    }

    // 10.5 动态压限器
    final comp = (p['comp'] as Map<String, dynamic>?) ?? {};
    if (comp.isNotEmpty) {
      if (comp['timeconstant'] != null) {
        m.setCompTimeconstant((comp['timeconstant'] as num).toDouble());
      }
      if (comp['granularity'] != null) {
        m.setCompGranularity((comp['granularity'] as num).toInt());
      }
      if (comp['tfresolution'] != null) {
        m.setCompTfresolution((comp['tfresolution'] as num).toInt());
      }
      if (comp['autoGain'] != null) {
        m.setCompAutoGain(comp['autoGain'] as bool);
      }
      if (comp['outputGain'] != null) {
        m.setCompOutputGain((comp['outputGain'] as num).toDouble());
      }
      if (comp['enable'] != null) {
        m.setCompEnabled(comp['enable'] as bool);
      }
    }

    // 10.6 任意响应 EQ（ArbMag）
    final arb = (p['arbmag'] as Map<String, dynamic>?) ?? {};
    if (arb.isNotEmpty) {
      if (arb['string'] != null && (arb['string'] as String).isNotEmpty) {
        m.setArbmagString(arb['string'] as String);
      }
      if (arb['autoGain'] != null) {
        m.setArbmagAutoGain(arb['autoGain'] as bool);
      }
      if (arb['outputGain'] != null) {
        m.setArbmagOutputGain((arb['outputGain'] as num).toDouble());
      }
      if (arb['enable'] != null) {
        m.setArbmagEnabled(arb['enable'] as bool);
      }
    }

    // 11. 交叉反馈（fcut/feed 先行，mode 随后，避免联动误切自定义）
    final xf = (p['crossfeed'] as Map<String, dynamic>?) ?? {};
    if (xf.isNotEmpty) {
      if (xf['fcut'] != null) m.setCrossfeedFcut((xf['fcut'] as num).toDouble());
      if (xf['feed'] != null) m.setCrossfeedFeed((xf['feed'] as num).toDouble());
      if (xf['mode'] != null) m.setCrossfeedMode(xf['mode'] as int);
      if (xf['enable'] != null) {
        m.setCrossfeedEnabled(xf['enable'] as bool);
      }
    }

    // 12. 脚本（v2：只恢复使能与滑块；全文不在预设里）。
    // 无 liveprog 节的老预设/老会话直接跳过，脚本态保持不动。
    final lp = (p['liveprog'] as Map<String, dynamic>?) ?? {};
    if (lp.isNotEmpty) {
      if (lp['params'] is List) {
        final saved =
            (lp['params'] as List).map((e) => (e as num).toDouble()).toList();
        for (var i = 0; i < saved.length && i < 8; i++) {
          m.lpParams[i] = saved[i];
        }
      }
      if (lp['enabled'] != null) m.lpEnabled = lp['enabled'] as bool;
      final savedHash = lp['codeHash'] as String?;
      m.lpPresetCodeMismatch = savedHash != null &&
          savedHash.isNotEmpty &&
          savedHash != _lpCodeHash(m.lpCode);
      // 下发（运行时切预设即时生效；会话恢复时引擎未连，send 空转安全，
      // 连接后 replaySessionToEngine 会再推一次全量，幂等）。
      m.setLiveprogEnabled(m.lpEnabled);
      for (var i = 0; i < 8; i++) {
        m.setLiveprogParam(i, m.lpParams[i]);
      }
    }

    // 13. 音频路由与设备记忆（接入预设系统）
    // 验证设备是否在当前环境中存在：在就按照记忆，不在就走默认或者留空标明无可用设备
    final routing = (p['routing'] as Map<String, dynamic>?);
    if (routing != null && routing.isNotEmpty) {
      if (routing['pipelineInputEnabled'] is bool) {
        m.setPipelineInputEnabled(routing['pipelineInputEnabled'] as bool);
      }
      if (routing['pipelineOutputEnabled'] is bool) {
        m.setPipelineOutputEnabled(routing['pipelineOutputEnabled'] as bool);
      }
      if (routing['monitorMirroring'] is bool) {
        m.setMonitorMirroring(routing['monitorMirroring'] as bool);
      }

      // 验证设备是否在当前环境中存在：在就按照记忆，不在就走默认或留空
      if (routing['pipelineInputDevice'] is String) {
        final dev = routing['pipelineInputDevice'] as String;
        final exists = dev.isNotEmpty &&
            m.wasapiDevices.any((d) => !d.isRender && (d.id == dev || d.name == dev));
        m.setPipelineInputDevice(exists ? dev : '');
      }
      if (routing['pipelineOutputDevice'] is String) {
        final dev = routing['pipelineOutputDevice'] as String;
        final exists = dev.isNotEmpty &&
            m.wasapiDevices.any((d) => d.isRender && (d.id == dev || d.name == dev));
        m.setPipelineOutputDevice(exists ? dev : '');
      }
      if (routing['vaioOutputEndpoint'] is String) {
        final ep = routing['vaioOutputEndpoint'] as String;
        final exists = ep.isNotEmpty &&
            m.vaioPhysicalEndpoints.any((d) => d.name == ep || d.id == ep);
        m.setVaioOutputEndpoint(exists ? ep : '');
      }
      if (routing['apoTargetEndpoint'] is String) {
        final ep = routing['apoTargetEndpoint'] as String;
        final exists = ep.isNotEmpty &&
            (m.vaioPhysicalEndpoints.any((d) => d.name == ep || d.id == ep) ||
                m.wasapiDevices.any((d) => d.id == ep || d.name == ep));
        m.setApoTargetEndpoint(exists ? ep : '');
      }
      if (routing['asioDriver'] is String) {
        final drv = routing['asioDriver'] as String;
        final names = [for (final d in m.asioDrivers) d['name'] ?? ''];
        final exists = drv.isNotEmpty && names.contains(drv);
        m.setAsioDriver(exists ? drv : (names.isNotEmpty ? names.first : ''));
      }
      if (routing['asioBufSize'] is num) {
        m.setAsioBufSize((routing['asioBufSize'] as num).toInt());
      }
      if (routing['asioOutPair'] is num) {
        m.setAsioOutPair((routing['asioOutPair'] as num).toInt());
      }
    }

    m.activePresetName = preset.name;
    // 脏跟踪锚点（2026-10-16 决策 #3）：应用成功后把当前状态记为
    // 「不脏」的基准；之后任意参数偏离都会使 fingerprintOf 失配
    // → 进入自定义/未保存态。会话恢复路径（restoreMemoryImage）随后
    // 会用会话里存的锚点覆盖本值，见 session_memory.dart。
    m.appliedPresetFingerprint = fingerprintOf(m);
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
    } catch (_) {}
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
