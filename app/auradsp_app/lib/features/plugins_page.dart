/*
 * plugins_page.dart — AuraDSP 第三方插件中心（VST3 / CLAP 64位宿主）
 *
 * 升级功能：
 * 1. 双插槽独立架构（Slot 1 / Slot 2 并行挂载与管理）
 * 2. 原生 GUI 编辑器弹窗唤起（独立消息循环异步线程）
 * 3. VB 多总线按路插件（VB 模式总线下拉选路，打开该路插件界面逐路调节；
 *    预设存取功能已移除，各插件当前加载状态由 pluginMirror 完整保留）
 * 4. 可自定义插件检索目录（UI 配置、持久化 config.json、多目录聚合扫描）
 * 5. 全音效处理链插入阶段调整（Pre-DSP / Pre-Vendor / Post-Vendor / Post-Reverb / Post-Limiter）
 */

import 'dart:async';
import 'package:flutter/material.dart';

import '../core/design.dart';
import '../core/nav.dart';
import '../core/path_memory.dart';
import '../core/plugins/plugin_manager.dart';
import '../core/state.dart';
import '../core/theme.dart';
import '../core/ui_helpers.dart';
import '../ui/wheel_scroll.dart';
import 'chrome.dart';
import 'widgets.dart';

import '../core/error_sink.dart';
import 'plugins/plugin_scan_dirs.dart';
part 'plugins/plugins_slots.dart';
part 'plugins/plugins_hero.dart';
part 'plugins/plugins_list.dart';
part 'plugins/plugins_badges.dart';

class PluginsPage extends StatefulWidget {
  final AppModel model;
  const PluginsPage({super.key, required this.model});

  @override
  State<PluginsPage> createState() => _PluginsPageState();
}

class _PluginsPageState extends State<PluginsPage>
    with WidgetsBindingObserver {
  final TextEditingController _searchCtrl = TextEditingController();
  bool _deepScan = false;
  Timer? _statusTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _searchCtrl.text = widget.model.pluginManager.searchQuery;
    _startStatusTimer();
  }

  void _startStatusTimer() {
    _statusTimer?.cancel();
    _statusTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      // P0-1：IndexedStack 保活后本页离屏仍在树上——只在可见时轮询，
      // 否则每秒白跑 IPC + 通知（与最小化门控同一目的）。
      if (widget.model.visiblePage.value != AppPage.plugins) return;
      for (var i = 0; i < PluginManager.kMaxSlots; i++) {
        if (widget.model.pluginManager.isSlotActive(i)) {
          widget.model.pluginManager.refreshStatus(slot: i);
        }
      }
    });
  }

  // UI 争用缓解（2026-10-22）：窗口最小化/隐藏时暂停 status 轮询——
  // 用户实测「最小化 App 音频一卡一卡」，轮询的唤醒/IPC 与渲染恢复风暴
  // 叠加是可消因素；恢复可见即重启轮询。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.inactive) {
      _statusTimer?.cancel();
      _statusTimer = null;
    } else {
      if (_statusTimer == null) _startStatusTimer();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _statusTimer?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _addCustomDirDialog(BuildContext context) async {
    final l = l10nOf(context);
    final dir = await AuraPathPickerDialog.show(
      context,
      title: l.plugAddDirTitle,
      prompt: l.plugAddDirPrompt,
      mode: AuraPathPickerMode.directory,
      memorySlot: PathMemory.slotLastPluginDir,
      confirmLabel: l.plugAddScan,
    );
    if (dir != null && dir.isNotEmpty) {
      widget.model.addPluginScanDir(dir);
      widget.model.pluginManager.scan(deep: _deepScan);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return ListenableBuilder(
      listenable: widget.model,
      builder: (context, _) {
        // BUGFIX（2026-10-22）：manager/currentSlot 必须在 builder 闭包内读取。
        // 原实现把 `final currentSlot = manager.selectedSlot` 放在外层
        // State.build 作用域——ListenableBuilder 重建时只重跑 builder 闭包，
        // 而闭包捕获的是上一次外层 build 的变量绑定，currentSlot 永远冻结
        // 在初始值 0。后果：切槽后 Hero 卡始终显示槽 1 的插件（tab 高亮
        // 正常——_SlotSelectorBar 内部直接读 manager，是新鲜值）；列表
        // 「载入到槽 N」/卸载永远落到槽 0，每次挂载都把槽 1 的插件挤掉。
        // AppModel 已通过 pluginManager.addListener(notifyListeners) 转发
        // manager 通知（builder 会随 selectSlot 重建），缺的只是新鲜读取。
        final manager = widget.model.pluginManager;
        final currentSlot = manager.selectedSlot;
        return PageScaffold(
          title: l10nOf(context).plugTitle,
          children: [
            // 0. 插槽选择器（Slot 1 / Slot 2 并行管理）
            _SlotSelectorBar(
              manager: manager,
              onSelectSlot: (slot) => manager.selectSlot(slot),
            ),

          // 1. 当前选中挂载插槽 Hero 卡片
          _ActivePluginHero(
            model: widget.model,
            manager: manager,
            slot: currentSlot,
          ),

          // 2. 插件扫描目录管理（2026-10-28：多选列表 + 内置目录）
          PluginScanDirsSection(
            model: widget.model,
            onAddDir: () => _addCustomDirDialog(context),
            onRescan: () => manager.scan(deep: _deepScan),
          ),

          // 3. 插件库与扫描控制中心
          SectionCard(
            title: l10nOf(context).plugLibTitle,
            hint: l10nOf(context).plugLibHint,
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 深度扫描勾选
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Checkbox(
                      value: _deepScan,
                      onChanged: manager.isScanning
                          ? null
                          : (v) => setState(() => _deepScan = v ?? false),
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    Text(l10nOf(context).plugDeepScan, style: captionOf(p)),
                    const SizedBox(width: 6),
                    InfoBadge(message: l10nOf(context).plugScanNoVerify),
                  ],
                ),
                const SizedBox(width: AuraSpace.sm),
                // 扫描按钮
                ElevatedButton.icon(
                  onPressed: manager.isScanning
                      ? null
                      : () => manager.scan(deep: _deepScan),
                  icon: manager.isScanning
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh_rounded, size: 16),
                  label: Text(manager.isScanning ? l10nOf(context).plugScanning : l10nOf(context).plugScan),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: p.accent,
                    foregroundColor: p.accentContrast,
                    padding: const EdgeInsets.symmetric(
                        horizontal: AuraSpace.md, vertical: AuraSpace.xs),
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // C2：扫描进行中 → Android 风格水平进度条 + 进度读数
                if (manager.isScanning) ...[
                  AuraScanProgress(
                    done: manager.scanDone,
                    total: manager.scanTotal,
                  ),
                  const SizedBox(height: AuraSpace.xs),
                  Text(
                    manager.scanTotal > 0
                        ? l10nOf(context).plugScanProgressCount(
                            manager.scanDone, manager.scanTotal, manager.scanFound)
                        : l10nOf(context).plugScanPreparing,
                    style: monoOf(p, size: 11, color: p.textDim),
                  ),
                  const SizedBox(height: AuraSpace.sm),
                ],
                // 搜索栏与分类药丸
                Row(
                  children: [
                    // 搜索输入框
                    Expanded(
                      child: Container(
                        height: 38,
                        decoration: BoxDecoration(
                          color: p.panelRaised,
                          borderRadius: BorderRadius.circular(AuraRadius.sm),
                          border: Border.all(color: p.hairline),
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        child: Row(
                          children: [
                            Icon(Icons.search_rounded, size: 18, color: p.textDim),
                            const SizedBox(width: 8),
                            Expanded(
                              child: TextField(
                                controller: _searchCtrl,
                                style: labelOf(p),
                                decoration: InputDecoration(
                                  hintText: l10nOf(context).plugSearchHint,
                                  hintStyle: captionOf(p),
                                  border: InputBorder.none,
                                  isDense: true,
                                  contentPadding: EdgeInsets.zero,
                                ),
                                onChanged: (val) => manager.setSearchQuery(val),
                              ),
                            ),
                            if (_searchCtrl.text.isNotEmpty)
                              GestureDetector(
                                onTap: () {
                                  _searchCtrl.clear();
                                  manager.setSearchQuery('');
                                },
                                child: Icon(Icons.clear_rounded,
                                    size: 16, color: p.textDim),
                              ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: AuraSpace.md),
                    // 格式药丸 Filter —— 窄窗口下允许横向滚动，避免挤压搜索框
                    // 或撑破整行（2026-10-28 窄宽度回归）。
                    Flexible(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: _FilterPills(
                          selected: manager.filterFormat,
                          countAll: manager.countAll,
                          countVst3: manager.countVst3,
                          countClap: manager.countClap,
                          countVst2: manager.countVst2,
                          countAu: manager.countAu,
                          countLv2: manager.countLv2,
                          onSelect: (fmt) => manager.setFilterFormat(fmt),
                        ),
                      ),
                    ),
                  ],
                ),

                if (manager.lastError != null) ...[
                  const SizedBox(height: AuraSpace.sm),
                  Container(
                    padding: const EdgeInsets.all(AuraSpace.sm),
                    decoration: BoxDecoration(
                      color: p.error.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(AuraRadius.sm),
                      border: Border.all(color: p.error.withValues(alpha: 0.3)),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.error_outline_rounded,
                            size: 16, color: p.error),
                        const SizedBox(width: AuraSpace.sm),
                        Expanded(
                          child: Text(manager.lastError!,
                              style: captionOf(p, color: p.error)),
                        ),
                      ],
                    ),
                  ),
                ],

                if (manager.lastNotice != null) ...[
                  const SizedBox(height: AuraSpace.sm),
                  Container(
                    padding: const EdgeInsets.all(AuraSpace.sm),
                    decoration: BoxDecoration(
                      color: p.warning.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(AuraRadius.sm),
                      border: Border.all(color: p.warning.withValues(alpha: 0.35)),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.warning_amber_rounded,
                            size: 16, color: p.warning),
                        const SizedBox(width: AuraSpace.sm),
                        Expanded(
                          child: Text(manager.lastNotice!,
                              style: captionOf(p, color: p.warning)),
                        ),
                        IconButton(
                          onPressed: manager.clearNotice,
                          icon: Icon(Icons.close_rounded,
                              size: 14, color: p.warning),
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                              minWidth: 24, minHeight: 24),
                        ),
                      ],
                    ),
                  ),
                ],

                const SizedBox(height: AuraSpace.md),

                // 插件列表内容（支持加载到当前选中插槽）
                _PluginListView(
                  manager: manager,
                  slot: currentSlot,
                  onLoad: (plugin) => manager.loadPlugin(plugin, slot: currentSlot),
                  onUnload: () => manager.unloadPlugin(slot: currentSlot),
                ),
              ],
            ),
          ),

          // 4. 宿主架构与规范说明
          SectionCard(
            title: l10nOf(context).plugM1Title,
            hint: l10nOf(context).plugM1Hint,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: AuraSpace.md,
                  runSpacing: AuraSpace.sm,
                  children: [
                    _FeatureBadge(
                      icon: Icons.check_circle_rounded,
                      label: l10nOf(context).plugFeatSlots,
                      color: p.success,
                    ),
                    _FeatureBadge(
                      icon: Icons.check_circle_rounded,
                      label: l10nOf(context).plugFeatStages,
                      color: p.success,
                    ),
                    _FeatureBadge(
                      icon: Icons.check_circle_rounded,
                      label: l10nOf(context).plugFeatGui,
                      color: p.success,
                    ),
                    _FeatureBadge(
                      icon: Icons.route_rounded,
                      label: l10nOf(context).plugFeatRoute,
                      color: p.success,
                    ),
                    _FeatureBadge(
                      icon: Icons.check_circle_rounded,
                      label: l10nOf(context).plugFeatDirs,
                      color: p.success,
                    ),
                    _FeatureBadge(
                      icon: Icons.check_circle_rounded,
                      label: l10nOf(context).plugFeatRt,
                      color: p.success,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
        );
      },
    );
  }
}
