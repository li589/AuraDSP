// autostart.dart — 开机自启端口。
//
// 方案：docs/10-架构/APP-目录重组与平台适配层方案-2026-11-01.md §7。
// Windows 实现 = HKCU Run（nativeapi.launchAtLogin）；Linux 实现 = XDG autostart .desktop（platform/autostart/autostart_linux.dart，S5b）；其它平台 available=false。
abstract interface class AutoStartPort {
  /// 当前平台是否支持开机自启。
  bool get available;

  /// 当前是否已开启；不可用或读取失败返回 null。
  bool? get enabled;

  /// 设置开关；返回操作是否成功。
  bool setEnabled(bool on);
}
