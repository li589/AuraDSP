import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;

import '../../../core/config.dart';
import '../../../core/error_sink.dart';
import 'milkdrop_preset.dart';

/// 内置 MilkDrop 预设的资产落盘（r65）。
///
/// 三只内置预设随包以真 .milk 资产发布（assets/milkdrop/），但
/// 原生 projectM 桥只能加载真实文件路径——'builtin:' 伪路径恒
/// 被拒（r64 验收定罪）。启动时把资产释放到用户数据目录
/// milkdrop_builtins/ 并把目录回填 [MilkdropPreset.builtinDir]，
/// 此后所有文件用途统一经 MilkdropPreset.resolveFilePath 解析。
/// 内容版本戳 bump 时整表重写；单文件缺失时单独补齐。
abstract final class MilkdropBuiltinStaging {
  static const int _contentVersion = 1;
  static bool _done = false;
  static bool _inFlight = false;

  static Future<void> ensureStaged() async {
    if (_done || _inFlight) return;
    _inFlight = true;
    try {
      final dir = ConfigManager.subDir('milkdrop_builtins');
      MilkdropPreset.builtinDir = dir.path;
      final sep = Platform.pathSeparator;
      final stampFile = File('${dir.path}$sep.version');
      var stamp = '';
      if (stampFile.existsSync()) {
        stamp = stampFile.readAsStringSync().trim();
      }
      final stale = stamp != '$_contentVersion';
      for (final preset in MilkdropPreset.builtInPresets) {
        final id = preset.filePath.substring('builtin:'.length);
        final out = File('${dir.path}$sep$id.milk');
        if (!stale && out.existsSync()) continue;
        final data = await rootBundle.load('assets/milkdrop/$id.milk');
        await out.writeAsBytes(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          flush: true,
        );
      }
      if (stale) await stampFile.writeAsString('$_contentVersion');
      _done = true;
    } catch (e, st) {
      // 落盘失败不阻断可视化：内置预设回落声明参数的 Dart 渲染。
      // 审查 F4：_done 只在成功后置位——失败不闩锁，后续调用
      // （如下次进入可视化页）会重试落盘；_inFlight 防并发重入。
      swallow(e, st);
    } finally {
      _inFlight = false;
    }
  }
}
