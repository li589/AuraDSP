import 'dart:convert';

/// 安装选项（Options 页产出；可序列化以支持提权重启动协议）。
class InstallOptions {
  InstallOptions({
    required this.installDir,
    this.allUsers = false,
    this.asio = true,
    this.vaio = true,
    this.ddcPresets = true,
    this.desktopShortcut = true,
    this.startMenuShortcut = true,
    this.autostart = false,
    this.closeRunningApps = false,
  });

  String installDir;
  bool allUsers;
  bool asio;
  bool vaio;
  bool ddcPresets;
  bool desktopShortcut;
  bool startMenuShortcut;
  bool autostart;
  bool closeRunningApps;

  Map<String, dynamic> toJson() => {
        'installDir': installDir,
        'allUsers': allUsers,
        'asio': asio,
        'vaio': vaio,
        'ddcPresets': ddcPresets,
        'desktopShortcut': desktopShortcut,
        'startMenuShortcut': startMenuShortcut,
        'autostart': autostart,
        'closeRunningApps': closeRunningApps,
      };

  factory InstallOptions.fromJson(Map<String, dynamic> j) => InstallOptions(
        installDir: j['installDir'] as String,
        allUsers: j['allUsers'] as bool? ?? false,
        asio: j['asio'] as bool? ?? true,
        vaio: j['vaio'] as bool? ?? true,
        ddcPresets: j['ddcPresets'] as bool? ?? true,
        desktopShortcut: j['desktopShortcut'] as bool? ?? true,
        startMenuShortcut: j['startMenuShortcut'] as bool? ?? true,
        autostart: j['autostart'] as bool? ?? false,
        closeRunningApps: j['closeRunningApps'] as bool? ?? false,
      );
}

class ManifestFile {
  const ManifestFile({required this.path, required this.size, required this.sha256});
  final String path; // 相对安装目录，正斜杠
  final int size;
  final String sha256;

  Map<String, dynamic> toJson() => {'path': path, 'size': size, 'sha256': sha256};
  factory ManifestFile.fromJson(Map<String, dynamic> j) => ManifestFile(
        path: j['path'] as String,
        size: j['size'] as int,
        sha256: j['sha256'] as String,
      );
}

/// install_manifest.json（UninstallerEmitter 写、卸载流读）。
class InstallManifest {
  InstallManifest({
    required this.version,
    required this.fullVersion,
    required this.installDir,
    required this.allUsers,
    required this.components,
    required this.files,
    required this.shortcuts,
    required this.installedAtIso,
  });

  final String version;
  final String fullVersion;
  final String installDir;
  final bool allUsers;
  final List<String> components; // app / asio / vaio / ddc
  final List<ManifestFile> files;
  final List<String> shortcuts; // .lnk 绝对路径
  final String installedAtIso;

  int get totalBytes => files.fold(0, (a, f) => a + f.size);
  int get estimatedSizeKb => (totalBytes / 1024).ceil();

  Map<String, dynamic> toJson() => {
        'version': version,
        'fullVersion': fullVersion,
        'installDir': installDir,
        'allUsers': allUsers,
        'components': components,
        'files': files.map((f) => f.toJson()).toList(),
        'shortcuts': shortcuts,
        'installedAt': installedAtIso,
      };

  String encode() => const JsonEncoder.withIndent('  ').convert(toJson());

  factory InstallManifest.fromJson(Map<String, dynamic> j) => InstallManifest(
        version: j['version'] as String,
        fullVersion: j['fullVersion'] as String,
        installDir: j['installDir'] as String,
        allUsers: j['allUsers'] as bool? ?? false,
        components: (j['components'] as List).cast<String>(),
        files: (j['files'] as List)
            .map((e) => ManifestFile.fromJson(e as Map<String, dynamic>))
            .toList(),
        shortcuts: (j['shortcuts'] as List).cast<String>(),
        installedAtIso: j['installedAt'] as String? ?? '',
      );

  static InstallManifest decode(String text) =>
      InstallManifest.fromJson(jsonDecode(text) as Map<String, dynamic>);
}

/// 向导运行时自带清单（pack.py 写入 ZIP-W 根，向导启动时读）。
class WizardManifest {
  const WizardManifest({required this.version, required this.fullVersion, required this.payloadSha256});
  final String version;
  final String fullVersion;
  final String payloadSha256;

  factory WizardManifest.fromJson(Map<String, dynamic> j) => WizardManifest(
        version: j['version'] as String? ?? '0.0.0',
        fullVersion: j['fullVersion'] as String? ?? '',
        payloadSha256: j['payloadSha256'] as String? ?? '',
      );
}

/// 安装/卸载进度事件（引擎 → Progress 页）。
class ProgressEvent {
  const ProgressEvent(this.step, this.detail, [this.fraction]);
  final String step; // guard/extract/asio/driver/shortcuts/registry/uninstaller/cleanup
  final String detail;
  final double? fraction; // 0..1（该步内或全局，由引擎保持单调）
}

typedef ProgressSink = void Function(ProgressEvent e);

class EngineResult {
  const EngineResult({required this.ok, this.error, this.warnings = const []});
  final bool ok;
  final String? error;
  final List<String> warnings;
}
