/*
 * chain_page.dart — 处理链主页面（按 UI 模块拆分重构）：
 * 1. 处理链频响测量（ChainSpectrumAnalyzer）：全链路复合传递函数解析、多声道联动、EqualizerAPO 风格
 * 2. 处理顺序（ChainOrderCard）：元素可拖拽重排、自动应用、条件恢复默认、双声道微型电平表、科幻全景面板内嵌
 * 3. 第三方插件挂载顺序（ChainPluginSlotsCard）：四槽位独立管理、阶段插入调整、PDC 延迟补偿
 */

import 'package:flutter/material.dart';

import '../core/effect_registry.dart';
import '../core/state.dart';
import '../core/ui_helpers.dart';
import '../l10n/gen/app_localizations.dart';
import 'chrome.dart';
import 'chain/chain_order_card.dart';
import 'chain/chain_plugin_slots_card.dart';
import 'chain/chain_spectrum_analyzer.dart';

// 链序/阶段元数据唯一事实源在 core/effect_registry.dart；此处保留导出，
// 避免既有调用方（chain_order_card、测试）改动导入路径。
export '../core/effect_registry.dart'
    show kStageMeta, kDefaultCoreOrder, kChainGroups;

/// stage id → 展示名（l10n；与效果器卡片名称严格对齐；未知 id 回退原文）。
String stageLabelOf(AppLocalizations l, String id) => switch (id) {
      'gate' => l.stGate,
      'dyneq' => l.dyneqTitle,
      'filter' => l.stFilter,
      'bass_shaping' => l.bassShapingTitle,
      'bassmono' => l.bassMonoModule,
      'shelf' => l.bassShelfModule,
      'tube' => l.tubeTitle,
      'comp' => l.compTitle,
      'bass' => l.bassBoost,
      'eq' => l.eqMultiBand,
      'arbmag' => l.stArbmag,
      'convolver' => l.convTitle,
      'ddc' => l.ddcTitle,
      'liveprog' => l.stScript,
      'crossfeed' => l.crossfeedTitle,
      'stereo' => l.stereoWiden,
      'haas' => l.stHaas,
      'spatial' => l.spatialTitle,
      'exciter' => l.stExciter,
      'loudness' => l.stLoudness,
      'reverb' => l.spatialReverbTitle,
      'output' => l.postGain,
      _ => id,
    };

/// 链组 id → 展示名（l10n）。
String chainGroupLabelOf(AppLocalizations l, String g) => switch (g) {
      'chInput' => l.chainGrpInput,
      'chTone' => l.chainGrpTone,
      'chEq' => l.chainGrpEqScript,
      'chSound' => l.chainGrpSound,
      'chSpatial' => l.chainGrpSpatial,
      'chOut' => l.chainGrpOut,
      _ => g,
    };

/// stage → 组逆查（未知 id 归入上一组，防御未来新增 stage）。
final Map<String, String> _stageToGroup = {
  for (final e in kChainGroups.entries)
    for (final id in e.value) id: e.key,
};

/// stage id → 分类展示名（方框徽标用，随中英文切换）。
String stageCategoryLabelOf(BuildContext ctx, String id) {
  final l = l10nOf(ctx);
  // 立体声专用卡片（crossfeed, stereo, haas, convolver, ddc）：徽标标签统一改为“立体声”
  if (id == 'crossfeed' || id == 'stereo' || id == 'haas' || id == 'convolver' || id == 'ddc') {
    return l.catStereo;
  }
  final g = _stageToGroup[id];
  return switch (g) {
    'chInput' => l.catInput,
    'chTone' => l.catTone,
    'chEq' => l.catEq,
    'chSound' => l.catStage,
    'chSpatial' => l.catSpace,
    'chOut' => l.catOutput,
    _ => l.catEffect,
  };
}

/// 处理链主页面
class ChainPage extends StatelessWidget {
  final AppModel model;
  const ChainPage({super.key, required this.model});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: model,
      builder: (context, _) => PageScaffold(
        title: l10nOf(context).chainTitle,
        children: [
          // 1. 卡片一：「处理链频响测量」（EqualizerAPO 风格全流程复合频响测量）
          ChainSpectrumAnalyzer(model: model),

          // 2. 卡片二：「处理顺序」（拖拽自动应用、智能重置、全 19 级电平、内嵌科幻流全景）
          ChainOrderCard(model: model),

          // 3. 卡片三：「第三方插件挂载顺序」（4 槽位管理、灵活阶段插入、PDC）
          ChainPluginSlotsCard(model: model),
        ],
      ),
    );
  }
}
