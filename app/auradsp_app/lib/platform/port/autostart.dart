// autostart.dart — 开机自启端口。
//
// 方案：docs/10-架构/APP-目录重组与平台适配层方案-2026-11-01.md §7。
// Windows 实现 = HKCU Run（WindowsRegistry，带 --tray 命令行参数）；
// Linux 实现 = XDG autostart .desktop（platform/autostart/autostart_linux.dart，带 --tray，S5b）；其它平台 available=false。
import 'package:flutter/foundation.dart' show ValueListenable;

abstract interface class AutoStartPort {
  /// 当前平台是否支持开机自启。
  bool get available;

  /// 当前是否已开启；不可用或读取失败返回 null。
  bool? get enabled;

  /// 开关状态可监听对象（供 UI 与托盘菜单双向响应）。
  ValueListenable<bool> get enabledListenable;

  /// 设置开关；返回操作是否成功。
  bool setEnabled(bool on);
}
