/// 命令行参数（引导壳透传 + 追加，设计 §2/§3）。
///
/// 纯逻辑、无平台依赖，可单测。
library;

enum SetupMode { install, uninstall }

class SetupArgs {
  const SetupArgs({
    required this.mode,
    this.setupExe,
    this.payloadOff,
    this.payloadLen,
    this.sessionDir,
    this.silent = false,
    this.elevated = false,
    this.resumeOptions,
  });

  final SetupMode mode;

  /// Setup 单体 exe 自身路径（卸载模式下即安装目录内的 uninstall.exe）。
  final String? setupExe;

  /// ZIP-P 在 setupExe 内的偏移/长度（引导壳实测尾块后追加）。
  final int? payloadOff;
  final int? payloadLen;

  /// 引导壳的临时会话目录（向导退出时自清理）。
  final String? sessionDir;

  /// /silent 或 --silent：无交互直跑（QuietUninstallString 用）。
  final bool silent;

  /// 经提权协议重启（信息性；真实提权态以令牌检查为准）。
  final bool elevated;

  /// 提权重启时携带的选项状态文件（读后即删）。
  final String? resumeOptions;

  bool get hasPayload => setupExe != null && payloadOff != null && payloadLen != null;

  static SetupArgs parse(List<String> argv) {
    var mode = SetupMode.install;
    String? setupExe;
    int? off;
    int? len;
    String? session;
    String? resume;
    var silent = false;
    var elevated = false;

    String? valueAfter(int i) =>
        i + 1 < argv.length && !argv[i + 1].startsWith('--') ? argv[i + 1] : null;

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
        case '--session-dir':
          session = valueAfter(i);
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
      }
    }
    return SetupArgs(
      mode: mode,
      setupExe: setupExe,
      payloadOff: off,
      payloadLen: len,
      sessionDir: session,
      silent: silent,
      elevated: elevated,
      resumeOptions: resume,
    );
  }
}
