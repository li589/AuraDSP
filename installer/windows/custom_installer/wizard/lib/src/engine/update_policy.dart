/// 安装目录 / 版本 / 更新策略（纯逻辑，无平台依赖，可单测）。
///
/// 设计口径（安装向导优化 2026-11-06）：
/// - 安装目录最后一段必须是 AuraDSP，不是则自动补；
/// - 覆盖升级沿用旧目录、旧组件选择，保留用户数据；
/// - 同版本 = 修复/重装，低版本 = 拦截（先卸载再装）。
library;

import 'package:path/path.dart' as p;

import 'models.dart';

const String kInstallDirLeaf = 'AuraDSP';

/// 规范化安装目录：trim、统一分隔符、去尾部斜杠、末段非 AuraDSP 时补上。
/// 大小写不敏感（用户已写 auradsp / AuraDsp 视为符合，保留原样）。
String normalizeInstallDir(String raw, String fallback) {
  var s = raw.trim().replaceAll('/', r'\');
  while (s.length > 3 && s.endsWith(r'\')) {
    s = s.substring(0, s.length - 1);
  }
  if (s.isEmpty) {
    // fallback 自身也可能为空；第二层兜底保证递归终止。
    return normalizeInstallDir(fallback, r'C:\AuraDSP');
  }
  if (RegExp(r'^[A-Za-z]:$').hasMatch(s)) s = '$s\\';
  final leaf = p.windows.basename(s);
  if (leaf.toLowerCase() == kInstallDirLeaf.toLowerCase()) return s;
  return p.windows.join(s, kInstallDirLeaf);
}

/// 版本号按数字段比较（支持 '.' 与 '+' 分隔），返回 -1 / 0 / 1。
int compareVersion(String a, String b) {
  List<int> parts(String v) => v
      .split(RegExp(r'[.+]'))
      .map((e) => int.tryParse(e.trim()) ?? 0)
      .toList();
  final x = parts(a);
  final y = parts(b);
  final n = x.length > y.length ? x.length : y.length;
  for (var i = 0; i < n; i++) {
    final xv = i < x.length ? x[i] : 0;
    final yv = i < y.length ? y[i] : 0;
    if (xv != yv) return xv > yv ? 1 : -1;
  }
  return 0;
}

enum UpdateMode { fresh, upgrade, repair, downgradeBlocked }

/// 已安装实例信息（注册表 + install_manifest.json）。
class InstalledInfo {
  const InstalledInfo({
    required this.fullVersion,
    required this.installDir,
    this.allUsers = false,
    this.manifest,
  });

  final String fullVersion;
  final String installDir;
  final bool allUsers;
  final InstallManifest? manifest;

  bool get hasManifest => manifest != null;
}

class UpdatePlan {
  const UpdatePlan({
    required this.mode,
    required this.installDir,
    this.previous,
    this.versionCompare = 0,
  });

  final UpdateMode mode;
  final String installDir;
  final InstalledInfo? previous;
  final int versionCompare;

  /// 覆盖既有安装（升级或修复）：需要备份/回滚与用户数据保护。
  bool get isOverwrite => mode == UpdateMode.upgrade || mode == UpdateMode.repair;
  bool get isBlocked => mode == UpdateMode.downgradeBlocked;
  UpdateMode get effectiveMode => mode;
}

/// 依据新版本与已装实例生成安装计划。
///
/// 一般软件的更新语义：升级/修复一律沿用旧目录（不允许借更新换位置），
/// 降级拦截，全新安装才使用用户选择的目录（并自动补 AuraDSP 尾段）。
UpdatePlan planUpdate({
  required String newFullVersion,
  required String requestedDir,
  required String defaultDir,
  InstalledInfo? installed,
}) {
  final requested = normalizeInstallDir(requestedDir, defaultDir);
  if (installed == null || installed.fullVersion.isEmpty) {
    return UpdatePlan(mode: UpdateMode.fresh, installDir: requested);
  }
  final cmp = compareVersion(newFullVersion, installed.fullVersion);
  final dir = installed.installDir.trim().isEmpty
      ? requested
      : normalizeInstallDir(installed.installDir, defaultDir);
  return UpdatePlan(
    mode: cmp < 0
        ? UpdateMode.downgradeBlocked
        : (cmp == 0 ? UpdateMode.repair : UpdateMode.upgrade),
    installDir: dir,
    previous: installed,
    versionCompare: cmp,
  );
}

const List<String> _userDirPrefixes = <String>[
  'user_data/',
  'resources/user_data/',
  'presets/',
  'sessions/',
  'logs/',
];

const List<String> _userFileNames = <String>[
  'config.json',
  'settings.json',
  'install_manifest.json',
];

/// 用户数据路径：覆盖升级的备份/回滚不得删除或覆盖这些文件。
bool isUserPath(String rel) {
  final s = rel.replaceAll(r'\', '/').toLowerCase();
  if (_userDirPrefixes.any(s.startsWith)) return true;
  final name = p.posix.basename(s);
  if (_userFileNames.contains(name)) return true;
  return name.endsWith('.aurapreset.json');
}

/// 卸载时总是删除的生成物（即使不在安装清单里，也不能留，否则下次
/// 安装会被旧清单误判为「已安装」）。
const Set<String> kUninstallGeneratedFiles = <String>{
  'uninstall.exe',
  'install_manifest.json',
};

enum UninstallAction { deleteProgram, keepUserData, deleteAllUserData }

/// 卸载分类（纯函数，可单测）：
/// - 安装清单记录的文件 = 随包程序文件，总是删除；
/// - 清单外的文件 = 用户后加的内容，keepData=true 时保留，否则一并删除；
/// - 卸载器与清单自身 = 生成物，总是删除。
UninstallAction classifyUninstallPath(
        String rel, Set<String> programPaths, bool keepData) {
  final s = rel.replaceAll(r'\', '/').replaceFirst(RegExp(r'^/+'), '');
  if (kUninstallGeneratedFiles.contains(s.toLowerCase())) {
    return UninstallAction.deleteProgram;
  }
  if (programPaths.contains(s)) return UninstallAction.deleteProgram;
  return keepData
      ? UninstallAction.keepUserData
      : UninstallAction.deleteAllUserData;
}

/// 覆盖升级后需要清理的旧版遗留：旧清单有、新清单没有，且不是用户数据
/// 或生成物。成功升级后执行，避免这些文件永久残留在安装目录。
/// [alsoPresent] 是本次仍留在盘上的路径（如写入失败被用户跳过、
/// 保留了旧版的文件），同样不得当遗留删除。
Set<String> staleUpgradePaths(
    InstallManifest? previous, List<ManifestFile> currentFiles,
    {Set<String> alsoPresent = const <String>{}}) {
  if (previous == null) return <String>{};
  final current = currentFiles.map((f) => f.path).toSet();
  return previous.files
      .map((f) => f.path)
      .where((rel) => !current.contains(rel) && !alsoPresent.contains(rel))
      .where((rel) => !isUserPath(rel))
      .where((rel) => !kUninstallGeneratedFiles.contains(rel.toLowerCase()))
      .toSet();
}

/// 关键文件分类（纯函数，可单测）：resources/ 下是资源内容
/// （卷积 IR、DDC、预设、脚本等 bulk 内容），写入失败可跳过；
/// 其余（程序本体、驱动、Flutter 数据、默认层）是关键文件，
/// 失败时只许重试或取消，不许跳过。
bool isCriticalPayloadPath(String rel) {
  final s = rel.replaceAll(r'\', '/').toLowerCase();
  return !s.startsWith('resources/');
}

/// 安装目录不可写时的可行动文案（纯函数，可单测）：把裸异常
/// 翻译成用户能执行的下一步，而不是让安装走到解压中途才失败。
String writabilityFailureMessage({
  required String dir,
  required int? errorCode,
  required String rawError,
  required bool elevated,
}) {
  if (errorCode == 5) {
    // ERROR_ACCESS_DENIED
    return elevated
        ? '安装目录不可写（拒绝访问）：$dir\n'
            '请检查该目录的权限设置或安全软件拦截，处理后重试。\n'
            '（技术详情：$rawError）'
        : '安装目录不可写（拒绝访问）：$dir\n'
            '该目录需要管理员权限。请以管理员身份重新运行安装程序，'
            '或改选当前用户目录（例如“本地应用数据\\Programs\\AuraDSP”）。\n'
            '（技术详情：$rawError）';
  }
  return '无法写入安装目录：$dir\n'
      '请确认目录可写，或换一个目录后重试。\n'
      '（技术详情：$rawError）';
}
