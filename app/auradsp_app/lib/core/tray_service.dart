/*
 * tray_service.dart — 系统托盘 / 关窗→托盘 / 开机自启 统一服务
 *
 * 职责（Windows 桌面集成，基于 window_manager + tray_manager(nativeapi)）：
 *   1. 托盘图标 + 工具提示（assets/tray_icon.ico，多尺寸 16/32/48）
 *   2. 关窗→托盘：setPreventClose 拦截 WM_CLOSE，隐藏窗口而非退出（音乐继续）
 *   3. 托盘交互：左键单击恢复窗口；右键菜单（显示主窗口 / 开机自启开关 / 退出）
 *   4. 开机自启：HKCU Run（nativeapi.launchAtLogin），设置页与托盘菜单可读可写
 *
 * 用法：main() 里 `await TrayService.instance.init()`（engine 就绪前即可；
 * 失败只置 ready=false，不抛异常、不阻塞启动——非核心路径）。
 * 退出走托盘菜单「退出」或应用内退出（dispose 移除图标并放行）。
 */
import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:nativeapi/nativeapi.dart'
    show ContextMenuTrigger, LaunchAtLogin, Menu, MenuItem, MenuItemClickedEvent,
        MenuItemState, MenuItemType, TrayIcon, TrayIconClickedEvent;
import 'package:nativeapi_flutter/nativeapi_flutter.dart' show ImageAsset;
import 'package:window_manager/window_manager.dart';

/// 开机自启（Windows = HKCU Run 键；nativeapi 的 LaunchAtLogin 常驻引用）
class AutoStartService {
  AutoStartService._();
  static final AutoStartService instance = AutoStartService._();

  LaunchAtLogin? _handle;

  /// 懒初始化原生句柄（首次查询/设置时创建，失败返回 false）。
  bool _ensure() {
    _handle ??= LaunchAtLogin.createWithIdAndDisplayName(
      'com.auradsp.app',
      'AuraDSP',
    );
    return _handle != null;
  }

  /// 当前是否已开启自启；原生不可用返回 null。
  bool? get enabled {
    if (!_ensure()) return null;
    return _handle!.isEnabled;
  }

  /// 设置自启开关；返回操作是否成功。
  bool setEnabled(bool on) {
    if (!_ensure()) return false;
    return on ? _handle!.enable() : _handle!.disable();
  }
}

/// 托盘服务（单例）
class TrayService {
  TrayService._();
  static final TrayService instance = TrayService._();

  TrayIcon? _icon;
  bool _ready = false;
  // 菜单项引用（label 是 live setter：applyLocale 运行时更新，无需重建菜单）
  MenuItem? _showItem;
  MenuItem? _autostartItem;
  MenuItem? _quitItem;
  String _curLocale = '';

  /// 是否已初始化（供 UI 判断托盘/自启可用）
  bool get ready => _ready;

  /// 初始化托盘 + 关窗拦截；任何一步失败只置 _ready=false，不抛（非核心路径）。
  Future<void> init() async {
    try {
      // 1) 窗口管理器：拦截关闭 → 隐藏到托盘
      await WindowManager.instance.ensureInitialized();
      await WindowManager.instance.setPreventClose(true);
      WindowManager.instance.addListener(_WindowCloseListener());

      // 2) 托盘图标
      final icon = TrayIcon.create();
      if (icon == null) return;
      icon.icon = ImageAsset.fromAsset('assets/tray_icon.ico');
      icon.setTooltip('AuraDSP');
      icon.setContextMenuTrigger(ContextMenuTrigger.rightClicked);

      // 3) 托盘菜单（右键）
      final menu = Menu.create()!;

      final showItem = MenuItem.createWithLabelAndType(
        'Show Main Window', MenuItemType.normal)!;
      showItem.addListener((event) {
        if (event is MenuItemClickedEvent) _showWindow();
      });
      menu.addItem(showItem);
      _showItem = showItem;
      menu.addSeparator();

      final autostartItem = MenuItem.createWithLabelAndType(
        'Launch at login', MenuItemType.checkbox)!;
      autostartItem.state = AutoStartService.instance.enabled ?? false
          ? MenuItemState.checked
          : MenuItemState.unchecked;
      autostartItem.addListener((event) {
        if (event is MenuItemClickedEvent) {
          final cur = AutoStartService.instance.enabled ?? false;
          AutoStartService.instance.setEnabled(!cur);
          // checkbox 原生不自动翻转，手动同步可见状态
          autostartItem.state = !cur
              ? MenuItemState.checked
              : MenuItemState.unchecked;
        }
      });
      menu.addItem(autostartItem);
      _autostartItem = autostartItem;
      menu.addSeparator();

      final quitItem = MenuItem.createWithLabelAndType(
        'Quit', MenuItemType.normal)!;
      quitItem.addListener((event) {
        if (event is MenuItemClickedEvent) _quitApp();
      });
      menu.addItem(quitItem);
      _quitItem = quitItem;

      icon.setContextMenu(menu);
      icon.addListener((event) {
        if (event is TrayIconClickedEvent) _showWindow();
      });
      icon.setVisible(true);

      _icon = icon;
      _ready = true;
    } catch (_) {
      _ready = false;
    }
  }

  final ValueNotifier<bool> isWindowVisible = ValueNotifier<bool>(true);

  void setWindowVisible(bool visible) {
    if (isWindowVisible.value == visible) return;
    isWindowVisible.value = visible;
  }

  /// 从托盘恢复主窗口（还原最小化 + 显示 + 前台）
  Future<void> _showWindow() async {
    setWindowVisible(true);
    await WindowManager.instance.restore();
    await WindowManager.instance.show();
    await WindowManager.instance.focus();
  }

  Future<void> _quitApp() async {
    await dispose();
    await WindowManager.instance.destroy();
  }

  /// 移除托盘图标（退出时调用）
  /// 应用当前语言到托盘菜单（label live 更新；去重防无谓重建）。
  /// 由 MaterialApp.builder 在 locale 变化时调用（有 context 可取 l10n）。
  void applyLocale(String localeTag, String showText, String autostartText,
      String quitText) {
    if (localeTag == _curLocale) return;
    _curLocale = localeTag;
    _showItem?.label = showText;
    _autostartItem?.label = autostartText;
    _quitItem?.label = quitText;
  }

  Future<void> dispose() async {
    _icon?.dispose();
    _icon = null;
    _showItem = _autostartItem = _quitItem = null;
    _ready = false;
  }
}

/// 关窗拦截：setPreventClose 后用户点关闭触发 onWindowClose 而非退出，
/// 统一隐藏窗口（引擎/音乐继续后台跑）。退出走托盘菜单。
class _WindowCloseListener extends WindowListener {
  @override
  void onWindowClose() {
    WindowManager.instance.hide();
    TrayService.instance.setWindowVisible(false);
  }

  @override
  void onWindowMinimize() {
    TrayService.instance.setWindowVisible(false);
  }

  @override
  void onWindowRestore() {
    TrayService.instance.setWindowVisible(true);
  }

  @override
  void onWindowEvent(String eventName) {
    if (eventName == 'hide') {
      TrayService.instance.setWindowVisible(false);
    } else if (eventName == 'show') {
      TrayService.instance.setWindowVisible(true);
    }
  }
}
