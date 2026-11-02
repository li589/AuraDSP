// ALSA 专家模式（D-6 二期）配置与纯逻辑门禁：
// - AppConfig 新字段默认值与 JSON 往返（旧配置缺字段须落默认）；
// - resolveAlsaDevice 的设备名解析口径。
import 'package:auradsp_app/core/config.dart';
import 'package:auradsp_app/engine/audio_out/alsa_ffi.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('AppConfig ALSA fields default to pulse backend', () {
    final c = AppConfig();
    expect(c.linuxAudioBackend, 'pulse');
    expect(c.alsaOutputDevice, '');
    expect(c.alsaCaptureDevice, '');
  });

  test('AppConfig ALSA fields survive a JSON round trip', () {
    final c = AppConfig()
      ..linuxAudioBackend = 'alsa'
      ..alsaOutputDevice = 'hw:1,0'
      ..alsaCaptureDevice = 'hw:Loopback,1';
    final back = AppConfig.fromJson(c.toJson());
    expect(back.linuxAudioBackend, 'alsa');
    expect(back.alsaOutputDevice, 'hw:1,0');
    expect(back.alsaCaptureDevice, 'hw:Loopback,1');
  });

  test('AppConfig from legacy JSON without ALSA keys uses defaults', () {
    final back = AppConfig.fromJson(const {
      'audio': {'sampleRate': 44100},
    });
    expect(back.linuxAudioBackend, 'pulse');
    expect(back.alsaOutputDevice, '');
    expect(back.alsaCaptureDevice, '');
  });

  test('alsaRateMatches accepts equal rates and unknown pump rate', () {
    expect(alsaRateMatches(negotiated: 48000, pumpRate: 48000), isTrue);
    expect(alsaRateMatches(negotiated: 44100, pumpRate: 44100), isTrue);
    // 输出未初始化（pumpRate<=0）无法判断：按可用处理，调用方另有兜底。
    expect(alsaRateMatches(negotiated: 44100, pumpRate: 0), isTrue);
  });

  test('alsaRateMatches rejects a mismatched negotiated rate', () {
    // ALSA 无服务端重采样：协商率被设备改掉（如固定 44.1k）而泵
    // 按 48k 消费会变速变调，必须拦下（打磨一期）。
    expect(alsaRateMatches(negotiated: 44100, pumpRate: 48000), isFalse);
    expect(alsaRateMatches(negotiated: 48000, pumpRate: 44100), isFalse);
  });

  test('resolveAlsaDevice maps blank to default and trims names', () {
    expect(resolveAlsaDevice(''), 'default');
    expect(resolveAlsaDevice('   '), 'default');
    expect(resolveAlsaDevice('hw:0,0'), 'hw:0,0');
    expect(resolveAlsaDevice(' plughw:1,0 '), 'plughw:1,0');
    expect(resolveAlsaDevice('default'), 'default');
  });
}
