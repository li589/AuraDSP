// chain_true_order_test.dart — 第七轮 S1（项 1）链序归真契约。
//
// 定罪背景：链页把 19 级呈现为可任意拖拽的线性序、全局信号流面板又
// 按硬编码分桶重排，两者与引擎 process_stereo_chain 的真实执行序都
// 不一致——跨桶拖动图上不动、拖自研级音频零变化。本组契约钉住：
// vendor 子序提取/真序拼合纯函数的不变量 + 面板/链卡的接线形态。
import 'dart:io';

import 'package:auradsp_app/core/effect_registry.dart';
import 'package:flutter_test/flutter_test.dart';

String _read(String relPath) {
  for (final base in const ['', '../', '../../']) {
    final f = File('$base$relPath');
    if (f.existsSync()) return f.readAsStringSync();
  }
  throw StateError('找不到 $relPath（cwd=${Directory.current.path}）');
}

void main() {
  group('vendor 子序与真序拼合', () {
    test('默认序的 vendor 子序 = 11 级既定相对序', () {
      expect(kDefaultVendorOrder, [
        'tube',
        'comp',
        'bass',
        'eq',
        'arbmag',
        'convolver',
        'ddc',
        'liveprog',
        'crossfeed',
        'stereo',
        'reverb',
      ]);
    });

    test('默认真序 = 钉死段归位 + vendor 默认子序（19 级）', () {
      expect(kTrueChainDefaultOrder, [
        'gate',
        'filter',
        'bassmono',
        'dyneq',
        'tube',
        'comp',
        'bass',
        'eq',
        'arbmag',
        'convolver',
        'ddc',
        'liveprog',
        'crossfeed',
        'stereo',
        'reverb',
        'haas',
        'spatial',
        'exciter',
        'loudness',
      ]);
      // 真序与默认 graphOrder 只是钉死级归位差异，成员集合恒等。
      expect(kTrueChainDefaultOrder.toSet(), kDefaultCoreOrder.toSet());
    });

    test('任意交错的存档串规范化后钉死级恒居其位、vendor 子序保真', () {
      // 模拟旧存档：reverb 被拖到最前、loudness 第二、eq 与 tube 互换。
      final legacy = 'reverb,loudness,eq,gate,comp,tube,filter,bass,dyneq,'
          'arbmag,convolver,ddc,liveprog,crossfeed,stereo,bassmono,haas,'
          'spatial,exciter,output';
      final normalized = trueChainOrderFrom(legacy);
      expect(normalized.length, 19);
      expect(normalized.sublist(0, 4), ['gate', 'filter', 'bassmono', 'dyneq']);
      expect(normalized.last, 'loudness');
      expect(normalized.sublist(15), ['haas', 'spatial', 'exciter', 'loudness']);
      // vendor 子序按存档中的相对序：reverb 第一、eq 在 tube 之前。
      expect(vendorSubsequenceOf(normalized), [
        'reverb',
        'eq',
        'comp',
        'tube',
        'bass',
        'arbmag',
        'convolver',
        'ddc',
        'liveprog',
        'crossfeed',
        'stereo',
      ]);
    });

    test('残缺串缺失的 vendor 级按默认相对序回插', () {
      final sub = vendorSubsequenceOf(['eq', 'tube']);
      expect(sub.length, 11);
      expect(sub.toSet(), kChainVendorStages.toSet());
      // 已有级的相对序保真（eq 在 tube 之前是存档原意）。
      expect(sub.indexOf('eq') < sub.indexOf('tube'), isTrue);
      // 缺失级按默认序回插到已有锚点之间：comp/bass 落在 eq 之前、
      // arbmag 起顺次其后（与链卡历史回插口径一致）。
      expect(sub.indexOf('comp') < sub.indexOf('eq'), isTrue);
      expect(sub.indexOf('eq') < sub.indexOf('arbmag'), isTrue);
    });

    test('钉死/vendor 分类互斥且覆盖全部 19 级', () {
      for (final id in kDefaultCoreOrder) {
        expect(isChainVendorStage(id) != isChainPinnedStage(id), isTrue,
            reason: '$id 必须恰属一类');
      }
    });
  });

  group('源码契约', () {
    test('信号流面板按真序拼合、无硬编码分桶残留', () {
      final panel =
          _read('app/auradsp_app/lib/features/chain/chain_scifi_flow_panel.dart');
      expect(panel.contains('vendorSubsequenceOf(widget.order)'), isTrue);
      expect(panel.contains('kChainPinnedHead'), isTrue);
      expect(panel.contains('kChainPinnedTail'), isTrue);
      // 旧分桶的判别式：主桶排除 reverb/loudness 的写法不得回归。
      expect(panel.contains("id != 'reverb'"), isFalse);
      expect(panel.contains("id != 'loudness'"), isFalse);
    });

    test('链卡展示走真序规范化、钉死级锁定、外部改序重同步', () {
      final card =
          _read('app/auradsp_app/lib/features/chain/chain_order_card.dart');
      expect(card.contains('trueChainOrderFrom'), isTrue);
      expect(card.contains('isChainPinnedStage'), isTrue);
      expect(card.contains('lock_outline_rounded'), isTrue);
      expect(card.contains('addListener(_onModelChanged)'), isTrue);
      expect(card.contains('composeTrueChainOrder(vendorSubsequenceOf(_order))'),
          isTrue);
    });

    test('setGraphOrder 改序后广播 UI 通知', () {
      final chain = _read('app/auradsp_app/lib/core/state/state_chain.dart');
      final start = chain.indexOf('void setGraphOrder');
      expect(start, greaterThanOrEqualTo(0));
      // 函数体含 send({...}) 的花括号，不能按首个 } 切分；取定长窗口
      // 并夹紧到文件长度（第六轮窗口越界教训）。
      final end = (start + 700 > chain.length) ? chain.length : start + 700;
      final body = chain.substring(start, end);
      expect(body.contains('scheduleAutoSave();'), isTrue);
      expect(body.contains('_notifyUi();'), isTrue);
    });
  });
}
