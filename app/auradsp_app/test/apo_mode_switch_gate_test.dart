// apo_mode_switch_gate_test.dart — 切离 sysapo 自动卸载门回归
// （业主 2026-11-12 裁定）。
//
// 钉死四件事：① 有端点附加时切换被拦截（blocking 置位、模式
// 不变），卸载成功后自动续行到原目标；② 等待期间反复切换被
// 吞掉（首个目标为准）；③ 卸载失败留在 sysapo 且范式/附加
// 字段回滚、blocking 清除；④ 无附加时不等待、直接切换且不
// 调用卸载。卸载本体经 apoDetachRunnerOverride 测试缝替代
// （真实路径依赖提权工具与注册表，单测不可达）。

import 'dart:async';

import 'package:auradsp_app/core/audio_modes.dart';
import 'package:auradsp_app/core/state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  AppModel sysapoModel() {
    final m = AppModel(testing: true);
    m.audioMode = 'sysapo';
    m.config.audioMode = 'sysapo';
    m.config.modeCategory = AudioModes.categoryAttachment;
    m.config.attachmentMode = AudioModes.attachSysApo;
    return m;
  }

  Future<void> settle() async {
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  test('有附加：拦截 → 卸载成功 → 续行原目标', () async {
    final m = sysapoModel();
    m.apoAnyAttached = true;
    var runs = 0;
    m.apoDetachRunnerOverride = () async {
      runs++;
      m.apoAnyAttached = false;
      return true;
    };
    final target = AudioModes.normalize('vbcallback');
    m.setAudioMode('vbcallback');
    expect(m.apoDetachBlocking, isTrue, reason: '卸载在途必须置位禁选旗标');
    expect(m.audioMode, 'sysapo', reason: '卸载落定前不得切换');
    await settle();
    expect(runs, 1);
    expect(m.apoDetachBlocking, isFalse);
    expect(m.audioMode, target, reason: '成功后应自动续行到原目标');
    m.dispose();
  });

  test('等待期间反复切换被吞掉（首个目标为准）', () async {
    final m = sysapoModel();
    m.apoAnyAttached = true;
    final gate = Completer<bool>();
    m.apoDetachRunnerOverride = () => gate.future;
    final first = AudioModes.normalize('vbcallback');
    m.setAudioMode('vbcallback');
    expect(m.apoDetachBlocking, isTrue);
    m.setAudioMode('asio'); // 在途点击：必须被吞
    m.setAudioMode('vaio'); // 再点：仍吞
    expect(m.audioMode, 'sysapo');
    m.apoAnyAttached = false;
    gate.complete(true);
    await settle();
    expect(m.audioMode, first, reason: '落定后只续行首个挂起目标');
    expect(m.apoDetachBlocking, isFalse);
    m.dispose();
  });

  test('卸载失败：留在 sysapo 并回滚预写字段', () async {
    final m = sysapoModel();
    m.apoAnyAttached = true;
    m.apoDetachRunnerOverride = () async => false;
    // 模拟 setModeCategory 已预写范式字段后进入漏斗的情形。
    m.config.modeCategory = AudioModes.categoryPipeline;
    m.setAudioMode('vbcallback');
    expect(m.apoDetachBlocking, isTrue);
    await settle();
    expect(m.apoDetachBlocking, isFalse);
    expect(m.audioMode, 'sysapo', reason: '失败必须留在 APO 模式');
    expect(m.config.modeCategory, AudioModes.categoryAttachment,
        reason: '范式字段须回滚到 sysapo 口径');
    expect(m.config.attachmentMode, AudioModes.attachSysApo);
    m.dispose();
  });

  test('无附加：不等待、直接切换、不调用卸载', () async {
    final m = sysapoModel();
    m.apoAnyAttached = false;
    var runs = 0;
    m.apoDetachRunnerOverride = () async {
      runs++;
      return true;
    };
    final target = AudioModes.normalize('vbcallback');
    m.setAudioMode('vbcallback');
    expect(m.apoDetachBlocking, isFalse);
    expect(m.audioMode, target, reason: '无附加时应当场切换');
    await settle();
    expect(runs, 0, reason: '无附加不得触发卸载');
    m.dispose();
  });
}
