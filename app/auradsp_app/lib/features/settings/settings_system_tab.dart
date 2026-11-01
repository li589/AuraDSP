part of '../settings_page.dart';

/*
 * settings_system_tab.dart — 系统设置页
 * 包含：引擎信息、持久化记忆与配置管理、系统服务（托盘常驻与开机自启动）
 */

List<Widget> buildSystemTab(BuildContext context, AppModel model) {
  final l = l10nOf(context);
  final p = paletteOf(context);

  return [
    // 1. 引擎信息
    SectionCard(
      title: l.engineInfo,
      child: _EngineInfo(model: model),
    ),

    // 2. 持久化记忆与外置配置
    SectionCard(
      title: l.memTitle,
      hint: l.memHint,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(l.memAutoRestore, style: labelOf(p)),
              AuraSwitch(
                value: model.config.autoRestoreSession,
                onChanged: model.setAutoRestoreSession,
              ),
            ],
          ),
          const SizedBox(height: AuraSpace.sm),
          Text(
            l.memDir(ConfigManager.baseDir),
            style: monoOf(p, size: 10, color: p.textDim),
          ),
          // S5b：Linux 上数据根与配置根分离（XDG），一并展示；同根时不重复。
          if (ConfigManager.dataDir != ConfigManager.baseDir) ...[
            const SizedBox(height: 2),
            Text(
              l.memDataDir(ConfigManager.dataDir),
              style: monoOf(p, size: 10, color: p.textDim),
            ),
          ],
          const SizedBox(height: AuraSpace.sm),
          Row(
            children: [
              AuraChip(
                l.memClear,
                icon: Icons.delete_outline_rounded,
                onTap: () {
                  SessionMemory.clear();
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text(l.memCleared),
                    duration: const Duration(milliseconds: 1400),
                  ));
                },
              ),
              const SizedBox(width: AuraSpace.sm),
              AuraChip(
                l.memReset,
                icon: Icons.restore_rounded,
                onTap: () {
                  model.resetConfig();
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text(l.memResetDone),
                    duration: const Duration(milliseconds: 1400),
                  ));
                },
              ),
            ],
          ),
        ],
      ),
    ),

    // 3. 系统（托盘常驻 + 开机自启；Windows 系统集成）
    SectionCard(
      title: l.sysTitle,
      hint: l.sysHint,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(l.sysTray, style: labelOf(p, size: 12)),
              const AuraSwitch(
                value: true,
                onChanged: null, // 常驻行为；托盘不可用时整卡隐藏
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(l.sysTrayHint, style: captionOf(p)),
          const SizedBox(height: AuraSpace.md),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(l.sysAutostart, style: labelOf(p, size: 12)),
              AuraSwitch(
                value: PlatformAdapters.instance.autoStart.enabled ?? false,
                onChanged: (v) =>
                    PlatformAdapters.instance.autoStart.setEnabled(v),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(l.sysAutostartHint, style: captionOf(p)),
        ],
      ),
    ),
  ];
}
