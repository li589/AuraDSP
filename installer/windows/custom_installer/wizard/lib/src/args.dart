/// 命令行参数（引导壳透传 + 追加，设计 §2/§3）。
///
/// 纯逻辑、无平台依赖，可单测。
library;

import 'package:path/path.dart' as p;

import 'engine/win32.dart';

enum SetupMode { install, uninstall }

class SetupArgs {
  const SetupArgs({
    required this.mode,
    this.setupExe,
    this.payloadOff,
    this.payloadLen,
    this.payloadSha256,
    this.sessionDir,
    this.protectedSession,
    this.silent = false,
    this.elevated = false,
    this.resumeOptions,
    this.autoStart = false,
    this.autoUninstall = false,
    this.keepData,
  });

  final SetupMode mode;

  /// Setup 单体 exe 自身路径（卸载模式下即安装目录内的 uninstall.exe）。
  final String? setupExe;

  /// ZIP-P 在 setupExe 内的偏移/长度（引导壳实测尾块后追加）。
  final int? payloadOff;
  final int? payloadLen;

  /// 提权前计算并跨 UAC 固定的原 ZIP-P SHA256（64 位十六进制）。
  final String? payloadSha256;

  /// 引导壳的临时会话目录（向导退出时自清理）。
  final String? sessionDir;

  /// 提权引导壳新建的管理员-only session；普通安装为 null。
  final String? protectedSession;

  /// /silent 或 --silent：无交互直跑（QuietUninstallString 用）。
  final bool silent;

  /// 经提权协议重启（信息性；真实提权态以令牌检查为准）。
  final bool elevated;

  /// 提权重启时携带的选项状态文件（读后即删）。
  final String? resumeOptions;

  /// 提权重启后自动开始安装（无需用户再点一次「开始安装」）。
  final bool autoStart;

  /// 提权重启后自动开始卸载（从「设置 → 应用 → 卸载」触发）。
  final bool autoUninstall;

  /// 提权重启时继承的「保留用户数据」选择；null = 使用 UI 默认值。
  final bool? keepData;

  bool get hasPayload =>
      setupExe != null && payloadOff != null && payloadLen != null;

  /// 提权向导不得继承交互用户可写的 session 或状态文件路径。路径相等
  /// 只是第一关；根与 session 还必须在最终句柄上具有精确的 SYSTEM/
  /// Administrators owner/DACL、无 reparse，并与声明路径一致。
  void validateProtectedSession({
    ProtectedDirectoryInspector inspector = inspectProtectedDirectory,
  }) {
    if (!elevated) return;
    final protectedDir = protectedSession;
    if (protectedDir == null ||
        protectedDir.isEmpty ||
        !p.isAbsolute(protectedDir)) {
      throw StateError('missing protected session');
    }
    final current = sessionDir;
    if (current == null ||
        !p.isAbsolute(current) ||
        !p.equals(p.normalize(current), p.normalize(protectedDir))) {
      throw StateError('elevated wizard session is not protected');
    }
    final resume = resumeOptions;
    if (resume != null &&
        !p.isWithin(p.normalize(protectedDir), p.normalize(resume))) {
      throw StateError('resume options are outside the protected session');
    }
    final root = p.dirname(protectedDir);
    final rootAttributes = inspector(root);
    final sessionAttributes = inspector(protectedDir);
    if (!hasProtectedDirectorySecurity(rootAttributes) ||
        !hasProtectedDirectorySecurity(sessionAttributes)) {
      throw StateError('protected session security descriptor is untrusted');
    }
    final normalizedRoot = p.normalize(root);
    final normalizedSession = p.normalize(protectedDir);
    if (!p.equals(p.normalize(rootAttributes.finalPath), normalizedRoot) ||
        !p.equals(
          p.normalize(sessionAttributes.finalPath),
          normalizedSession,
        ) ||
        !p.equals(
          p.dirname(sessionAttributes.finalPath),
          rootAttributes.finalPath,
        )) {
      throw StateError('protected session final path does not match');
    }
  }

  static SetupArgs parse(List<String> argv) {
    var mode = SetupMode.install;
    String? setupExe;
    int? off;
    int? len;
    String? payloadSha256;
    String? session;
    String? protectedSession;
    String? resume;
    var silent = false;
    var elevated = false;
    var autoStart = false;
    var autoUninstall = false;
    bool? keepData;

    String? valueAfter(int i) =>
        i + 1 < argv.length && !argv[i + 1].startsWith('--')
            ? argv[i + 1]
            : null;

    for (var i = 0; i < argv.length; i++) {
      final a = argv[i];
      switch (a) {
        case '--mode':
          if (valueAfter(i) == 'uninstall') mode = SetupMode.uninstall;
          i++;
        case '--uninstall':
          mode = SetupMode.uninstall;
        case '--setup-exe':
          setupExe = valueAfter(i);
          i++;
        case '--payload-off':
          off = int.tryParse(valueAfter(i) ?? '');
          i++;
        case '--payload-len':
          len = int.tryParse(valueAfter(i) ?? '');
          i++;
        case '--payload-sha256':
          payloadSha256 = valueAfter(i);
          i++;
        case '--session-dir':
          session = valueAfter(i);
          i++;
        case '--protected-session':
          protectedSession = valueAfter(i);
          i++;
        case '--resume-options':
          resume = valueAfter(i);
          i++;
        case '--silent':
        case '/silent':
        case '/S':
          silent = true;
        case '--elevated':
          elevated = true;
        case '--auto-start':
          autoStart = true;
        case '--auto-uninstall':
          autoUninstall = true;
          mode = SetupMode.uninstall;
        case '--keep-data':
          keepData = true;
        case '--no-keep-data':
          keepData = false;
      }
    }
    return SetupArgs(
      mode: mode,
      setupExe: setupExe,
      payloadOff: off,
      payloadLen: len,
      payloadSha256: payloadSha256,
      sessionDir: session,
      protectedSession: protectedSession,
      silent: silent,
      elevated: elevated,
      resumeOptions: resume,
      autoStart: autoStart,
      autoUninstall: autoUninstall,
      keepData: keepData,
    );
  }
}
