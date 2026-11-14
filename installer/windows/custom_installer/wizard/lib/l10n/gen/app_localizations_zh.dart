// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get appTitle => 'AuraDSP 安装程序';

  @override
  String get welcomeTitle => '欢迎使用 AuraDSP';

  @override
  String get welcomeBody => '跨平台全局音频效果系统：实时 DSP 效果链、插件托管与虚拟音频设备，覆盖整个系统的声音。';

  @override
  String get licenseAgree => '我已阅读并同意许可协议（GPL-3.0 / 随包组件许可）';

  @override
  String get quickInstall => '立即安装';

  @override
  String get quickUpdate => '立即更新';

  @override
  String get customInstall => '自定义安装';

  @override
  String get optionsTitle => '安装选项';

  @override
  String get installDirLabel => '安装位置';

  @override
  String get dirAutoAppendHint =>
      '末段不是 AuraDSP 时会自动补上，例如 D:\\Games → D:\\Games\\AuraDSP';

  @override
  String get updateDirLocked => '覆盖安装沿用原目录，保留设置与数据。';

  @override
  String get driverGroupTitle => '驱动（可选，默认安装）';

  @override
  String get driverOptionalHint => '取消勾选只跳过自动安装；驱动文件与手动安装脚本仍会保留在安装目录。';

  @override
  String get compAsio => 'AuraASIO 驱动（在 DAW 中暴露 AuraDSP）';

  @override
  String get compVaio => 'AuraVAIO 虚拟音频设备驱动';

  @override
  String get compDdc => '预装精选耳机/音箱 DDC 校准文件';

  @override
  String get allUsers => '为所有用户安装（需要管理员权限）';

  @override
  String get scDesktop => '桌面快捷方式';

  @override
  String get scStartMenu => '开始菜单程序组';

  @override
  String get scAutostart => '开机自启动';

  @override
  String get needsElevation => '该选择需要管理员权限，向导将请求 Windows 提权后继续。';

  @override
  String get signWarnTitle => 'AuraVAIO 为测试签名驱动';

  @override
  String get signWarnShort =>
      '64 位 Windows 默认拒绝加载测试签名驱动；未开启测试签名模式时驱动无法使用（应用本体不受影响）。';

  @override
  String get signGuideTitle => '驱动签名设置说明';

  @override
  String get signGuideBody =>
      'AuraVAIO 使用自签名测试证书，不是微软正式签名（Attestation/EV）。\n\n【适用系统】所有 64 位 Windows（Win7 / 8.1 / 10 / 11）默认都拒绝加载测试签名驱动；只有 32 位系统基本不强制。Windows 11 只是额外多了 Secure Boot 与内存完整性等门槛，并非「Win10 以下不受影响」。\n\n【方案 A · 持久（推荐）】\n1. 以管理员身份打开命令提示符，执行：bcdedit /set testsigning on\n2. 重启电脑。桌面右下角出现「测试模式」水印属正常。\n3. 若提示「该值受 Secure Boot 策略保护」：进 BIOS 关闭 Secure Boot（BitLocker 需先暂停）。\n4. Win11 若仍失败：Windows 安全中心 → 设备安全性 → 核心隔离 → 关闭「内存完整性」后重启。\n5. 以管理员身份运行 安装目录\\driver\\install_vaio.ps1 -Action install\n恢复：bcdedit /set testsigning off 后重启。\n\n【方案 B · 临时（仅本次开机有效）】\n设置 → 系统 → 恢复 → 高级启动「立即重新启动」→ 疑难解答 → 高级选项 → 启动设置 → 重启 → 按 7 或 F7「禁用驱动程序签名强制」。下次重启自动失效，仅适合临时验证。\n\nAuraASIO 是用户态 COM 组件，不需要以上步骤。完整说明见 安装目录\\driver\\README.txt。';

  @override
  String get signViewGuide => '查看设置教程';

  @override
  String get openDriverReadme => '打开驱动说明文件';

  @override
  String get manualDriverHint => '安装目录 driver\\ 内保留驱动与手动安装脚本，可随时以管理员身份补装。';

  @override
  String updateDetected(String oldVer, String newVer) {
    return '检测到已安装 AuraDSP v$oldVer，将更新到 v$newVer（保留设置与数据）。';
  }

  @override
  String updateRepair(String ver) {
    return '检测到同版本 v$ver，将执行修复 / 重装（保留设置与数据）。';
  }

  @override
  String updateDowngrade(String oldVer, String newVer) {
    return '当前已安装 v$oldVer，高于本安装包 v$newVer。请先卸载旧版本再安装。';
  }

  @override
  String get blockedHint => '为避免配置不兼容，向导不会自动降级。';

  @override
  String updateFrom(String oldVer, String newVer) {
    return '已从 v$oldVer 更新到 v$newVer';
  }

  @override
  String get finishUpdatedTitle => '更新完成';

  @override
  String get awaitingElevation => '正在等待 Windows 管理员授权…请在 UAC 弹窗中点击「是」。';

  @override
  String get elevDeniedTitle => '未获得管理员权限';

  @override
  String get elevDeniedBody =>
      '授权请求被取消或拒绝。可以重新授权，或以当前权限继续安装（虚拟声卡驱动与全用户安装将被跳过）。';

  @override
  String get elevUninstallDeniedBody =>
      '授权请求被取消或拒绝。继续卸载会跳过驱动、设备与系统注册项清理，可能留下残留；建议重新授权。';

  @override
  String get elevRetry => '重新授权';

  @override
  String get elevContinue => '仍要继续';

  @override
  String get elevCancel => '返回';

  @override
  String get finishDesktopShortcut => '创建桌面快捷方式';

  @override
  String get back => '返回';

  @override
  String get startInstall => '开始安装';

  @override
  String get progressTitle => '正在安装…';

  @override
  String get stepGuard => '检查运行中进程';

  @override
  String get stepBackup => '备份旧版本文件';

  @override
  String get stepRestore => '恢复旧版本';

  @override
  String get stepExtract => '解压文件';

  @override
  String get stepAsio => '注册 ASIO 驱动';

  @override
  String get stepDriver => '安装虚拟音频驱动';

  @override
  String get stepShortcuts => '创建快捷方式';

  @override
  String get stepRegistry => '写入系统注册';

  @override
  String get stepUninstaller => '准备卸载器';

  @override
  String get stepCleanup => '移除文件';

  @override
  String get stepDone => '完成';

  @override
  String get finishTitle => '安装完成';

  @override
  String get warningsTitle => '已完成，附带说明：';

  @override
  String get launchApp => '立即启动 AuraDSP';

  @override
  String get openSound => '打开 Windows 声音设置';

  @override
  String get done => '完成';

  @override
  String get errorTitle => '出现问题';

  @override
  String get errorBody => '操作失败，已尽可能回滚已完成的步骤。详情：';

  @override
  String get close => '关闭';

  @override
  String get uninstallTitle => '卸载 AuraDSP';

  @override
  String get uninstallBody => '将从这台设备移除 AuraDSP 及其组件。';

  @override
  String get uninstallProgressTitle => '正在卸载…';

  @override
  String get uninstalledTitle => '卸载完成';

  @override
  String get startUninstall => '卸载';

  @override
  String get keepData => '保留我的配置、预设与校准数据';

  @override
  String get keepDataHint =>
      '将保留 %APPDATA%\\AuraDSP（配置 / 预设 / 校准 / 会话）与安装目录内你自己添加的文件；驱动、注册表项、快捷方式仍会清理。';

  @override
  String get uninstallDeleteAllHint => '将同时删除上述用户数据，且不可恢复。';

  @override
  String get uninstallKeptTitle => '已保留的用户数据：';

  @override
  String get uninstallCleanNote => '程序文件、驱动、注册表项与快捷方式已清理。';

  @override
  String get fileErrorTitle => '写入文件失败';

  @override
  String fileErrorBody(String path) {
    return '安装程序无法写入以下文件：\n$path\n\n错误详情（原文）：';
  }

  @override
  String get fileErrorCriticalNote =>
      '这是关键文件，不能跳过。请处理占用或权限问题后重试，或取消安装（将回滚已完成的部分）。';

  @override
  String get fileErrorRetry => '重试';

  @override
  String get fileErrorSkip => '跳过';

  @override
  String get fileErrorCancel => '取消安装';
}
