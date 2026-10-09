/*
 * plugins_page.dart — 插件页（M1 占位）：多格式插件宿主的落位页
 *
 * 许可决策已拍板 GPLv3.0（VST3 SDK GPL 路线 + CLAP MIT 一等公民 + VST2 用
 * fst 逆向头）。本页 v1 为规划态占位：扫描/桥进程/身份合并随 M1 落地。
 */
import 'package:flutter/material.dart';

import '../core/design.dart';
import '../core/state.dart';
import 'chrome.dart';
import 'widgets.dart';

class PluginsPage extends StatelessWidget {
  final AppModel model;
  const PluginsPage({super.key, required this.model});

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return PageScaffold(
      title: '插件',
      children: [
        SectionCard(
          title: '插件宿主',
          hint: 'M1 规划：VST3（GPLv3）/ CLAP（MIT）/ VST2（fst）多格式宿主，'
              '每插件独立桥进程沙箱（崩溃自动旁路、泄漏隔离）',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                _RoadmapItem(done: false, label: '扫描器（快扫/深扫/缓存）'),
                const SizedBox(width: AuraSpace.md),
                _RoadmapItem(done: false, label: '桥进程沙箱'),
                const SizedBox(width: AuraSpace.md),
                _RoadmapItem(done: false, label: '身份合并（32/64 与 VST2/VST3）'),
              ]),
              const SizedBox(height: AuraSpace.md),
              Text(
                '许可证决策：AuraDSP APP 走 GPLv3.0 分发（libjamesdsp 同源），'
                'VST3 SDK 免签署；CLAP 为跨平台一等公民（含 Android 创新路径）。',
                style: captionOf(p),
              ),
            ],
          ),
        ),
        SectionCard(
          title: '已安装插件',
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.extension_rounded, size: 36, color: p.textDim),
                const SizedBox(height: AuraSpace.md),
                Text('扫描器随 M1 里程碑交付', style: captionOf(p)),
              ]),
            ),
          ),
        ),
      ],
    );
  }
}

class _RoadmapItem extends StatelessWidget {
  final bool done;
  final String label;
  const _RoadmapItem({required this.done, required this.label});

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(done ? Icons.check_circle_rounded : Icons.schedule_rounded,
          size: 14, color: done ? p.success : p.textDim),
      const SizedBox(width: AuraSpace.xs + 2),
      Text(label, style: labelOf(p, color: p.textDim)),
    ]);
  }
}
