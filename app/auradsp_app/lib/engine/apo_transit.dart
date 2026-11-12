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
// 式的引擎在 App 进程内、直接读原路径，永不经此。全部失败吞
// 掉并留日志——中转失败时发布者写空路径（引擎卸载该文件），
// 绝不把 audiodg 读不到的原始路径写进参数块假装可用。

import 'dart:io';

import 'package:crypto/crypto.dart';

import '../platform/port/windows_system.dart';
import 'debug_log.dart';

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
}
