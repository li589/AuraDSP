// platform_profile_os_test.dart — 第四十四轮 S3：操作系统
// 显示串清洗（Dart 原串在 Windows 上产品名带引号）。
import 'package:flutter_test/flutter_test.dart';

import 'package:auradsp_app/platform/platform_profile.dart';

void main() {
  group('PlatformProfile.cleanOsVersion', () {
    test('Windows 带引号产品名 → 去引号拼接', () {
      expect(
        PlatformProfile.cleanOsVersion(
            '"Windows 10 IoT Enterprise LTSC 2021" 10.0 (Build 19044)',
            isWindows: true),
        'Windows 10 IoT Enterprise LTSC 2021 10.0 (Build 19044)',
      );
      expect(
        PlatformProfile.cleanOsVersion('"Windows 11 Pro" 10.0 (Build 26100)',
            isWindows: true),
        'Windows 11 Pro 10.0 (Build 26100)',
      );
    });

    test('Windows 无引号串原样（仅 trim）', () {
      expect(
        PlatformProfile.cleanOsVersion('  Windows 11 Pro 10.0 (Build 26100) ',
            isWindows: true),
        'Windows 11 Pro 10.0 (Build 26100)',
      );
    });

    test('非 Windows 兜底去引号', () {
      expect(
        PlatformProfile.cleanOsVersion('Linux 6.8.0-45-generic',
            isWindows: false),
        'Linux 6.8.0-45-generic',
      );
    });
  });
}
