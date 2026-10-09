/*
 * presets.dart — 引擎全量参数快照（预设）库（M3-b 附属，纯 app 层零新依赖）
 *
 * 格式：JSON {version, name, savedAt, params:{...}}，存
 * %APPDATA%/AuraDSP/presets/。载入 = 逐项 setParam（引擎守卫照常生效，
 * T2 类效果在音乐档下会被拒并经既有 EventBanner 提示——诚实不静默）。
 * liveprog 代码不入预设（脚本有独立库管理），convolver 仅在 IR 已加载时
 * 才下发 enable。
 */
import 'dart:convert';
import 'dart:io';

import '../core/state.dart';

abstract final class PresetLibrary {
  static String? _dir;

  static String get dir {
    if (_dir != null) return _dir!;
    final appData = Platform.environment['APPDATA'];
    _dir = appData != null
        ? Directory('$appData${Platform.pathSeparator}AuraDSP'
                '${Platform.pathSeparator}presets').path
        : 'presets';
    return _dir!;
  }

  static List<String> list() {
    try {
      final d = Directory(dir);
      if (!d.existsSync()) return const [];
      return d
          .listSync()
          .whereType<File>()
          .where((f) => f.path.toLowerCase().endsWith('.json'))
          .map((f) => f.uri.pathSegments.last)
          .toList()
        ..sort();
    } catch (_) {
      return const [];
    }
  }

  static bool save(String name, Map<String, dynamic> params) {
    if (name.contains(RegExp(r'[\\/:*?"<>|]')) || name.contains('..')) {
      return false;
    }
    if (!name.toLowerCase().endsWith('.json')) name = '$name.json';
    try {
      final d = Directory(dir);
      if (!d.existsSync()) d.createSync(recursive: true);
      final payload = {
        'version': 1,
        'name': name,
        'savedAt': DateTime.now().toIso8601String(),
        'params': params,
      };
      File('$dir${Platform.pathSeparator}$name')
          .writeAsStringSync(jsonEncode(payload));
      return true;
    } catch (_) {
      return false;
    }
  }

  static Map<String, dynamic>? load(String name) {
    try {
      final raw = File('$dir${Platform.pathSeparator}$name').readAsStringSync();
      final doc = jsonDecode(raw) as Map<String, dynamic>;
      return doc['params'] as Map<String, dynamic>?;
    } catch (_) {
      return null;
    }
  }

  static bool delete(String name) {
    try {
      final f = File('$dir${Platform.pathSeparator}$name');
      if (f.existsSync()) f.deleteSync();
      return true;
    } catch (_) {
      return false;
    }
  }

  /* ---- 快照 ---- */

  static Map<String, dynamic> snapshot(AppModel m) => {
        'bass.enable': m.bassOn ? 1 : 0,
        'bass.gain': m.bassGain,
        'reverb.preset': m.reverbPreset,
        'stereo.mix': m.stereoMix * AppModel.stereoWidenMax,
        if (m.stereoBandUsed)
          for (var i = 0; i < 5; i++)
            'stereo.band${i + 1}': m.stereoBands[i],
        'eq.enable': m.eqOn ? 1 : 0,
        'post.gain': m.postGain,
        'limiter.enable': m.limiterOn ? 1 : 0,
        'mode.latency': m.latencyMode,
        'tube.enable': m.tubeOn ? 1 : 0,
        'crossfeed.enable': m.xfeedOn ? 1 : 0,
        'shelf.enable': m.shelfOn ? 1 : 0,
        'shelf.freq': m.shelfFreq,
        'shelf.gain': m.shelfGain,
        'convolver.enable': (m.convEnabled && m.convReady) ? 1 : 0,
        'liveprog.enable': m.lpEnabled ? 1 : 0,
        'freeverb.enable': m.fvOn ? 1 : 0,
        'freeverb.decay': m.fvDecay,
        'freeverb.damp': m.fvDamp,
        'freeverb.wet': m.fvWet,
        'freeverb.dry': m.fvDry,
      };

  /// 逐项下发：float 类参数白名单，其余按 i32。
  /// convolver.enable 只在 IR 已就绪时下发（引擎会拒无 IR 的使能）。
  static void apply(AppModel m, Map<String, dynamic> params) {
    const floatIds = {
      'bass.gain', 'stereo.mix', 'post.gain', 'shelf.freq', 'shelf.gain',
      'freeverb.decay', 'freeverb.damp', 'freeverb.wet', 'freeverb.dry',
    };
    params.forEach((id, v) {
      if (id == 'convolver.enable' && !m.convReady) return;
      if (floatIds.contains(id)) {
        m.setFloat(id, (v as num).toDouble());
      } else {
        m.setInt(id, (v as num).toInt());
      }
    });
  }
}
