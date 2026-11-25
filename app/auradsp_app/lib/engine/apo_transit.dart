// apo_transit.dart — APO 文件中转（资源计划 Part C / P4；设计
// 骨架 = APO 计划书 Part III，2026-11-10 定稿、2026-11-12 业主
// 裁定沿用中转根）。
//
// 问题：audiodg 以 LocalService 身份运行，读不到用户任意选址
// 的 IR/VDC 文件（用户目录 ACL 无 LocalService 读权，第十轮已
// 实证）。解法：文件被引用时按内容哈希复制进中转根
// %ProgramData%\AuraDSP\apo-assets\（LocalService 可读），参数
// 通道只传中转路径；引擎侧（ApoEngineHost）围栏校验路径必须
// 在中转根下，防任意路径下发。UI 始终显示原始路径（业主 Q3
// 裁定：界面保留现状，内部处理走副本）。
//
// 本类只被 APO 参数发布者（audio_isolate_apo）使用：非 APO 模
// 式的引擎在 App 进程内、直接读原路径，永不经此。文件中转失败
// 吞错并留日志，发布者写空路径（引擎卸载该文件）；插件中转则返回
// 带原因的结构化失败，经现有槽位终态事件呈现，绝不假装可用。

import 'dart:io';

import 'package:crypto/crypto.dart';

import '../platform/port/windows_system.dart';
import 'debug_log.dart';

final class ApoPluginTransitResult {
  const ApoPluginTransitResult({this.path, this.errorMessage});

  final String? path;
  final String? errorMessage;
}

abstract final class ApoTransit {
  static bool _rootReady = false;
  static final Set<String> _copied = {};

  /// 中转根：%ProgramData%\AuraDSP\apo-assets（ProgramData 环境
  /// 变量缺失时回退到固定盘符口径）。
  static String get root {
    final pd = Platform.environment['ProgramData'] ?? r'C:\ProgramData';
    return '$pd${Platform.pathSeparator}AuraDSP'
        '${Platform.pathSeparator}apo-assets';
  }

  static bool isTransitPath(String path) {
    final norm = path.replaceAll('/', r'\').toLowerCase();
    // A ".." segment would resolve outside the root while passing
    // the prefix test; the host fence canonicalizes, this side
    // rejects outright so such a path is re-copied, not trusted.
    if (norm.split(r'\').contains('..')) return false;
    final r = root.replaceAll('/', r'\').toLowerCase();
    return norm == r || norm.startsWith('$r\\');
  }

  /// 确保中转根存在且 LocalService 可读：目录创建走当前用户
  /// 身份（ProgramData 下用户可建目录）；ACL 授予走平台层端口
  /// （WindowsSystemPort.grantDirReadToLocalService——icacls 按
  /// SID 授予，语言无关；第十八轮 CI 附带项：原先在此直连进程
  /// 调用触 F9/F10 平台隔离门，收回平台层。本类运行于音频隔
  /// 离体、无 AppModel 装配，经端口工厂 createWindowsSystemPort
  /// 取实现，与隔离体直调 createAudioOut 工厂同例。）每进程只做一次。
  static void _ensureRoot() {
    if (_rootReady) return;
    _rootReady = true;
    try {
      final d = Directory(root);
      if (!d.existsSync()) d.createSync(recursive: true);
      createWindowsSystemPort().grantDirReadToLocalService(root);
    } catch (e) {
      dbgLog('apo transit: root prepare failed: $e');
    }
  }

  static const String pluginUnsupportedMessage = '当前版本不支持在系统 APO 内加载第三方插件';

  /// APO 插件入口失败关闭：空路径仍用于显式卸载；任何非空插件路径
  /// 都返回带明确原因的失败结果，让现有槽位终态事件把“不支持”传给
  /// 状态消费方。不得复制后再返回路径，把生产宿主禁止的能力伪装成可用。
  static Future<ApoPluginTransitResult> transitPluginPathForAsync(
    String source,
  ) {
    if (source.isEmpty) {
      return Future.value(ApoPluginTransitResult(path: source));
    }
    dbgLog('apo transit: $pluginUnsupportedMessage: $source');
    return Future.value(
      const ApoPluginTransitResult(errorMessage: pluginUnsupportedMessage),
    );
  }

  /// [transitPathFor] 的异步孪生（插件单文件路径专用，与同步版
  /// 共用同一份已复制缓存）：语义与同步版逐条一致。
  static Future<String?> transitPathForAsync(String source) async {
    try {
      if (source.isEmpty) return source;
      if (isTransitPath(source)) return source;
      final f = File(source);
      if (!await f.exists()) {
        dbgLog('apo transit: source missing: $source');
        return null;
      }
      _ensureRoot();
      final bytes = await f.readAsBytes();
      final hash = sha256.convert(bytes).toString();
      final dot = source.lastIndexOf('.');
      final ext = dot >= 0 ? source.substring(dot).toLowerCase() : '';
      final dest = '$root${Platform.pathSeparator}$hash$ext';
      if (_copied.contains(dest)) return dest;
      final df = File(dest);
      if (!await df.exists()) {
        await df.writeAsBytes(bytes, flush: true);
        dbgLog('apo transit: copied $source -> $dest (${bytes.length} B)');
      }
      _copied.add(dest);
      return dest;
    } catch (e) {
      dbgLog('apo transit: copy failed for $source: $e');
      return null;
    }
  }

  /// 返回 source 的中转副本路径：已在中转根下 → 原样；副本已
  /// 存在（同哈希）→ 直接返回；否则复制。失败返回 null。
  static String? transitPathFor(String source) {
    try {
      if (source.isEmpty) return source;
      if (isTransitPath(source)) return source;
      final f = File(source);
      if (!f.existsSync()) {
        dbgLog('apo transit: source missing: $source');
        return null;
      }
      _ensureRoot();
      final bytes = f.readAsBytesSync();
      final hash = sha256.convert(bytes).toString();
      final dot = source.lastIndexOf('.');
      final ext = dot >= 0 ? source.substring(dot).toLowerCase() : '';
      final dest = '$root${Platform.pathSeparator}$hash$ext';
      if (_copied.contains(dest)) return dest;
      final df = File(dest);
      if (!df.existsSync()) {
        df.writeAsBytesSync(bytes, flush: true);
        dbgLog('apo transit: copied $source -> $dest (${bytes.length} B)');
      }
      _copied.add(dest);
      return dest;
    } catch (e) {
      dbgLog('apo transit: copy failed for $source: $e');
      return null;
    }
  }

  /// 中转孤儿回收（2026-11-23 后续小项轮）：中转根只进不出，
  /// 用户换 IR/DDC/插件后旧副本永久滞留。发布者把「当前参数
  /// 块与插件块实际引用的中转路径集合」交给本方法：不在集合
  /// 内、且最后修改时间早于 [minAge]（默认 7 天）的条目（文件
  /// 或 bundle 目录）删除。双条件是安全垫：audiodg 可能仍持
  /// 有旧参数块引用近期被替换的文件，刚复制尚未下发的副本
  /// mtime 即当前——只删「无引用且足够老」的。逐项失败吞掉
  /// 留日志（与本类既有口径一致），返回实际删除条数。
  /// [rootOverride]/[nowOverride] 仅供测试注入。
  static int collectOrphans(
    Set<String> referenced, {
    Duration minAge = const Duration(days: 7),
    String? rootOverride,
    DateTime? nowOverride,
  }) {
    final dir = Directory(rootOverride ?? root);
    List<FileSystemEntity> entries;
    try {
      if (!dir.existsSync()) return 0;
      entries = dir.listSync();
    } catch (e) {
      // An unguarded listing failure would abort the whole pass
      // and surface only as a generic isolate trace.
      dbgLog('apo transit GC: cannot list ${dir.path}: $e');
      return 0;
    }
    final now = nowOverride ?? DateTime.now();
    String norm(String p) => p.replaceAll('/', r'\').toLowerCase();
    final keep = referenced.map(norm).toSet();
    var removed = 0;
    for (final e in entries) {
      try {
        if (keep.contains(norm(e.path))) continue;
        if (now.difference(e.statSync().modified) < minAge) continue;
        if (e is Directory) {
          e.deleteSync(recursive: true);
        } else {
          e.deleteSync();
        }
        removed++;
        dbgLog('apo transit: orphan removed ${e.path}');
      } catch (err) {
        dbgLog('apo transit: orphan collect failed for ${e.path}: $err');
      }
    }
    if (removed > 0) {
      dbgLog('apo transit: orphan collect removed $removed entries');
    }
    return removed;
  }
}
