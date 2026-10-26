part of '../settings_page.dart';

/*
 * settings_test_tab.dart — 测试工具页
 * 包含：测试音频源（440Hz 正弦波、粉红噪声、测试音频文件注入与播放控制）
 */

List<Widget> buildTestTab(BuildContext context, AppModel model) {
  final l = l10nOf(context);

  return [
    // 1. 测试音频源（测量用信号源与测试注入，停止后回到主源）
    SectionCard(
      title: l.testSrcTitle,
      hint: l.testSrcHint,
      child: _TestSourceChips(model: model),
    ),
  ];
}
