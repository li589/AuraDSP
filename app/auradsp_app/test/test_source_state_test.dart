import 'package:auradsp_app/core/state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('测试源状态（第四十四轮 S4）', () {
    test('文件路径跨源保留：切波形不卸载、切回续播', () {
      final m = AppModel(testing: true);
      m.setSource('file', path: '/x/a.wav');
      expect(m.sourceKind, 'file');
      expect(m.sourcePath, '/x/a.wav');
      expect(m.sourceExt, 'wav');
      m.setSource('tone');
      expect(m.sourceKind, 'tone');
      expect(m.sourcePath, '/x/a.wav', reason: '已选文件保留');
      m.toggleFilePlay();
      expect(m.sourceKind, 'file', reason: '以保留路径重新起播');
    });

    test('波形与文件互斥：任一起播替换当前源', () {
      final m = AppModel(testing: true);
      m.setSource('file', path: '/x/b.mp3');
      m.toggleWave();
      expect(m.waveActive, isTrue);
      expect(m.sourceKind, 'tone');
      m.toggleWave();
      expect(m.sourceKind, '', reason: '再按停波形');
      expect(m.sourcePath, '/x/b.mp3', reason: '停后文件仍保留');
    });

    test('波形类别切换：粉噪↔tone 整源重发、tone 内换形保 kind', () {
      final m = AppModel(testing: true);
      m.setWaveShape('sine');
      m.toggleWave();
      expect(m.sourceKind, 'tone');
      m.setWaveShape('pink');
      expect(m.sourceKind, 'pink');
      expect(m.waveShape, 'pink');
      m.setWaveShape('square');
      expect(m.sourceKind, 'tone');
      expect(m.waveShape, 'square');
      m.setWaveShape('triangle');
      expect(m.sourceKind, 'tone', reason: 'tone 内换形不重发整源');
      expect(m.waveShape, 'triangle');
    });

    test('频率钳制 20–20000', () {
      final m = AppModel(testing: true);
      m.setWaveFreq(99999);
      expect(m.waveFreq, 20000);
      m.setWaveFreq(5);
      expect(m.waveFreq, 20);
      m.setWaveFreq(440);
      expect(m.waveFreq, 440);
    });

    test('文件暂停态与定位比率钳制', () {
      final m = AppModel(testing: true);
      m.setSource('file', path: '/x/c.wav');
      m.setSourcePaused(true);
      expect(m.sourcePaused, isTrue);
      m.toggleFilePlay();
      expect(m.sourcePaused, isFalse, reason: '播放/暂停切换');
      m.seekSource(1.5);
      expect(m.sourcePosRatio, 1);
      m.seekSource(-0.2);
      expect(m.sourcePosRatio, 0);
    });

    test('调试模式开关写 config', () {
      final m = AppModel(testing: true);
      expect(m.config.debugMode, isFalse);
      m.setDebugMode(true);
      expect(m.config.debugMode, isTrue);
      m.setDebugMode(false);
      expect(m.config.debugMode, isFalse);
    });

    test('ASIO 链路下测试源一律无效（第四十九轮 S3）', () {
      final m = AppModel(testing: true);
      m.audioMode = 'asio';
      m.setSource('tone');
      expect(m.sourceKind, '', reason: '波形源起播被拦');
      m.setSource('pink');
      expect(m.sourceKind, '', reason: '粉噪起播被拦');
      m.setSource('file', path: '/x/a.wav');
      expect(m.sourceKind, '', reason: '文件源起播被拦');
      m.toggleWave();
      expect(m.sourceKind, '', reason: 'toggleWave 同样被拦');
      // 切回非 ASIO 后恢复正常；stop 在 ASIO 下永远放行。
      m.audioMode = 'pipeline';
      m.setSource('tone');
      expect(m.sourceKind, 'tone');
      m.audioMode = 'asio';
      m.setSource('stop');
      expect(m.sourceKind, '', reason: 'stop 不受 ASIO 拦截影响');
    });
  });
}
