// atlas_release_test.dart — 精灵图集隐藏期释放/恢复重解码回归
// （2026-11-12 优化指令：托盘/最小化时释放图像节点内存）。
//
// 钉死三件事：① ensureImage 正常解码；② releaseImage 后图集
// 为空（内存已还）且不置失败标记；③ 恢复后 ensureImage 能再
// 次解码（释放不是永久关闭精灵层）。另钉解码在飞时 release
// 的代次作废：落地结果不得回填。

import 'package:auradsp_app/features/visualizer/styles/visualizer_sprite_atlas.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> waitImage(VisualizerSpriteAtlas atlas,
    {required bool present}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (DateTime.now().isBefore(deadline)) {
    if ((atlas.imageOrNull != null) == present) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  fail('等待图集${present ? '解码' : '释放'}超时');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final atlas = VisualizerSpriteAtlas.instance;

  test('解码 → 释放 → 再解码 全周期', () async {
    atlas.ensureImage();
    await waitImage(atlas, present: true);
    atlas.releaseImage();
    expect(atlas.imageOrNull, isNull, reason: '释放后不得再持有图集');
    atlas.ensureImage();
    await waitImage(atlas, present: true);
    atlas.releaseImage();
  });

  test('解码在飞时释放：落地结果被代次作废', () async {
    atlas.releaseImage();
    atlas.ensureImage();
    atlas.releaseImage(); // 解码大概率尚在飞（或刚落地亦应为空）
    // 给足落地时间后仍必须为空：若在飞结果回填，这里会非空。
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(atlas.imageOrNull, isNull,
        reason: 'release 之后的在飞解码结果不得回填');
    // 且精灵层未被永久关闭：再次 ensure 应能解码回来。
    atlas.ensureImage();
    await waitImage(atlas, present: true);
    atlas.releaseImage();
  });
}
