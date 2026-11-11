// window.dart — 桌面窗口能力端口（全屏 / 可见性）。
//
// 方案：docs/10-架构/APP-目录重组与平台适配层方案-2026-11-01.md §4。
// 可见性用于 core 侧暂停高频泵（可视化/事件轮询）；实现由托盘服务提供。
import 'package:flutter/foundation.dart' show ValueListenable;

abstract interface class WindowPort {
  /// 主窗口是否可见（最小化/隐藏到托盘为 false）。
  ValueListenable<bool> get visibleListenable;

  bool get isVisible;

  /// 更新可见性状态（托盘隐藏/恢复窗口后调用；UI 指针守卫也会用）。
  void setVisible(bool visible);

  /// 是否支持真全屏切换（桌面三平台）。
  bool get supportsFullScreen;

  /// 切换全屏；不支持的平台为空操作。
  Future<void> setFullScreen(bool enabled);

  /// 从托盘恢复并聚焦主窗口；无桌面窗口的平台为空操作。
  Future<void> show();

  /// 初始化桌面窗口/托盘（移动端为空操作）。
  /// [startInTray] 为 true 时表示开机自启静默模式，启动后窗口保持隐藏在托盘。
  Future<void> init({bool startInTray = false});

  /// 关窗行为偏好（第十二轮 A1）：true = 关窗隐藏到托盘；
  /// false = 关窗直接退出。由 AppModel 在启动与设置变更时下发；
  /// 无托盘的平台可忽略。
  void setCloseToTray(bool value);

  /// 注销托盘/窗口监听。
  Future<void> dispose();

  /// 应用当前语言到托盘菜单（无托盘平台为空操作）。
  void applyLocale(
    String localeTag,
    String showText,
    String autostartText,
    String quitText,
  );
}
