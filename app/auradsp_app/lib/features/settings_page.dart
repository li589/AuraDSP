/*
 * settings_page.dart — 设置页骨架与页面路由
 *
 * 下设四类分区（外观/音频/系统/测试），底部选卡切换。
 * 4 个分类独立拆分为单独的 Dart 文件，清晰解耦：
 *  - settings_appearance_tab.dart (外观：配色、语言)
 *  - settings_audio_tab.dart      (音频：范式、设备、采样率、声道配置)
 *  - settings_system_tab.dart     (系统：引擎信息、持久化记忆、开机自启/托盘)
 *  - settings_test_tab.dart       (测试：音频测试源注入)
 *  - settings_about_tab.dart      (关于：版本、开源地址/协议、参考项目)
 */
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/app_info.dart';
import '../core/audio_modes.dart';
import '../core/config.dart';
import '../core/design.dart';
import '../core/path_memory.dart';
import '../core/session_memory.dart';
import '../core/notice.dart';
import '../core/state.dart';
import '../core/theme.dart';
import '../core/ui_helpers.dart';
import '../l10n/gen/app_localizations.dart';
import '../platform/adapters.dart';
import '../platform/platform_profile.dart';
import 'chrome.dart';
import 'widgets.dart';

// 四个分类子页
part 'settings/settings_appearance_tab.dart';
part 'settings/settings_audio_tab.dart';
part 'settings/settings_system_tab.dart';
part 'settings/settings_test_tab.dart';
part 'settings/settings_about_tab.dart';

// 驱动/面板子组件
part 'settings/panels/sections.dart';
part 'settings/panels/hardware_drivers.dart';
part 'settings/panels/hardware_io_input.dart';
part 'settings/panels/hardware_io_output.dart';
part 'settings/panels/vb_theme.dart';

class SettingsPage extends StatefulWidget {
  final AppModel model;
  const SettingsPage({super.key, required this.model});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  // 当前分类：0 外观 / 1 音频 / 2 系统 / 3 测试 / 4 关于
  int _cat = 1;

  @override
  Widget build(BuildContext context) {
    final model = widget.model;
    final l = l10nOf(context);

    return ListenableBuilder(
      listenable: model,
      builder: (_, _) {
        final List<Widget> tabContent;
        switch (_cat) {
          case 0:
            tabContent = buildAppearanceTab(context, model);
            break;
          case 1:
            tabContent = buildAudioTab(context, model);
            break;
          case 2:
            tabContent = buildSystemTab(context, model);
            break;
          case 3:
            tabContent = buildTestTab(context, model);
            break;
          case 4:
            tabContent = buildAboutTab(context, model);
            break;
          default:
            tabContent = buildAudioTab(context, model);
        }

        final shown = [...tabContent, const SizedBox(height: 84)];
        final p = paletteOf(context);
        // 切离 APO 全覆盖等待层（第三十五轮，业主裁定）：卸载在途
        // 时整页音频设置（含输入/输出设备区）一律被等待层盖住，
        // 不再只禁选模式卡——盖层本身吃掉全部触摸，下层控件既
        // 点不动也滚不动；分类栏保留可用（切走再回来盖层仍在）。
        final detachCover = _cat == 1 && model.apoDetachBlocking;

        return Stack(
          children: [
            PageScaffold(
              // 去掉“偏好”小字，仅显示页面主标题“设置”
              title: l.pageSettingsTitle,
              children: shown,
            ),
            if (detachCover)
              Positioned.fill(
                child: ColoredBox(
                  color: p.bg.withValues(alpha: 0.78),
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 32),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            width: 56,
                            height: 56,
                            child: CircularProgressIndicator(
                              strokeWidth: 5,
                              color: p.accent,
                            ),
                          ),
                          const SizedBox(height: AuraSpace.lg),
                          Text(
                            l.apoSwitchDetachTitle,
                            textAlign: TextAlign.center,
                            style:
                                labelOf(p, size: 15, color: p.text),
                          ),
                          const SizedBox(height: AuraSpace.sm),
                          Text(
                            l.apoSwitchDetachHint,
                            textAlign: TextAlign.center,
                            style:
                                labelOf(p, size: 12.5, color: p.textDim),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _CatBar(
                selected: _cat,
                labels: [
                  l.catAppearance,
                  l.catAudio,
                  l.catSystem,
                  l.catTest,
                  l.catAbout
                ],
                onChanged: (v) => setState(() => _cat = v),
              ),
            ),
          ],
        );
      },
    );
  }
}
