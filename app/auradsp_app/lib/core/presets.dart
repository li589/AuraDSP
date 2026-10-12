/*
 * presets.dart — AuraDSP 预设系统 v2
 *
 * 规范：统一 Schema v2，区分出厂预设 (只读) 与用户预设。
 * 覆盖全部 8 大效果卡片完整参数（包含交互式 EQ 曲线、低音谐波、电子管饱和度等）。
 * 存储路径：%APPDATA%/AuraDSP/presets/
 */

import 'dart:convert';
import 'dart:io';

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

  /// 确保出厂预设目录及文件已初始化
  static void ensureInitialized() {
    try {
      final fDir = Directory(factoryDir);
      if (!fDir.existsSync()) fDir.createSync(recursive: true);
      final uDir = Directory(userDir);
      if (!uDir.existsSync()) uDir.createSync(recursive: true);

      for (final p in _builtInPresets) {
        final f = File('$factoryDir${Platform.pathSeparator}${_safeFileName(p.name)}.json');
        if (!f.existsSync()) {
          final content = const JsonEncoder.withIndent('  ').convert(p.toJson());
          f.writeAsStringSync(content);
        }
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
          'oversampling': m.tubeOversampling,
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
      },
    );
  }

  static void apply(AppModel m, AuraPreset preset) {
    final p = preset.params;

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
        m.setReverbCustomParam('decay', (rev['decay'] as num?)?.toDouble() ?? 0.5);
        m.setReverbCustomParam('damp', (rev['damp'] as num?)?.toDouble() ?? 0.5);
        m.setReverbCustomParam('wet', (rev['wet'] as num?)?.toDouble() ?? 0.35);
        m.setReverbCustomParam('dry', (rev['dry'] as num?)?.toDouble() ?? 1.0);
        m.setReverbCustomParam('roomSize', (rev['roomSize'] as num?)?.toDouble() ?? 1.2);
        m.setReverbCustomParam('width', (rev['stereoWidth'] as num?)?.toDouble() ?? 1.0);
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
      if (tube['oversampling'] != null) {
        m.setTubeOversampling((tube['oversampling'] as num).toInt());
      }
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

    // 11. 交叉反馈
    final xf = (p['crossfeed'] as Map<String, dynamic>?) ?? {};
    if (xf.isNotEmpty && xf['enable'] != null) {
      m.setCrossfeedEnabled(xf['enable'] as bool);
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

    m.activePresetName = preset.name;
  }

  /* ---- 6 大出厂经典调音预设 ---- */

  static final List<AuraPreset> _builtInPresets = [
    // 01 流行清澈人声
    AuraPreset(
      name: 'Pop Vocal Clarity',
      category: '流行人声',
      description: '突出人声泛音与透亮度，注入适度三极管暖声与精致短混响',
      author: 'AuraDSP Acoustics',
      createdAt: '2026-10-10T10:00:00Z',
      isFactory: true,
      params: {
        'bass': {
          'enable': true,
          'intensity': 0.45,
          'mode': 0,
          'cutoff': 110.0,
          'harmonics': 0.35,
          'harmonicBlend': 0.5,
          'subFloor': 30.0,
        },
        'reverb': {
          'enable': true,
          'preset': 1, // 小型厅堂
          'decay': 0.35,
          'damp': 0.6,
          'wet': 0.25,
          'dry': 1.0,
          'roomSize': 1.0,
          'stereoWidth': 1.0,
        },
        'tube': {
          'enable': true,
          'gain': 3.0,
          'style': 0, // 三极管 12AX7
          'oversampling': 2,
          'compensation': 0.0,
          'mix': 0.75,
        },
        'eq': {
          'enable': true,
          'bandsCount': 15,
          'gains': [0, 0, 0, -0.5, 0.5, 1.0, 1.5, 2.5, 3.5, 3.0, 2.0, 1.5, 1.0, 0.5, 0],
          'q': 1.414,
          'filter': 0,
          'interp': 1,
          'presetName': 'vocal',
        },
        'stereo': {'mix': 0.25, 'bandUsed': false},
        'post': {'gain': 0.0, 'limiterEnable': true},
      },
    ),
    // 02 摇滚深邃重低音
    AuraPreset(
      name: 'Rock Bass Impact',
      category: '重低音',
      description: '心理声学谐波强化，低频下潜强劲下沉，配合现代五极管动态饱和',
      author: 'AuraDSP Acoustics',
      createdAt: '2026-10-10T10:00:00Z',
      isFactory: true,
      params: {
        'bass': {
          'enable': true,
          'intensity': 0.85,
          'mode': 2, // 心理声学谐波
          'cutoff': 140.0,
          'harmonics': 0.75,
          'harmonicBlend': 0.65,
          'subFloor': 20.0,
        },
        'reverb': {
          'enable': false,
          'preset': -1,
        },
        'tube': {
          'enable': true,
          'gain': 5.5,
          'style': 1, // 五极管 EL34
          'oversampling': 2,
          'compensation': -1.0,
          'mix': 0.85,
        },
        'eq': {
          'enable': true,
          'bandsCount': 15,
          'gains': [5.0, 4.5, 3.5, 2.0, 1.0, -1.0, -1.5, -1.0, 0.5, 1.5, 2.5, 3.5, 4.0, 3.0, 2.0],
          'q': 1.414,
          'filter': 0,
          'interp': 1,
          'presetName': 'rock',
        },
        'stereo': {'mix': 0.35, 'bandUsed': false},
        'post': {'gain': 0.0, 'limiterEnable': true},
      },
    ),
    // 03 宏伟交响大厅
    AuraPreset(
      name: 'Symphonic Concert Hall',
      category: '空间声学',
      description: '大动态 3D 声学室模拟，深度去相关声场展宽，带来身临其境的音乐厅听感',
      author: 'AuraDSP Acoustics',
      createdAt: '2026-10-10T10:00:00Z',
      isFactory: true,
      params: {
        'bass': {
          'enable': true,
          'intensity': 0.5,
          'mode': 1, // 纯净低架
          'cutoff': 100.0,
          'harmonics': 0.3,
          'harmonicBlend': 0.5,
          'subFloor': 25.0,
        },
        'reverb': {
          'enable': true,
          'preset': 3, // 大会堂
          'decay': 0.75,
          'damp': 0.45,
          'wet': 0.45,
          'dry': 0.9,
          'roomSize': 1.8,
          'stereoWidth': 1.6,
        },
        'tube': {
          'enable': false,
          'gain': 0.0,
        },
        'eq': {
          'enable': true,
          'bandsCount': 15,
          'gains': [1.0, 1.0, 0.5, 0.5, 0.0, 0.0, 0.5, 1.0, 1.5, 1.5, 1.0, 1.0, 1.5, 1.5, 1.0],
          'q': 1.414,
          'filter': 0,
          'interp': 1,
          'presetName': 'classical',
        },
        'stereo': {'mix': 0.65, 'bandUsed': false},
        'post': {'gain': 0.0, 'limiterEnable': true},
      },
    ),
    // 04 经典黑胶暖管
    AuraPreset(
      name: 'Vintage Vinyl Tube',
      category: '模拟复古',
      description: '模拟磁带温润饱和与电子管轻微二阶谐波染色，抚平数码生硬感',
      author: 'AuraDSP Acoustics',
      createdAt: '2026-10-10T10:00:00Z',
      isFactory: true,
      params: {
        'bass': {
          'enable': true,
          'intensity': 0.6,
          'mode': 0,
          'cutoff': 120.0,
          'harmonics': 0.4,
          'harmonicBlend': 0.5,
          'subFloor': 30.0,
        },
        'reverb': {
          'enable': false,
          'preset': -1,
        },
        'tube': {
          'enable': true,
          'gain': 6.0,
          'style': 2, // 模拟磁带温润
          'oversampling': 4,
          'compensation': 0.5,
          'mix': 1.0,
        },
        'eq': {
          'enable': true,
          'bandsCount': 15,
          'gains': [2.0, 2.5, 2.0, 1.5, 1.0, 0.5, 0.0, -0.5, -0.5, 0.0, 0.5, -0.5, -1.0, -2.0, -3.0],
          'q': 1.414,
          'filter': 0,
          'interp': 1,
          'presetName': 'warm',
        },
        'stereo': {'mix': 0.2, 'bandUsed': false},
        'post': {'gain': 0.0, 'limiterEnable': true},
      },
    ),
    // 05 动感微笑曲线
    AuraPreset(
      name: 'V-Shape Smile Hi-Fi',
      category: '流行流行',
      description: '两端提升中间平缓的经典 Smile 调音，能量充沛，明快抓耳',
      author: 'AuraDSP Acoustics',
      createdAt: '2026-10-10T10:00:00Z',
      isFactory: true,
      params: {
        'bass': {
          'enable': true,
          'intensity': 0.7,
          'mode': 0,
          'cutoff': 130.0,
          'harmonics': 0.5,
          'harmonicBlend': 0.5,
          'subFloor': 25.0,
        },
        'reverb': {
          'enable': false,
          'preset': -1,
        },
        'tube': {
          'enable': true,
          'gain': 3.5,
          'style': 0,
          'oversampling': 2,
          'compensation': 0.0,
          'mix': 0.8,
        },
        'eq': {
          'enable': true,
          'bandsCount': 15,
          'gains': [5.0, 4.0, 3.0, 1.5, 0.0, -1.5, -2.5, -2.5, -1.5, 0.0, 1.5, 3.0, 4.0, 5.0, 5.5],
          'q': 1.414,
          'filter': 0,
          'interp': 1,
          'presetName': 'smile',
        },
        'stereo': {'mix': 0.35, 'bandUsed': false},
        'post': {'gain': 0.0, 'limiterEnable': true},
      },
    ),
    // 06 录音棚平直监听
    AuraPreset(
      name: 'Studio Flat Monitor',
      category: '专业监听',
      description: '全频带线性直通，零额外染色与平直响应，供母带与录音回放基准对比',
      author: 'AuraDSP Acoustics',
      createdAt: '2026-10-10T10:00:00Z',
      isFactory: true,
      params: {
        'bass': {
          'enable': false,
          'intensity': 0.0,
          'gain': 0.0,
        },
        'reverb': {
          'enable': false,
          'preset': -1,
        },
        'tube': {
          'enable': false,
          'gain': 0.0,
        },
        'eq': {
          'enable': true,
          'bandsCount': 15,
          'gains': [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
          'q': 1.414,
          'filter': 0,
          'interp': 1,
          'presetName': 'flat',
        },
        'stereo': {'mix': 0.0, 'bandUsed': false},
        'shelf': {'enable': false, 'gain': 0.0},
        'post': {'gain': 0.0, 'limiterEnable': true},
      },
    ),
  ];
}
