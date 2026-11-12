// plugin_editor_actions_test.dart — 插件编辑器三动作引擎回归
// （业主 2026-11-12 立项：立即应用 / 自动应用 / 恢复）。
//
// 钉死管理器侧契约：① 影子模式下编辑器打开回执即发基线快照
// 命令；② 立即应用 = 手动收获命令（无 auto 标记）；③ 自动
// 应用开启后 300ms 轮询带 auto 标记的收获命令，关闭编辑器
// 自动停发并复位开关；④ 恢复在基线未就绪时不发命令、就绪
// 后发恢复命令；⑤ 非影子模式下打开编辑器不快照、立即应用
// 为空操作。

import 'package:auradsp_app/core/plugins/plugin_manager.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('三动作引擎（sysapo 影子）', () {
    late List<Map<String, dynamic>> sent;
    late PluginManager m;

    setUp(() {
      sent = [];
      m = PluginManager(commandSender: sent.add);
      m.setApoShadow(true);
    });

    tearDown(() => m.dispose());

    List<Map<String, dynamic>> cmds(String cmd) =>
        sent.where((e) => e['cmd'] == cmd).toList();

    test('编辑器打开回执 → 发基线快照命令', () {
      m.onPluginSlotEditorResult(1, 'show', true);
      expect(m.isSlotEditorOpen(1), isTrue);
      final snaps = cmds('apoSnapshotBaseline');
      expect(snaps, hasLength(1));
      expect(snaps.single['slot'], 1);
    });

    test('立即应用发手动收获（无 auto 标记）', () {
      m.onPluginSlotEditorResult(0, 'show', true);
      sent.clear();
      m.applyEditorStateNow(slot: 0);
      final h = cmds('apoHarvestState');
      expect(h, hasLength(1));
      expect(h.single['auto'], isNull);
    });

    test('自动应用：300ms 轮询带 auto 标记；关编辑器停发并复位', () async {
      m.onPluginSlotEditorResult(2, 'show', true);
      m.setEditorAutoApply(true, slot: 2);
      expect(m.isEditorAutoApply(2), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 700));
      final autos = cmds('apoHarvestState')
          .where((e) => e['auto'] == true && e['slot'] == 2)
          .toList();
      expect(autos.length, greaterThanOrEqualTo(2),
          reason: '700ms 内至少两轮 300ms 轮询');
      m.onPluginSlotEditorResult(2, 'close', true);
      expect(m.isEditorAutoApply(2), isFalse, reason: '关闭即复位开关');
      sent.clear();
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(cmds('apoHarvestState'), isEmpty,
          reason: '关闭后轮询必须停发');
    });

    test('恢复：基线未就绪不发命令；就绪后发恢复命令', () {
      m.onPluginSlotEditorResult(3, 'show', true);
      sent.clear();
      m.restoreEditorBaseline(slot: 3);
      expect(cmds('apoRestoreBaseline'), isEmpty,
          reason: '基线未就绪不得发恢复');
      m.onApoBaselineResult(3, true);
      expect(m.isEditorBaselineReady(3), isTrue);
      m.restoreEditorBaseline(slot: 3);
      final r = cmds('apoRestoreBaseline');
      expect(r, hasLength(1));
      expect(r.single['slot'], 3);
    });

    test('恢复回执基线丢失 → 就绪旗标清除', () {
      m.onPluginSlotEditorResult(0, 'show', true);
      m.onApoBaselineResult(0, true);
      expect(m.isEditorBaselineReady(0), isTrue);
      m.onApoRestoreResult(0, false, true);
      expect(m.isEditorBaselineReady(0), isFalse);
    });
  });

  group('非影子模式：三动作不适用', () {
    test('打开编辑器不快照、立即应用为空操作', () {
      final sent = <Map<String, dynamic>>[];
      final m = PluginManager(commandSender: sent.add);
      m.setApoShadow(false);
      m.onPluginSlotEditorResult(0, 'show', true);
      m.applyEditorStateNow(slot: 0);
      m.restoreEditorBaseline(slot: 0);
      expect(sent.where((e) => e['cmd'] == 'apoSnapshotBaseline'), isEmpty);
      expect(sent.where((e) => e['cmd'] == 'apoHarvestState'), isEmpty);
      expect(sent.where((e) => e['cmd'] == 'apoRestoreBaseline'), isEmpty);
      m.dispose();
    });
  });
}
