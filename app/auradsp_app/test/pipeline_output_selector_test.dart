// pipeline_output_selector_test.dart — 管线输出分段控件落位回归
// （vm-win10 真机报告 2026-11-09 §2.1）。
//
// 根因：setAudioMode 按引擎模式反向覆写 config.pipelineOutput，
// 而映射多对一（WASAPI/VAIO 输出都合成 vaio 模式）——ASIO→WASAPI
// 时选择被 vaio 覆写拖回中间项（VAIO），需第二次点击才落位。
// 修复后覆写非损：vaio 模式不得改动已选的 WASAPI 输出。
import 'package:auradsp_app/core/audio_modes.dart';
import 'package:auradsp_app/core/state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('管线输出选择落位（2026-11-09）', () {
    test('ASIO → WASAPI 一次落位（不被 vaio 模式拖回中间项）', () {
      final model = AppModel(testing: true);
      addTearDown(model.dispose);
      model.setAudioMode('asio');
      expect(model.pipelineOutput, AudioModes.outputAsioClient);
      model.setPipelineOutput(AudioModes.outputWasapi);
      expect(model.audioMode, 'vaio');
      expect(model.pipelineOutput, AudioModes.outputWasapi);
    });

    test('VAIO → WASAPI 一次落位', () {
      final model = AppModel(testing: true);
      addTearDown(model.dispose);
      model.setPipelineOutput(AudioModes.outputVaio);
      expect(model.pipelineOutput, AudioModes.outputVaio);
      model.setPipelineOutput(AudioModes.outputWasapi);
      expect(model.pipelineOutput, AudioModes.outputWasapi);
    });

    test('切入 asio 模式强制 ASIO 输出；切回 vaio 时纠正残留 ASIO 选择', () {
      final model = AppModel(testing: true);
      addTearDown(model.dispose);
      model.setPipelineOutput(AudioModes.outputWasapi);
      model.setAudioMode('asio');
      expect(model.pipelineOutput, AudioModes.outputAsioClient);
      model.setAudioMode('vaio');
      expect(model.pipelineOutput, AudioModes.outputVaio);
    });

    test('WASAPI ↔ VAIO 互切保持各自落位', () {
      final model = AppModel(testing: true);
      addTearDown(model.dispose);
      model.setPipelineOutput(AudioModes.outputVaio);
      expect(model.pipelineOutput, AudioModes.outputVaio);
      model.setPipelineOutput(AudioModes.outputWasapi);
      expect(model.pipelineOutput, AudioModes.outputWasapi);
      model.setPipelineOutput(AudioModes.outputVaio);
      expect(model.pipelineOutput, AudioModes.outputVaio);
    });
  });
}
