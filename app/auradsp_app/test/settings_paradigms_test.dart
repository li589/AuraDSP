// settings_paradigms_test.dart — ADR-009 音频处理范式与设置页两级面板集成测试
import 'package:auradsp_app/core/audio_modes.dart';
import 'package:auradsp_app/core/design.dart';
import 'package:auradsp_app/core/state.dart';
import 'package:auradsp_app/core/theme.dart';
import 'package:auradsp_app/core/ui_helpers.dart';
import 'package:auradsp_app/features/settings_page.dart';
import 'package:auradsp_app/ui/chrome.dart';
import 'package:auradsp_app/l10n/gen/app_localizations.dart';
import 'package:auradsp_app/platform/platform_profile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app(AppModel model) => MaterialApp(
      theme: withAuraExtension(ThemeData.dark(), auraDark),
      locale: model.locale,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: Scaffold(body: SettingsPage(model: model)),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('settings_paradigms', () {
    testWidgets('ADR-009: Attachment mode renders System APO and Voicemeeter subpanels',
        (tester) async {
      final model = AppModel(testing: true);
      addTearDown(model.dispose);
      await tester.pumpWidget(_app(model));
      await tester.pumpAndSettle();

      // 默认或切到附加模式
      model.setModeCategory(AudioModes.categoryAttachment);
      model.setAttachmentMode(AudioModes.attachSysApo);
      await tester.pumpAndSettle();

      expect(find.text('附加模式'), findsWidgets);
      expect(find.text('System APO'), findsWidgets);
      expect(find.text('Voicemeeter API'), findsWidgets);
      expect(find.text('附加目标端点'), findsOneWidget);
      expect(find.text('APO 挂载状态'), findsOneWidget);
      expect(find.text('一键附加'), findsOneWidget);
      expect(find.text('一键卸载'), findsOneWidget);

      // 切到 Voicemeeter API
      model.setAttachmentMode(AudioModes.attachVoicemeeterApi);
      await tester.pumpAndSettle();
      expect(find.text('连接状态'), findsOneWidget);
    });

    testWidgets('ADR-009: Pipeline mode renders input/output selectors and specialized panels',
        (tester) async {
      final model = AppModel(testing: true);
      addTearDown(model.dispose);
      await tester.pumpWidget(_app(model));
      await tester.pumpAndSettle();

      // 切换到普通管线模式（2026-11-20 重构后管线选择器只剩
      // WASAPI/VAIO，ASIO 已升独立范式——ASIO 断言移至下方
      // ASIO 范式用例）
      model.setModeCategory(AudioModes.categoryPipeline);
      model.setPipelineInput(AudioModes.inputVaio);
      model.setPipelineOutput(AudioModes.outputVaio);
      await tester.pumpAndSettle();

      expect(find.text('普通管线模式'), findsWidgets);
      expect(find.text('输入端'), findsOneWidget);
      expect(find.text('输出端'), findsOneWidget);

      // Verify 3 layers（r44 起驱动卡改名「驱动」，原「驱动信息
      // 与控制」；本断言 r44 漏改、r45 门禁复核时补正）
      expect(find.text('驱动'), findsOneWidget);
      expect(find.text('音频输入'), findsOneWidget);
      expect(find.text('音频输出'), findsOneWidget);

      // Verify segment names
      expect(find.text('WASAPI 标准模式'), findsWidgets);
      expect(find.text('AuraVAIO 虚拟输入'), findsWidgets);
      expect(find.text('WASAPI 标准输出'), findsWidgets);
      expect(find.text('AuraVAIO 虚拟输出'), findsWidgets);

      // 切到 AuraVAIO 输出端：耳机监听镜像开关在场；虚拟声卡说明
      // 自 2026-11-14（业主裁定）起收进问号气泡——旧的常显提示
      // 文本不得再以正文出现，气泡载体 InfoBadge 须在镜像行内。
      await tester.pumpAndSettle();
      expect(find.textContaining('为虚拟声卡输出'), findsNothing);
      expect(find.text('本地耳机监听镜像'), findsOneWidget);
      // 镜像行（标签的某个 Row 祖先）子树内须同时含气泡与开关——
      // 版式为外 Row[内 Row[标签+InfoBadge], AuraSwitch] 嵌套，
      // 故按子树判定而非直子。
      var mirrorRowFound = false;
      for (final e in find
          .ancestor(
              of: find.text('本地耳机监听镜像'), matching: find.byType(Row))
          .evaluate()) {
        final row = find.byWidget(e.widget);
        final hasBadge = find
            .descendant(of: row, matching: find.byType(InfoBadge))
            .evaluate()
            .isNotEmpty;
        final hasSwitch = find
            .descendant(of: row, matching: find.byType(AuraSwitch))
            .evaluate()
            .isNotEmpty;
        if (hasBadge && hasSwitch) mirrorRowFound = true;
      }
      expect(mirrorRowFound, isTrue);
      // VAIO 链下物理输出落点字段行在场。
      expect(find.text('物理输出'), findsWidgets);

      // 切到 WASAPI 渲染输出端（r58 文案：模式行值 = WASAPI 标准输出）
      model.setPipelineOutput(AudioModes.outputWasapi);
      await tester.pumpAndSettle();
      expect(find.text('WASAPI 标准输出'), findsWidgets);
    });

    testWidgets('ASIO paradigm: flavor switch card replaces in/out selectors',
        (tester) async {
      final model = AppModel(testing: true);
      addTearDown(model.dispose);
      await tester.pumpWidget(_app(model));
      await tester.pumpAndSettle();

      // 进入 ASIO 范式：主卡只剩子形态切换卡，无输入/输出端选择。
      model.setModeCategory(AudioModes.categoryAsio);
      await tester.pumpAndSettle();
      expect(find.text('ASIO 模式'), findsWidgets);
      expect(find.text('虚拟 ASIO'), findsWidgets);
      expect(find.text('ASIO Client'), findsWidgets);
      expect(find.text('输入端'), findsNothing);
      expect(find.text('输出端'), findsNothing);
      expect(model.pipelineChain, PipelineChain.asio);
      expect(model.asioInChain, isTrue);

      // 缺省子形态 client：ASIO Client 控制（缓冲档/输出声道对）在场。
      expect(model.asioFlavor, AudioModes.asioClient);
      expect(find.text('缓冲档'), findsOneWidget);
      expect(find.text('输出起始声道对'), findsOneWidget);
      // S2：Client 卡无输入侧行（全双工单设备，输入随驱动同体）。
      expect(find.text('输入通道'), findsNothing);

      // 切到虚拟 ASIO：驱动管理卡在场；DAW 空闲时无 DAW 状态行
      // （第三十七轮口径沿用）。
      model.setAsioFlavor(AudioModes.asioVirtual);
      await tester.pumpAndSettle();
      expect(model.asioFlavor, AudioModes.asioVirtual);
      expect(find.text('AuraDSP 虚拟 ASIO 驱动'), findsOneWidget);
      // S2：驱动状态在 I/O 面板与驱动卡各一行。
      expect(find.text('驱动状态'), findsWidgets);
      expect(find.text('DAW 状态'), findsNothing);
      // S2：虚拟形态 I/O 面板承输入通道行与驱动声道档位行
      // （档位行与驱动卡共用同一控件，两处在场）。
      expect(find.text('输入通道'), findsOneWidget);
      expect(find.text('驱动声道数'), findsWidgets);
      // S3：后端输出端点下拉在场，缺省选中「跟随系统默认」。
      expect(find.text('物理输出'), findsOneWidget);
      expect(find.text('跟随系统默认'), findsOneWidget);
      expect(model.asioRenderEndpoint, isEmpty);

      // 回普通管线：ASIO 残留对降为 VAIO（无 ASIO 选项可选）。
      model.setModeCategory(AudioModes.categoryPipeline);
      await tester.pumpAndSettle();
      expect(model.pipelineInput, AudioModes.inputVaio);
      expect(model.pipelineOutput, AudioModes.outputVaio);
      expect(find.text('输入端'), findsOneWidget);
    });
  }, skip: !PlatformProfile.isWindows ? 'ADR-009 paradigms UI is Windows only' : null);
}
