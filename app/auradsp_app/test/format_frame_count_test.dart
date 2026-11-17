// format_frame_count_test.dart — 第四十四轮 S2：VAIO 已处理
// 帧计数的显示格式（千分位分组 + 极大值 M/B 进位）。
import 'package:flutter_test/flutter_test.dart';

import 'package:auradsp_app/features/settings_page.dart';

void main() {
  group('formatFrameCount', () {
    test('负值与零', () {
      expect(formatFrameCount(-5), '0');
      expect(formatFrameCount(0), '0');
    });

    test('千分位分组', () {
      expect(formatFrameCount(999), '999');
      expect(formatFrameCount(1000), '1,000');
      expect(formatFrameCount(123456), '123,456');
      expect(formatFrameCount(999999), '999,999');
    });

    test('M 进位（去尾零）', () {
      expect(formatFrameCount(1000000), '1M');
      expect(formatFrameCount(1500000), '1.5M');
      expect(formatFrameCount(123456789), '123.46M');
    });

    test('B 进位（一天 48kHz 约 4.1e9 帧）', () {
      expect(formatFrameCount(4147200000), '4.15B');
    });
  });
}
