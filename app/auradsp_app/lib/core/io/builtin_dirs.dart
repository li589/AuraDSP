// builtin_dirs.dart — 安装内置目录登记（资源计划 P2 / Part B1）。
//
// 打包期由 pack 定版在 <exeDir>/resources/builtin_dirs.json 登记
// 安装目录下四类资源位置（installer pack.py finalize 生成，Linux
// 经 merge_resources.py 同源）；App 启动读取，把「安装内置」目录
// 交给各消费方（插件扫描目录、脚本库、资源定位器）。
//
// 容错口径：文件缺失、损坏、版本不认 → 空登记，全部消费方回退
// 既有探测/播种口径，绝不因登记文件问题影响启动。进程内缓存
// 一份（登记在运行期不变）。

import 'dart:convert';
import 'dart:io';

import '../../platform/platform_profile.dart';
import '../error_sink.dart';

class BuiltinDirs {
  BuiltinDirs._(this.byKind);

  /// kind（convolver/ddc/liveprog/plugins）→ 绝对路径。
  final Map<String, String> byKind;

  static const kinds = ['convolver', 'ddc', 'liveprog', 'plugins'];

  String? operator [](String kind) => byKind[kind];

  static BuiltinDirs? _cache;

  static BuiltinDirs load() => _cache ??= _load();

  static BuiltinDirs _load() {
    try {
      final sep = Platform.pathSeparator;
      final exeDir = PlatformProfile.executableDir;
      final f = File('$exeDir${sep}resources${sep}builtin_dirs.json');
      if (!f.existsSync()) return BuiltinDirs._(const {});
      final decoded = jsonDecode(f.readAsStringSync());
      if (decoded is! Map || decoded['version'] != 1) {
        return BuiltinDirs._(const {});
      }
      final out = <String, String>{};
      final dirs = decoded['dirs'];
      if (dirs is List) {
        for (final d in dirs) {
          if (d is Map) {
            final kind = d['kind'];
            final rel = d['rel'];
            if (kind is String && rel is String && kinds.contains(kind)) {
              out[kind] = '$exeDir$sep${rel.replaceAll('/', sep)}';
            }
          }
        }
      }
      return BuiltinDirs._(out);
    } catch (e, st) {
      swallow(e, st);
      return BuiltinDirs._(const {});
    }
  }
}
