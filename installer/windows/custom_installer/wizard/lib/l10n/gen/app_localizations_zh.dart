// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get allUsers => '为所有用户安装（需要管理员权限）';

  @override
  String get appTitle => 'AuraDSP 安装程序';

  @override
  String get back => '返回';

  @override
  String get close => '关闭';

  @override
  String get compAsio => 'AuraASIO 驱动（在 DAW 中暴露 AuraDSP）';

  @override
  String get compDdc => '预装精选耳机/音箱 DDC 校准文件';

  @override
  String get compVaio => 'AuraVAIO 虚拟音频设备驱动';

  @override
  String get customInstall => '自定义安装';

  @override
  String get done => '完成';

  @override
  String get errorBody => '操作失败，已尽可能回滚已完成的步骤。详情：';

  @override
  String get errorTitle => '出现问题';

  @override
  String get finishTitle => '安装完成';

  @override
  String get installDirLabel => '安装位置';

  @override
  String get keepData => '保留我的预设与校准数据';

  @override
  String get launchApp => '立即启动 AuraDSP';

  @override
  String get licenseAgree => '我已阅读并同意许可协议（GPL-3.0 / 随包组件许可）';

  @override
  String get needsElevation => '该选择需要管理员权限，向导将请求 Windows 提权后继续。';

  @override
  String get openSound => '打开 Windows 声音设置';

  @override
  String get optionsTitle => '安装选项';

  @override
  String get progressTitle => '正在安装…';

  @override
  String get quickInstall => '立即安装';

  @override
  String get scAutostart => '开机自启动';

  @override
  String get scDesktop => '桌面快捷方式';

  @override
  String get scStartMenu => '开始菜单程序组';

  @override
  String get startInstall => '开始安装';

  @override
  String get startUninstall => '卸载';

  @override
  String get stepAsio => '注册 ASIO 驱动';

  @override
  String get stepCleanup => '移除文件';

  @override
  String get stepDone => '完成';

  @override
  String get stepDriver => '安装虚拟音频驱动';

  @override
  String get stepExtract => '解压文件';

  @override
  String get stepGuard => '检查运行中进程';

  @override
  String get stepRegistry => '写入系统注册';

  @override
  String get stepShortcuts => '创建快捷方式';

  @override
  String get stepUninstaller => '准备卸载器';

  @override
  String get uninstallBody => '将从这台设备移除 AuraDSP 及其组件。';

  @override
  String get uninstallProgressTitle => '正在卸载…';

  @override
  String get uninstallTitle => '卸载 AuraDSP';

  @override
  String get uninstalledTitle => '卸载完成';

  @override
  String get warningsTitle => '已完成，附带说明：';

  @override
  String get welcomeBody => '跨平台全局音频效果系统：实时 DSP 效果链、插件托管与虚拟音频设备，覆盖整个系统的声音。';

  @override
  String get welcomeTitle => '欢迎使用 AuraDSP';
}
