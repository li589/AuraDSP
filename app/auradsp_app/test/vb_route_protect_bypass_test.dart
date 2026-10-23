import 'package:flutter_test/flutter_test.dart';
import 'package:auradsp_app/core/state.dart';

/// Z15：VB 超预算保护旁路判定纯函数单测。
///
/// 数据源为 vbstatus 心跳的 protect/hotGrp 两个字段；语义：
/// - protect==1 时有效掩码收窄到 hotGrp（仅该路进插件链），其余路直通；
/// - group<0（无选中路）恒 false——无路态由下拉的旁路提示表达，不占按钮态。
Map<String, dynamic> _info({int? protect, int? hotGrp}) => {
      'protect': ?protect,
      'hotGrp': ?hotGrp,
    };

void main() {
  group('Z15 vbRouteProtectBypassed', () {
    test('protect off → never bypassed (any group/hotGrp)', () {
      expect(vbRouteProtectBypassed(_info(protect: 0, hotGrp: 0), 3), false);
      expect(vbRouteProtectBypassed(_info(protect: 0, hotGrp: 7), 0), false);
      expect(vbRouteProtectBypassed(_info(hotGrp: 2), 5), false,
          reason: 'missing protect defaults to 0');
    });

    test('protect on, group == hotGrp → not bypassed (hot group alive)', () {
      expect(vbRouteProtectBypassed(_info(protect: 1, hotGrp: 2), 2), false);
      expect(vbRouteProtectBypassed(_info(protect: 1, hotGrp: 0), 0), false);
      expect(vbRouteProtectBypassed(_info(protect: 1, hotGrp: 7), 7), false);
    });

    test('protect on, group != hotGrp → bypassed', () {
      expect(vbRouteProtectBypassed(_info(protect: 1, hotGrp: 2), 3), true);
      expect(vbRouteProtectBypassed(_info(protect: 1, hotGrp: 0), 1), true);
      expect(vbRouteProtectBypassed(_info(protect: 1, hotGrp: 7), 0), true);
    });

    test('group < 0 (no route selected) → false', () {
      expect(vbRouteProtectBypassed(_info(protect: 1, hotGrp: 3), -1), false);
      expect(vbRouteProtectBypassed(_info(protect: 1), -1), false);
    });

    test('protect on but hotGrp missing → all groups bypassed (hot=-1)', () {
      expect(vbRouteProtectBypassed(_info(protect: 1), 0), true);
      expect(vbRouteProtectBypassed(_info(protect: 1), 5), true);
    });

    test('empty / degenerate info → false', () {
      expect(vbRouteProtectBypassed({}, 4), false);
      expect(vbRouteProtectBypassed({'protect': 'x', 'hotGrp': 'y'}, 4),
          false,
          reason: 'non-numeric fields degrade to defaults');
    });

    test('num type tolerance (double-encoded JSON numbers)', () {
      expect(
          vbRouteProtectBypassed({'protect': 1.0, 'hotGrp': 2.0}, 2), false);
      expect(
          vbRouteProtectBypassed({'protect': 1.0, 'hotGrp': 2.0}, 3), true);
    });
  });
}
