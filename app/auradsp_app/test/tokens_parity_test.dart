/*
 * tokens_parity_test.dart — 设计令牌漂移防线（P2-1，2026-10-23）
 *
 * 真相源：app/auradsp_app/design/tokens/aura.tokens.json
 * 消费方：lib/core/tokens.g.dart（由 tools/gen_theme.py 生成）
 * 运行时常量：AuraPalette / AuraSpace / AuraSize / AuraRadius / AuraDur / AuraCurve
 *
 * 本测试把「JSON ↔ 运行时常量」逐项比对：改了 JSON 忘记重跑
 * `python tools/gen_theme.py`，这里必红——这是令牌单一真相源能成立的前提。
 */
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:auradsp_app/core/design.dart';
import 'package:auradsp_app/core/theme.dart';

int _hexToArgb32(String v) {
  var h = v.trim().replaceFirst('#', '');
  if (h.length == 3) h = h.split('').map((c) => '$c$c').join();
  return int.parse('FF$h', radix: 16);
}

double _px(dynamic v) =>
    double.parse(v.toString().trim().replaceAll(RegExp(r'(px|ms)$'), ''));

void main() {
  final file = File('design/tokens/aura.tokens.json');
  final Map<String, dynamic> tokens =
      jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;

  group('配色：三主题 × 14 色', () {
    final palettes = <String, (AuraPalette, String)>{
      'aura-dark': (auraDark, 'auraDark'),
      'aura-light': (auraLight, 'auraLight'),
      'aurora': (aurora, 'aurora'),
    };
    final fields = <String, Color Function(AuraPalette)>{
      'bg': (p) => p.bg,
      'panel': (p) => p.panel,
      'panel-raised': (p) => p.panelRaised,
      'hairline': (p) => p.hairline,
      'text': (p) => p.text,
      'text-dim': (p) => p.textDim,
      'accent': (p) => p.accent,
      'accent-contrast': (p) => p.accentContrast,
      'accent-2': (p) => p.accent2,
      'success': (p) => p.success,
      'warning': (p) => p.warning,
      'error': (p) => p.error,
      'viz-spectrum': (p) => p.vizSpectrum,
      'viz-grid': (p) => p.vizGrid,
    };
    palettes.forEach((jsonName, entry) {
      final (palette, label) = entry;
      fields.forEach((jsonKey, getter) {
        test('$label.$jsonKey 与 JSON 一致', () {
          final want = _hexToArgb32(
              tokens['color'][jsonName][jsonKey]['value'] as String);
          expect(getter(palette).toARGB32(), want,
              reason: 'palette=$jsonName key=$jsonKey');
        });
      });
    });
  });

  group('间距 / 语义留白', () {
    final spacing = tokens['spacing'] as Map<String, dynamic>;
    final cases = <String, double>{
      'xxs': AuraSpace.xxs, 'xs': AuraSpace.xs, 'sm': AuraSpace.sm,
      'md': AuraSpace.md, 'lg': AuraSpace.lg, 'xl': AuraSpace.xl,
      'xxl': AuraSpace.xxl, 'hero': AuraSpace.hero,
    };
    cases.forEach((k, v) => test('spacing.$k', () {
          expect(v, _px(spacing[k]['value']));
        }));
    final sem = spacing['semantic'] as Map<String, dynamic>;
    final semCases = <String, double>{
      'page-x': AuraSpace.pageX, 'page-top': AuraSpace.pageTop,
      'page-bottom': AuraSpace.pageBottom, 'card-pad': AuraSpace.cardPad,
      'card-pad-collapsed': AuraSpace.cardPadCollapsed,
      'card-head-gap': AuraSpace.cardHeadGap, 'card-gap': AuraSpace.cardGap,
      'row-gap': AuraSpace.rowGap, 'content-max-w': AuraSpace.contentMaxW,
    };
    semCases.forEach((k, v) => test('semantic.$k', () {
          expect(v, _px(sem[k]['value']));
        }));
  });

  group('组件尺寸 / 圆角', () {
    final size = tokens['size'] as Map<String, dynamic>;
    final sizeCases = <String, double>{
      'rail-w': AuraSize.railW, 'rail-min-w': AuraSize.railMinW,
      'top-bar-h': AuraSize.topBarH, 'nav-item-h': AuraSize.navItemH,
      'nav-icon': AuraSize.navIcon, 'chip-h': AuraSize.chipH,
      'switch-w': AuraSize.switchW, 'switch-h': AuraSize.switchH,
      'switch-thumb': AuraSize.switchThumb, 'slider-thumb': AuraSize.sliderThumb,
      'slider-track': AuraSize.sliderTrack, 'hero-compact': AuraSize.heroCompact,
    };
    sizeCases.forEach((k, v) => test('size.$k', () {
          expect(v, _px(size[k]['value']));
        }));
    final radius = tokens['radius'] as Map<String, dynamic>;
    final radiusCases = <String, double>{
      'xs': AuraRadius.xs, 'sm': AuraRadius.sm,
      'md': AuraRadius.md, 'lg': AuraRadius.lg,
    };
    radiusCases.forEach((k, v) => test('radius.$k', () {
          expect(v, _px(radius[k]['value']));
        }));
  });

  group('动效时长 / 曲线', () {
    final dur = tokens['motion']['duration'] as Map<String, dynamic>;
    final durCases = <String, Duration>{
      'instant': AuraDur.instant, 'fast': AuraDur.fast, 'base': AuraDur.base,
      'slow': AuraDur.slow, 'page': AuraDur.page,
      'stagger-step': AuraDur.stagger, 'stagger-span': AuraDur.staggerSpan,
    };
    durCases.forEach((k, v) => test('duration.$k', () {
          expect(v.inMilliseconds, _px(dur[k]['value']).round());
        }));
    final curve = tokens['motion']['curve'] as Map<String, dynamic>;
    test('curve.standard = easeOutCubic', () {
      expect(curve['standard']['value'], 'easeOutCubic');
      expect(AuraCurve.standard.transform(0.37),
          closeTo(Curves.easeOutCubic.transform(0.37), 1e-9));
    });
    // cubic-bezier 逐点采样比对（Cubic 不接受相等性比较）。
    final bez = curve['emphasized']['value'] as String;
    final nums = bez
        .substring('cubic-bezier('.length, bez.length - 1)
        .split(',')
        .map((s) => double.parse(s.trim()))
        .toList();
    test('curve.emphasized 与 JSON cubic-bezier 采样一致', () {
      final ref = Cubic(nums[0], nums[1], nums[2], nums[3]);
      for (final t in [0.0, 0.17, 0.5, 0.83, 1.0]) {
        expect(AuraCurve.emphasized.transform(t),
            closeTo(ref.transform(t), 1e-9));
      }
    });
    test('curve 采样合理性（单调不减）', () {
      double prev = -1;
      for (var i = 0; i <= 20; i++) {
        final y = AuraCurve.emphasized.transform(i / 20.0);
        expect(y, greaterThanOrEqualTo(prev - 1e-9));
        prev = math.max(prev, y);
      }
    });
  });
}
