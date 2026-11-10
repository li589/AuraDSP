// 第四轮项 2（用户设计规格）：管线输入/输出设备互斥——输入选了
// 哪块声卡，输出候选就剔除同一块；存量冲突在写输入时自动让位。
// 项 4 的呈现一致性只在 widget 层（pipelineChain 派生），不在此钉。
import 'package:flutter_test/flutter_test.dart';

import 'package:auradsp_app/core/state.dart';

void main() {
  group('项2 互斥：wasapiOutputsExcludingInput', () {
    AppModel modelWith(List<AudioDeviceItem> devs) {
      final m = AppModel(testing: true);
      m.wasapiDevices = devs;
      m.vaioDetectInfo = <String, dynamic>{};
      return m;
    }

    const cardA = AudioDeviceItem(id: 'a', name: 'Speakers (Card A)', isRender: true);
    const cardB = AudioDeviceItem(id: 'b', name: 'Headphones (Card B)', isRender: true);
    const mic = AudioDeviceItem(id: 'c', name: 'Mic (Card A)', isRender: false);

    test('输入选渲染端点 → 输出候选剔除同一端点', () {
      final m = modelWith([cardA, cardB, mic]);
      m.config.pipelineInput = 'wasapi';
      m.config.pipelineInputDevice = 'a';
      expect(m.wasapiOutputsExcludingInput.map((d) => d.id), ['b']);
      expect(m.inputOccupiesRenderSlot, isTrue);
    });

    test('输入为录音端点 → 不剔除（同名声卡的输出不受牵连）', () {
      final m = modelWith([cardA, cardB, mic]);
      m.config.pipelineInput = 'wasapi';
      m.config.pipelineInputDevice = 'c';
      expect(m.wasapiOutputsExcludingInput.map((d) => d.id), ['a', 'b']);
      expect(m.inputOccupiesRenderSlot, isFalse);
    });

    test('输入为默认（空）→ 具名项全保留，但占据渲染槽（widget 撤默认项）', () {
      final m = modelWith([cardA, cardB]);
      m.config.pipelineInput = 'wasapi';
      m.config.pipelineInputDevice = '';
      expect(m.wasapiOutputsExcludingInput.map((d) => d.id), ['a', 'b']);
      expect(m.inputOccupiesRenderSlot, isTrue);
    });

    test('单声卡：输入选它 → 输出候选为空（widget 呈「无可用声卡」置灰态）', () {
      final m = modelWith([cardA]);
      m.config.pipelineInput = 'wasapi';
      m.config.pipelineInputDevice = 'a';
      expect(m.wasapiOutputsExcludingInput, isEmpty);
    });
  });

  group('项2 互斥：setPipelineInputDevice 存量冲突自动让位', () {
    test('先选输出、后选同卡为输入 → 输出迁到另一块卡', () {
      final m = AppModel(testing: true);
      m.wasapiDevices = const [
        AudioDeviceItem(id: 'a', name: 'Speakers (Card A)', isRender: true),
        AudioDeviceItem(id: 'b', name: 'Headphones (Card B)', isRender: true),
      ];
      m.vaioDetectInfo = <String, dynamic>{};
      m.config.pipelineInput = 'wasapi';
      m.config.pipelineOutput = 'wasapi';
      m.config.pipelineOutputDevice = 'a';
      m.setPipelineInputDevice('a');
      expect(m.config.pipelineInputDevice, 'a');
      expect(m.config.pipelineOutputDevice, 'b');
      expect(m.pipelinePairConflicts, isFalse);
    });

    test('无处可让（单声卡）→ 保留原值，冲突由呈现层置灰+守卫兜底', () {
      final m = AppModel(testing: true);
      m.wasapiDevices = const [
        AudioDeviceItem(id: 'a', name: 'Speakers (Card A)', isRender: true),
      ];
      m.vaioDetectInfo = <String, dynamic>{};
      m.config.pipelineInput = 'wasapi';
      m.config.pipelineOutput = 'wasapi';
      m.config.pipelineOutputDevice = 'a';
      m.setPipelineInputDevice('a');
      expect(m.config.pipelineOutputDevice, 'a');
      expect(m.pipelinePairConflicts, isTrue);
    });

    test('双默认也是冲突（细审 R-A H1 口径与守卫一致）', () {
      final m = AppModel(testing: true);
      m.wasapiDevices = const [];
      m.config.pipelineInputDevice = '';
      m.config.pipelineOutputDevice = '';
      expect(m.pipelinePairConflicts, isTrue);
    });
  });
}
