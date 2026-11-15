// 桥非计划死亡自动重启闸门语义（2026-11-15 无声事件修复）：
// 窗口内前 maxRestarts 次死亡允许自动重启，其后停手；窗口过期
// 重新计数；显式指令 reset 后重新布防；后端之间互不影响。
import 'package:auradsp_app/engine/bridge_death_gate.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BridgeDeathGate', () {
    test('前 3 次死亡允许重启，第 4 次停手', () {
      final gate = BridgeDeathGate();
      expect(gate.recordDeath('vaio', 1000), isTrue);
      expect(gate.recordDeath('vaio', 2000), isTrue);
      expect(gate.recordDeath('vaio', 3000), isTrue);
      expect(gate.recordDeath('vaio', 4000), isFalse);
      expect(gate.recordDeath('vaio', 5000), isFalse);
    });

    test('窗口过期后重新允许', () {
      final gate = BridgeDeathGate();
      expect(gate.recordDeath('vaio', 0), isTrue);
      expect(gate.recordDeath('vaio', 1000), isTrue);
      expect(gate.recordDeath('vaio', 2000), isTrue);
      expect(gate.recordDeath('vaio', 3000), isFalse);
      // 距首次死亡超过 120s 窗口：旧计数滚出，重新放行。
      expect(gate.recordDeath('vaio', 121000), isTrue);
    });

    test('reset 后重新布防', () {
      final gate = BridgeDeathGate();
      gate.recordDeath('vaio', 0);
      gate.recordDeath('vaio', 1);
      gate.recordDeath('vaio', 2);
      expect(gate.recordDeath('vaio', 3), isFalse);
      gate.reset('vaio');
      expect(gate.recordDeath('vaio', 4), isTrue);
    });

    test('后端之间互不影响', () {
      final gate = BridgeDeathGate();
      gate.recordDeath('vaio', 0);
      gate.recordDeath('vaio', 1);
      gate.recordDeath('vaio', 2);
      expect(gate.recordDeath('vaio', 3), isFalse);
      expect(gate.recordDeath('asio', 3), isTrue);
      expect(gate.deathCount('vm', 3), 0);
    });
  });
}
