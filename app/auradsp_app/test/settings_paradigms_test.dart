// settings_paradigms_test.dart — ADR-009 音频处理范式与设置页两级面板集成测试
import 'package:auradsp_app/core/audio_modes.dart';
import 'package:auradsp_app/core/design.dart';
import 'package:auradsp_app/core/state.dart';
import 'package:auradsp_app/core/theme.dart';
import 'package:auradsp_app/features/settings_page.dart';
import 'package:auradsp_app/l10n/gen/app_localizations.dart';
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

    // 切换到普通管线模式
    model.setModeCategory(AudioModes.categoryPipeline);
    model.setPipelineInput(AudioModes.inputAsioDriver);
    model.setPipelineOutput(AudioModes.outputAsioClient);
    await tester.pumpAndSettle();

    expect(find.text('普通管线模式'), findsWidgets);
    expect(find.text('输入源'), findsOneWidget);
    expect(find.text('输出端'), findsOneWidget);

    // Virtual ASIO driver management card visible
    expect(find.text('AuraDSP 虚拟 ASIO 驱动'), findsOneWidget);
    expect(find.text('驱动状态'), findsOneWidget);
    expect(find.text('DAW 状态'), findsOneWidget);

    // External ASIO client controls visible
    expect(find.text('缓冲档'), findsOneWidget);
    expect(find.text('输出声道对'), findsOneWidget);

    // 切到 AuraVAIO 输出端：出现虚拟声卡提示与耳机监听镜像开关
    model.setPipelineOutput(AudioModes.outputVaio);
    await tester.pumpAndSettle();
    expect(find.text('提示：AuraVAIO 为虚拟声卡输出，需在 OBS 或录音软件中选择 AuraVAIO 才能听到声音。'),
        findsOneWidget);
    expect(find.text('本地耳机监听镜像'), findsOneWidget);
    expect(find.text('物理输出'), findsOneWidget);

    // 切到 WASAPI 渲染输出端
    model.setPipelineOutput(AudioModes.outputWasapi);
    await tester.pumpAndSettle();
    expect(find.text('WASAPI 物理渲染 (扬声器/耳机)'), findsWidgets);
  });
}
