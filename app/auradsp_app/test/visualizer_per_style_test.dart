// visualizer_per_style_test.dart — 每方案可视化设置（2026-11-23 user 裁定）
//
// 语义：生效配置 = 全局为底 + 当前风格覆盖表只替换调参字段；
// 风格/歌词/MilkDrop 路径恒归全局；覆盖表随 config.json 与会话
// 记忆持久化；抽屉两档（全局/当前预设）分别写入不同存储。
import 'package:auradsp_app/core/config.dart';
import 'package:auradsp_app/core/state.dart';
import 'package:auradsp_app/core/visualizer_types.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('每方案可视化设置', () {
    test('无覆盖时生效值即全局', () {
      final m = AppModel(testing: true);
      m.setVisualizerConfig(
        const VisualizerConfig().copyWith(sensitivity: 1.4),
      );
      expect(m.visualizerConfig.value.sensitivity, 1.4);
      expect(m.visualizerHasStyleOverride, isFalse);
    });

    test('覆盖只替换调参字段，歌词与 MilkDrop 路径恒归全局', () {
      final m = AppModel(testing: true);
      m.setVisualizerConfig(
        const VisualizerConfig().copyWith(
          showLyrics: true,
          milkdropPresetPath: 'D:/presets/a.milk',
        ),
      );
      m.setVisualizerStyleOverride(
        m.visualizerConfig.value.copyWith(
          sensitivity: 2.2,
          showLyrics: false,
          milkdropPresetPath: 'D:/presets/b.milk',
        ),
      );
      final eff = m.visualizerConfig.value;
      expect(eff.sensitivity, 2.2); // 调参字段被覆盖
      expect(eff.showLyrics, isTrue); // 全局域不被覆盖快照带走
      expect(eff.milkdropPresetPath, 'D:/presets/a.milk');
      expect(m.visualizerHasStyleOverride, isTrue);
      // 全局本身的调参字段未被覆盖写入污染
      expect(m.config.visualizerConfig.sensitivity, 1.0);
    });

    test('覆盖里改全局域字段会同步落全局', () {
      final m = AppModel(testing: true);
      m.setVisualizerStyleOverride(
        m.visualizerConfig.value.copyWith(
          milkdropPresetPath: 'D:/presets/c.milk',
        ),
      );
      expect(m.config.visualizerConfig.milkdropPresetPath,
          'D:/presets/c.milk');
      expect(m.visualizerConfig.value.milkdropPresetPath,
          'D:/presets/c.milk');
    });

    test('切换风格后各自覆盖互不影响，清除覆盖回全局', () {
      final m = AppModel(testing: true);
      m.setVisualizerStyleOverride(
        m.visualizerConfig.value.copyWith(gravity: 3.0),
      ); // bars 覆盖
      m.setVisualizerConfig(
        m.config.visualizerConfig
            .copyWith(style: VisualizerStyle.oscilloscope),
      );
      expect(m.visualizerConfig.value.gravity, 1.8); // 示波器无覆盖
      m.setVisualizerStyleOverride(
        m.visualizerConfig.value.copyWith(gravity: 0.9),
      );
      m.setVisualizerConfig(
        m.config.visualizerConfig.copyWith(style: VisualizerStyle.bars),
      );
      expect(m.visualizerConfig.value.gravity, 3.0); // bars 覆盖还在
      m.clearVisualizerStyleOverride();
      expect(m.visualizerConfig.value.gravity, 1.8);
      expect(m.visualizerHasStyleOverride, isFalse);
    });

    test('覆盖表随 config JSON 往返不丢', () {
      final cfg = AppConfig(
        visualizerPerStyle: {
          'bars': const VisualizerConfig().copyWith(bloom: 0.9),
          'tornado': const VisualizerConfig().copyWith(barCount: 64),
        },
      );
      final json = cfg.toJson();
      final back = AppConfig.fromJson(json);
      expect(back.visualizerPerStyle.length, 2);
      expect(back.visualizerPerStyle['bars']!.bloom, 0.9);
      expect(back.visualizerPerStyle['tornado']!.barCount, 64);
    });

    test('脏覆盖表条目逐条跳过不丢整表', () {
      final cfg = AppConfig.fromJson({
        'visualizer': {
          'style': 'bars',
          'perStyle': {
            'bars': {'bloom': 0.7},
            'broken': 42,
          },
        },
      });
      expect(cfg.visualizerPerStyle.length, 1);
      expect(cfg.visualizerPerStyle['bars']!.bloom, 0.7);
    });
  });
}
