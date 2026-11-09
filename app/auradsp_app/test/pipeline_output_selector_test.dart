// pipeline_output_selector_test.dart — 管线输出分段控件落位回归
// （vm-win10 真机报告 2026-11-09 §2.1）。
//
// 根因：setAudioMode 按引擎模式反向覆写 config.pipelineOutput，
// 而映射多对一（WASAPI/VAIO 输出都合成 vaio 模式）——ASIO→WASAPI
// 时选择被 vaio 覆写拖回中间项（VAIO），需第二次点击才落位。
// 修复口径收敛在纯函数 AudioModes.pipelineOutputForMode（非损
// 覆写），本文件钉死其落位矩阵。
//
// 为何不走 AppModel 级用例：setAudioMode 先经 AudioModes
// .normalize 的 OS 归一化——Linux CI 上 'asio'/'vaio' 不是合法
// 模式 id（Linux 三模式为 system/virtual/driver），会被回退为
// 平台默认，Windows 管线语义在 Linux 测试宿主上根本不可达
// （首版用例正因此在 J6 全灭）。helper 是该口径的可测接缝。
import 'package:auradsp_app/core/audio_modes.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('管线输出选择落位（2026-11-09）', () {
    test('切入 asio 模式：任何现选都纠正为 ASIO 输出', () {
      expect(
        AudioModes.pipelineOutputForMode('asio', AudioModes.outputWasapi),
        AudioModes.outputAsioClient,
      );
      expect(
        AudioModes.pipelineOutputForMode('asio', AudioModes.outputVaio),
        AudioModes.outputAsioClient,
      );
      expect(
        AudioModes.pipelineOutputForMode(
            'asio', AudioModes.outputAsioClient),
        AudioModes.outputAsioClient,
      );
    });

    test('vaio 模式：WASAPI 输出保持落位（不被拖回中间项）', () {
      expect(
        AudioModes.pipelineOutputForMode('vaio', AudioModes.outputWasapi),
        AudioModes.outputWasapi,
      );
    });

    test('vaio 模式：VAIO 输出保持落位', () {
      expect(
        AudioModes.pipelineOutputForMode('vaio', AudioModes.outputVaio),
        AudioModes.outputVaio,
      );
    });

    test('vaio 模式：残留 ASIO 选择降为 VAIO（唯一允许的纠正）', () {
      expect(
        AudioModes.pipelineOutputForMode(
            'vaio', AudioModes.outputAsioClient),
        AudioModes.outputVaio,
      );
    });

    test('其余模式：回落 WASAPI 输出（历史口径不变）', () {
      expect(
        AudioModes.pipelineOutputForMode('system', AudioModes.outputVaio),
        AudioModes.outputWasapi,
      );
    });
  });
}
