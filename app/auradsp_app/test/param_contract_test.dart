// param_contract_test.dart — 参数三层契约全量回归（审查报告 §8 门禁 2+3）
//
// 背景：v1.0 审查发现 S-2（setter 误接 copy-paste 写错参数）与 P-4（默认值
// 三层发散）均无自动化守卫。本测试把三类缺口补齐：
//
//   Part A（门禁 2-运行时）：全部 ParamSpec 的 getter/setter 闭环 ——
//     setter 写错字段时 getter 读不到新值，S-2 类 bug 直接挂。
//   Part B（门禁 2-静态链）：spec.setter → state.dart 方法体（含 helper 与
//     传递调用）→ setInt/setFloat/setString('引擎id') 全链静态比对；UI 名与
//     引擎名不一致的必须显式登记 alias，不允许"看起来对"的静默豁免。
//   Part C（权威对账）：引擎全部参数 id ↔ registry spec id 双向差集白名单化，
//     引擎新增参数而 UI 未接线（或反向）必须人工登记。
//   Part D（门禁 3）：引擎默认 ↔ spec.defaultValue 全量一致；fixture 带引擎
//     源码行数哨兵，header/create 变更未重生立即失败；同引擎成员的 spec
//     默认互相不得打架。
//
// 维护约定：所有白名单新增条目必须带理由注释；测试与白名单之间是**精确
// 集合相等**断言（双向），禁止"悄悄变大/变小"。

import 'dart:convert';
import 'dart:io';

import 'package:auradsp_app/core/engine_error_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:auradsp_app/core/param_schema.dart';
import 'package:auradsp_app/core/state.dart';

import 'fixtures/param_defaults_contract.g.dart';

// ---------------------------------------------------------------------------
// 白名单区（显式登记制；集合断言见 Part B/C）
// ---------------------------------------------------------------------------

/// spec.id → 引擎真实 id（UI 命名与引擎不一致的合法映射）。
/// key = spec.id，value = 期望出现的引擎 id 集合（模板展开后）。
const Map<String, Set<String>> kAliasToEngineId = {
  // freeverb 家族：UI 叫 reverb.*，引擎叫 freeverb.*（setReverbCustomParam 映射）
  'reverb.decay': {'freeverb.decay'},
  'reverb.damp': {'freeverb.damp'},
  'reverb.wet': {'freeverb.wet'},
  'reverb.dry': {'freeverb.dry'},
  'reverb.roomSize': {'freeverb.roomsize'},
  'reverb.width': {'freeverb.width'},
  // 总开关走 reverb.preset（WP1：freeverb.enable 已退役为 deprecated 写别名）
  'reverb.enable': {'reverb.preset'},
  // 输出增益门命名差异（UI outputgain ↔ 引擎 outgain）
  'bass.outputgain': {'bass.outgain'},
  'eq.outputgain': {'eq.outgain'},
  'tube.outputgain': {'tube.outgain'},
  'comp.outputgain': {'comp.outgain'},
  'reverb.outputgain': {'reverb.outgain'},
  'arbmag.outputgain': {'arbmag.outgain'},
  // 其它历史命名/语义差
  'bass.harmonicBlend': {'bass.harmonicblend'}, // 引擎 id 全小写
  'bass.subFloor': {'bass.subfreq'},
  'bass.intensity': {'bass.gain'}, // 强度旋钮直写引擎增益
  // B3 定案：bass_shaping.enable 已删除（假参数；开关复用 shelf.enable + bassmono.enable）
  'gate.hold': {'gate.hold_ms'},
  // B3 定案：stereo 分带 spec id 已统一为引擎层名称 stereo.band1..5（无别名）
  // comp 宏观阈值换算为 7 段压限量下发
  'comp.threshold': {
    'comp.gain1', 'comp.gain2', 'comp.gain3', 'comp.gain4',
    'comp.gain5', 'comp.gain6', 'comp.gain7',
  },
};

/// setter 走 helper 方法的 spec（method → helper 名）；
/// helper 体内引用引擎 id，按同样规则建链。
const Map<String, String> kSetterHelper = {
  'setStereoEnabled': '_pushStereoChain',
  'setStereoMix': '_pushStereoChain',
  'setStereoBand': '_pushStereoChain',
};

/// Part B 检测出的"setter 不向引擎下发任何参数"的 spec（字段直赋 / 空实现 /
/// helper 链为空）。与检测结果精确相等（双向断言）；新条目必须带理由。
/// 注意：与本文件其它白名单语义不同——这里登记的是"写法形态"，
/// kUiOnlySpecIds 登记的是"引擎无此参数"。
const Set<String> kNoEngineWriteSpecIds = {
  // 字段直赋（m.xxx = v）
  'eq.bypass', // toggleEqBypass 特路消费；引擎无 eq.bypass
  'eq.presetName', // UI 预设名，不入引擎
  'stereo.bandUsed', // 字段直赋，_pushStereoChain 间接影响 bandUsed 推送
  // 空实现 noop（setter 是 (m, v) {}）
  'bass.gain', // 派生字段，由 intensity 经 _mirror 回写
  'liveprog.codeHash', // 由 apply 特殊对账消费（FNV 哈希只读态）
  'routing.modeCategory', // 宿主路由配置，ConfigManager 域
  'routing.attachmentMode', // 宿主路由配置，ConfigManager 域
  'routing.pipelineInput', // 宿主路由配置，ConfigManager 域
  'routing.pipelineOutput', // 宿主路由配置，ConfigManager 域
  // 方法链为空（方法体走 config.* + ConfigManager.save，不引用任何引擎 id）
  'comp.ratio', // 引擎无 comp.ratio 参数（vendor 多段压缩无比率）；静态孤儿 spec
  'eq.filter', // setEqFilter 仅切 UI 滤波类型
  'eq.interp', // setEqInterp 仅切 UI 插值
  // 注：eq.bandsCount / eq.q 不在此列——二者经 setEqBandsCount/fillEqQ →
  // _pushEqCurve 向引擎下发 eq.curve（链非空；引擎无同名参数，形态走
  // kUiOnlySpecIds 豁免期望断言）
  'routing.apoTargetEndpoint', // APO 端点，ConfigManager 域
  'routing.asioBufSize', // ASIO 缓冲档，ConfigManager 域
  'routing.asioDriver', // ASIO 驱动，ConfigManager 域
  'routing.asioOutPair', // ASIO 输出对，ConfigManager 域
  'routing.monitorMirroring', // 监视器镜像，ConfigManager 域
  'routing.pipelineInputDevice', // 管道输入设备，ConfigManager 域
  'routing.pipelineInputEnabled', // 管道输入开关，ConfigManager 域
  'routing.pipelineOutputDevice', // 管道输出设备，ConfigManager 域
  'routing.pipelineOutputEnabled', // 管道输出开关，ConfigManager 域
  'routing.vaioOutputEndpoint', // AuraVAIO 端点，ConfigManager 域
};

/// Part A（getter/setter 运行时闭环）排除项：setter 写入门槛非对称或空实现，
/// 探针值无法原样读回。排除不等于豁免——形态仍由 Part B 静态链覆盖。
const Set<String> kNonRoundtripSpecIds = {
  'bass.gain', // noop：派生字段
  'liveprog.codeHash', // noop：只读哈希态
  'arbmag.string', // setter 仅 v.isNotEmpty 时写入，空串还原被跳过
  'arbmag.enable', // 实际生效值 = on && arbmagReady；testing 下引擎回显置 0
  'routing.modeCategory', // noop setter：值经 ConfigManager/快照对账路径应用
  'routing.attachmentMode', // noop setter：同上
  'routing.pipelineInput', // noop setter：同上
  'routing.pipelineOutput', // noop setter：同上
};

/// Part C：UI 专属 spec——引擎无对应参数（经 alias 归一后仍不在引擎表）。
/// 与差集断言精确相等（双向）。
const Set<String> kUiOnlySpecIds = {
  // EQ UI 态（引擎无参；UI 曲线生成时消费，见 P-1）
  'eq.bandsCount', 'eq.q', 'eq.filter', 'eq.interp',
  // EQ 预设名 / 旁路（字段直赋或 toggleEqBypass 特路）
  'eq.presetName', 'eq.bypass', 'liveprog.codeHash',
  // 宿主/路由配置（ConfigManager 域，不发电Engine）
  // 注：bass.mode 曾在此登记为 UI 专属——P-032 起引擎新增了同名状态载体
  // 参数（纯 UI 模式选择的状态回读通道，不参与 DSP 计算），故已移出。
  'routing.apoTargetEndpoint', 'routing.asioBufSize',
  'routing.asioDriver', 'routing.asioOutPair', 'routing.attachmentMode',
  'routing.modeCategory', 'routing.monitorMirroring', 'routing.pipelineInput',
  'routing.pipelineInputDevice', 'routing.pipelineInputEnabled',
  'routing.pipelineOutput', 'routing.pipelineOutputDevice',
  'routing.pipelineOutputEnabled', 'routing.vaioOutputEndpoint',
};

/// Part C：引擎侧参数 UI 不通过 registry 暴露的状态/掩码/计量/别名族/
/// 动态分支。与差集断言精确相等（双向）；新条目必须带理由。
const Set<String> kEngineOnlyIds = {
  // ---- arbmag：ArbMag 节点数/就绪 ----
  'arbmag.channel_mask',
  'arbmag.nodeCount',
  'arbmag.ready',
  // ---- bass：oversample（UI 未暴露） ----
  'bass.intensity',
  'bass.oversample',
  // ---- bassmono：WP0 多对选择/全局合并（UI 于 WP4 接入） ----
  'bassmono.merge',
  'bassmono.pairs',
  // ---- channels：声道数/模式查询（VM/isolate 直发） ----
  'channels.count',
  'channels.countMode',
  'channels.mode',
  // ---- comp：channel_mask（spec id = comp.channels；freq/gain 14 动态段已注册进 comp section） ----
  'comp.channel_mask',
  'comp.mode',
  // ---- convolver：卷积 IR 查询/清空（副作用指令） ----
  'convolver.clear',
  'convolver.ir.channels',
  'convolver.ir.frames',
  'convolver.ir.path',
  'convolver.ir.peak',
  'convolver.ir.spectrum',
  'convolver.ir.srcRate',
  'convolver.ready',
  // ---- ddc：DDC 加载/就绪（副作用指令） ----
  'ddc.load',
  'ddc.ready',
  // ---- dyneq：别名族 + 声道掩码 ----
  'dyneq.band1.attack',
  'dyneq.band1.release',
  'dyneq.band2.attack',
  'dyneq.band2.release',
  'dyneq.band3.attack',
  'dyneq.band3.release',
  'dyneq.channel_mask',
  'dyneq.high.attack',
  'dyneq.high.release',
  'dyneq.low.attack',
  'dyneq.low.release',
  'dyneq.mid.attack',
  'dyneq.mid.release',
  // ---- eq：curve 大参数 + 掩码 ----
  'eq.channel_mask',
  'eq.curve',
  // ---- exciter：声道掩码族（UI 不暴露逐效果掩码） ----
  'exciter.channel_mask',
  // ---- filter：声道掩码族（UI 不暴露逐效果掩码） ----
  'filter.channel_mask',
  // ---- gate：IR 上限查询 + 别名 id + 掩码 ----
  'gate.channel_mask',
  'gate.hold',
  'gate.maxFileMb',
  'gate.maxIrSeconds',
  // ---- gr：GR 计量（只读回读） ----
  'gr.comp',
  'gr.dyneq',
  'gr.dyneq.b1',
  'gr.dyneq.b2',
  'gr.dyneq.b3',
  'gr.dyneq.high',
  'gr.dyneq.low',
  'gr.dyneq.mid',
  'gr.gate',
  'gr.limiter',
  // ---- graph：链顺序（字符串大参数） ----
  'graph.effects',
  'graph.order',
  // ---- input：多声道 balance 分支（UI 仅 1/2） ----
  'input.balance.3',
  'input.balance.4',
  'input.balance.5',
  'input.balance.6',
  'input.balance.7',
  'input.balance.8',
  // ---- limiter：别名 id limiter.release_ms + 掩码 ----
  'limiter.channel_mask',
  'limiter.release_ms',
  // ---- liveprog：Liveprog 代码/状态/参数分支 ----
  'liveprog.code',
  'liveprog.param1',
  'liveprog.param2',
  'liveprog.param3',
  'liveprog.param4',
  'liveprog.param5',
  'liveprog.param6',
  'liveprog.param7',
  'liveprog.param8',
  'liveprog.status',
  'liveprog.unload',
  // ---- loudness：声道掩码族（UI 不暴露逐效果掩码） ----
  'loudness.channel_mask',
  // ---- mode：全局模式查询 ----
  'mode.latency',
  // ---- post：WP0 逐声道补偿（UI 于 WP5 接入） ----
  'post.gain.c0',
  'post.gain.c1',
  'post.gain.c2',
  'post.gain.c3',
  'post.gain.c4',
  'post.gain.c5',
  'post.gain.c6',
  'post.gain.c7',
  // ---- reverb：WP1 混响边界（reverb.engine 只读诊断；predelay/lfe 已接 UI） ----
  'reverb.engine',
  // WP1：freeverb.enable / spatial.fdn / spatial.late 已从 UI 退役，
  // 引擎保留为 deprecated 写别名（旧会话迁移用），UI 不读回。
  'freeverb.enable',
  'spatial.fdn',
  'spatial.late',
  // ---- shelf：声道掩码族（channel_mask 别名仍仅引擎侧） ----
  'shelf.channel_mask',
  // ---- tube：声道掩码族（channel_mask 别名仍仅引擎侧） ----
  'tube.channel_mask',
  // ---- viz：可视化参数 ----
  'viz.fftSize',
};

/// Part E：param_schema 静态解析到、但未挂进 sections（因而不在
/// ParamRegistry.allParams）的孤儿 spec。与实测差集精确相等；
/// 将它们接线进 registry 时同步删此条目。
const Set<String> kOrphanStaticSpecIds = {
  // 待引擎补充（B2 排期，方案文档 2026-10-19 §2.2）：
  // FFTCompander 外围"阈值输入偏移 + 比率增益标度"宏控映射，需 vendor 语义验证 + 听感校准。
  'comp.ratio', // 引擎无 comp.ratio 参数（vendor 多段压缩无比率）；UI 核心滑块 + 传递曲线可视化依赖，暂保留
  'comp.threshold', // 同上：宏观阈值；7 段 gain 已注册进 comp section，macro 本体未挂
};

/// Part D：已登记的"spec.defaultValue ≠ 引擎默认"分歧（P-4 类）。
/// 与实测分歧集合精确相等（双向）——修好一项就删一条；
/// 新增分歧不登记即测试红。
/// 2026-10-19 B-3 定案：A1 九条全部闭合（6 条技术定向 + 3 条听感无差异→
/// Dart 对齐引擎出厂值：gate.hold=10ms / limiter.release=100ms）。
const Map<String, String> kKnownDefaultDivergences = {};

/// Part D：同一引擎成员被多个 spec 引用时默认值必须一致（防别名族互相打架）。
/// 与实测冲突集合精确相等（双向）。
/// 现状：引擎别名族（dynex.low/mid/high.attack 等）在 registry 无同名 spec
/// （attack/release 仅 b1/b2/b3 与总 attack/release 暴露），暂无冲突。
const Set<String> kKnownMemberConflicts = {
  // B2 注册后：comp 7 频段动态 spec（comp.freq1..7）引用同一数组成员 comp_freq[7]，
  // 各槽位默认值不同（95/200/400/800/1600/3400/7500 Hz）——设计预期，非打架。
  'comp_freq',
};

/// Part F：macro 换算别名——UI 域与引擎域量纲不同，范围本应不同，跳过比对。
const Set<String> kRangeCheckSkipSpecIds = {
  'bass.intensity', // UI 0..1 → 引擎 bass.gain 0..15 dB
  'comp.threshold', // UI -48..0 dB → 引擎 comp.gain1..7 -1.2..1.2
};

/// Part F：已登记的"spec 数值范围 ≠ 引擎表范围"分歧。
/// 与实测分歧精确相等（双向）；每条注明方向与待办。
/// 修复方向：以引擎表为准收紧 spec（UI 超界会被 setter 钳位/引擎拒收，
/// 属误导性元数据），或产品确认后反向调整引擎。已修：dynex.low.q /
/// dynex.high.q（spec 0.1..10 → 0.5..2.0，与引擎及 setter 钳位一致）。
///
/// 2026-10-18 UI 排查再修 7 条「UI 超界」（spec 收紧到引擎表口径，setter
/// 补/正 clamp）：bass.subfreq、comp.timeconstant、dyneq.mid.q、filter.q、
/// limiter.release、freeverb.roomsize、freeverb.width。这类超界值经 preset
/// apply / session 回放直达引擎必被拒收 → 回读回弹（块自己变）+ guard
/// 通知，属真实缺陷而非产品取舍。
/// 剩余 5 条均为「UI 收窄」（spec 是引擎范围的子集，UI 选值必在引擎域内，
/// 无拒收风险），收窄是产品取舍，保留登记待产品确认，不得悄悄抹平。
const Map<String, String> kKnownRangeDivergences = {
  'comp.granularity': 'spec 0..2 vs 引擎 0..4（UI 收窄，产品已定案保留 2026-10-19）',
  'comp.tfresolution': 'spec 0..2 vs 引擎 0..3（UI 收窄，产品已定案保留 2026-10-19）',
  'dyneq.attack': 'spec 1..100ms vs 引擎 0.1..100ms（UI 收窄下限）',
  'dyneq.mid.freq': 'spec 200..5000Hz vs 引擎 200..8000Hz（UI 收窄，产品已定案保留 2026-10-19）',
  'dyneq.release': 'spec 10..500ms vs 引擎 10..1000ms（UI 收窄，产品已定案保留 2026-10-19）',
};

// ---------------------------------------------------------------------------
// 源码解析 helpers（静态链；不依赖缩进，全部括号配对）
// ---------------------------------------------------------------------------

/// Part H：定位 engine/ 目录（CWD 基准 ['', '../', '../../']，找不到即抛）。
Directory _locateEngineDir() {
  for (final base in const ['', '../', '../../']) {
    final d = Directory('${base}engine');
    if (d.existsSync()) return d;
  }
  throw StateError('engine/ 目录不存在（CWD 基准漂移？）');
}

/// Part I：定位 lib/ 目录（同上基准，找不到即抛）。
Directory _locateLibDir() {
  for (final base in const ['', '../', '../../']) {
    final d = Directory('${base}lib');
    if (d.existsSync()) return d;
  }
  throw StateError('lib/ 目录不存在（CWD 基准漂移？）');
}

String _read(String relPath) {
  for (final base in const ['', '../', '../../']) {
    final f = File('$base$relPath');
    if (f.existsSync()) return f.readAsStringSync();
  }
  throw StateError('找不到 $relPath（cwd=${Directory.current.path}）');
}

/// state.dart 入口 + lib/core/state/ 全部 part 文件拼成的单一库源码。
///
/// 2026-10-22 拆分：AppModel 的方法陆续迁入 part 文件的
/// `extension ... on AppModel`。静态解析（setter→引擎 id 链、源码形状
/// 不变量）必须覆盖整个库，否则解析面缺失——曾致 convolver.mix 的
/// setFloat helper 断链、误判「无引擎下发」而红。
String _readStateLibrary() {
  for (final base in const ['', '../', '../../']) {
    final f = File('${base}app/auradsp_app/lib/core/state.dart');
    if (!f.existsSync()) continue;
    final src = f.readAsStringSync();
    final dir = Directory('${base}app/auradsp_app/lib/core/state');
    final parts = <String>[];
    if (dir.existsSync()) {
      final files = dir
          .listSync()
          .whereType<File>()
          .where((e) => e.path.endsWith('.dart'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      for (final e in files) {
        parts.add(e.readAsStringSync());
      }
    }
    return [src, ...parts].join('\n');
  }
  throw StateError('找不到 state.dart（cwd=${Directory.current.path}）');
}

List<String> _sorted(Set<String> s) => (s.toList()..sort());

/// 去掉行注释与块注释（解析前必须剥离，否则注释里的 id 字样会污染链）。
String _stripComments(String src) => src
    .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), ' ')
    .replaceAll(RegExp(r'//[^\n]*'), ' ');

/// 圆括号配对：从 openIdx 处的 '(' 找到配对 ')'，返回内容区间 (start, end)。
(int, int) _matchParens(String src, int openIdx) {
  var depth = 0;
  for (var j = openIdx; j < src.length; j++) {
    final c = src[j];
    if (c == '(') {
      depth++;
    } else if (c == ')') {
      depth--;
      if (depth == 0) return (openIdx + 1, j);
    }
  }
  return (openIdx + 1, src.length);
}

/// 花括号配对：从 openIdx 处的 '{' 找到配对 '}'，返回内容区间。
(int, int) _matchBraces(String src, int openIdx) {
  var depth = 0;
  for (var j = openIdx; j < src.length; j++) {
    final c = src[j];
    if (c == '{') {
      depth++;
    } else if (c == '}') {
      depth--;
      if (depth == 0) return (openIdx + 1, j);
    }
  }
  return (openIdx + 1, src.length);
}

class _SpecInfo {
  final String name;
  final String id;
  final String setter; // setter 表达式原文（块内、已剥注释）
  _SpecInfo(this.name, this.id, this.setter);
}

/// 静态解析 param_schema.dart 全部 `ParamSpec<T>(...)`（含未挂 section 的孤儿）。
List<_SpecInfo> _parseSpecs(String schemaSrc) {
  final out = <_SpecInfo>[];
  final re = RegExp(r'static final (\w+) = ParamSpec<[^>]*>\(');
  for (final m in re.allMatches(schemaSrc)) {
    final open = m.end - 1; // '(' 下标
    final (s, e) = _matchParens(schemaSrc, open);
    final block = _stripComments(schemaSrc.substring(s, e));
    final idm = RegExp(r"id: '([^']*)'").firstMatch(block);
    final stm = RegExp(r'setter:\s*(.*)$', dotAll: true).firstMatch(block);
    if (idm == null || stm == null) continue;
    var setter = stm.group(1)!.trim();
    // 块内容已排除 ParamSpec(...) 的外层括号，只需去掉行尾逗号
    setter = setter.replaceFirst(RegExp(r',\s*$'), '').trim();
    out.add(_SpecInfo(m.group(1)!, idm.group(1)!, setter));
  }
  return out;
}

/// state 库内全部方法体：AppModel 类体 + 所有 `extension ... on AppModel`
/// 体（2026-10-22 拆分后方法在 part 文件的 extension 内，同库拼源后一并
/// 扫描）。类/extension 延伸到各自文件尾且混合缩进，必须括号配对；方法体
/// 定位要先跳过参数表的 ')'（可选 {…} 命名参数）。
Map<String, String> _parseMethods(String stateSrc) {
  final bodies = <String>[];
  final cls = stateSrc.indexOf('class AppModel extends ChangeNotifier {');
  if (cls < 0) {
    throw StateError('state.dart 应含 class AppModel');
  }
  final copen = stateSrc.indexOf('{', cls);
  final (bs, be) = _matchBraces(stateSrc, copen);
  bodies.add(stateSrc.substring(bs, be));
  for (final m in RegExp(r'extension \w+ on AppModel \{').allMatches(stateSrc)) {
    final obr = stateSrc.indexOf('{', m.start);
    final (es, ee) = _matchBraces(stateSrc, obr);
    bodies.add(stateSrc.substring(es, ee));
  }
  final out = <String, String>{};
  final re = RegExp(r'(?:^|\n)\s*(?:void|Future<void>|Future<[^>]*>) (\w+)\(');
  for (final body in bodies) {
    for (final m in re.allMatches(body)) {
      final popen = m.end - 1;
      final (_, pe) = _matchParens(body, popen);
      // 方法体 '{' 必须在参数表 ')' 之后（可选 {…} 命名参数的花括号不是体）
      final obr = body.indexOf('{', pe);
      if (obr < 0) continue;
      final (ms, me) = _matchBraces(body, obr);
      out[m.group(1)!] = _stripComments(body.substring(ms, me));
    }
  }
  return out;
}

/// auradsp_ffi.dart 的 ParamId 常量表与函数形式模板。
/// 返回 name → 引擎 id（函数形式以 '$ch' 作占位符，如 input.balance.$ch）。
Map<String, String> _parseParamIdConsts(String ffiSrc) {
  final start = ffiSrc.indexOf('class ParamId');
  if (start < 0) {
    throw StateError('auradsp_ffi.dart 应含 class ParamId');
  }
  final obr = ffiSrc.indexOf('{', start);
  final (bs, be) = _matchBraces(ffiSrc, obr);
  final body = ffiSrc.substring(bs, be);
  final out = <String, String>{};
  // static const xxx = 'engine.id';（类型可省略，如 static const arbmagString = ...）
  for (final m
      in RegExp(r"static const (?:\w+\s+)?(\w+) = '([^']*)'").allMatches(body)) {
    out[m.group(1)!] = m.group(2)!;
  }
  // static String inputBalance(int ch) => 'input.balance.$ch';
  for (final m in RegExp(r"static String (\w+)\([^)]*\) => '([^']*)'")
      .allMatches(body)) {
    out[m.group(1)!] = m.group(2)!;
  }
  return out;
}

String _resolveArg(String arg, Map<String, String> consts) {
  if (!arg.startsWith('ParamId.')) {
    return arg.substring(1, arg.length - 1); // 去引号
  }
  final rest = arg.substring('ParamId.'.length);
  // 函数形式 ParamId.inputBalance(1) / ParamId.inputBalance (1)
  final fm = RegExp(r'(\w+)\s*\(\s*(\d+)\s*\)').firstMatch(rest);
  if (fm != null) {
    final tpl = consts[fm.group(1)!];
    if (tpl == null) return 'UNRESOLVED_FN:${fm.group(1)}';
    return tpl.replaceAll(r'$ch', fm.group(2)!);
  }
  return consts[rest] ?? 'UNRESOLVED_CONST:$rest';
}

/// 一段（已剥注释的）代码里引用的引擎 id 集合。
/// 采集三层口径，由宽到净：
///   1) setInt/Float/String(ARG) 首参 与 send map 的 'id': ARG；
///   2) 形如引擎 id 的字符串字面量（含 'stereo.band${i + 1}' 模板）；
///   3) 任意 ParamId.X / ParamId.f(n) 引用。
/// 第 2/3 层是宽口径（可能收进未真正下发的 id），只做"存在性"断言，
/// 不会因宽口径漏报；漏收不可能发生（宽口径 ⊇ 窄口径）。
Set<String> _chainIds(String code, Map<String, String> consts) {
  final ids = <String>{};
  final argRe = RegExp(r"""set(?:Int|Float|String)\(\s*(ParamId\.\w+(?:\s*\(\s*\d+\s*\))?|'[^']*')""");
  final sendRe = RegExp(r"""'id':\s*(ParamId\.\w+(?:\s*\(\s*\d+\s*\))?|'[^']*')""");
  for (final m in argRe.allMatches(code)) {
    ids.add(_resolveArg(m.group(1)!, consts));
  }
  for (final m in sendRe.allMatches(code)) {
    ids.add(_resolveArg(m.group(1)!, consts));
  }
  // 引擎 id 形字符串（允许 ${...} 模板与尾段数字如 input.balance.1）
  final litRe = RegExp(r"""'([a-z][a-z0-9_]*(?:\.[a-z0-9][a-zA-Z0-9_]*)+(?:\$\{[^}]*\})?[^']*)'""");
  for (final m in litRe.allMatches(code)) {
    if (m.group(1)!.contains('.')) ids.add(m.group(1)!);
  }
  for (final m in RegExp(r'\bParamId\.(\w+)(?:\s*\(\s*(\d+)\s*\))?').allMatches(code)) {
    final fn = m.group(1)!;
    final num = m.group(2);
    final tpl = consts[fn];
    if (num != null && tpl != null) {
      ids.add(tpl.replaceAll(r'$ch', num));
    } else if (tpl != null) {
      ids.add(tpl);
    } else {
      ids.add('UNRESOLVED_CONST:$fn');
    }
  }
  return ids;
}

/// 从 setter 方法体出发做传递方法追踪（深限 4，visited 防环），
/// 汇总全部可达方法体的引擎 id 引用。
Set<String> _transitiveChainIds(
  String methodName,
  Map<String, String> methods,
  Map<String, String> consts, [
  Set<String>? visited,
  int depth = 0,
]) {
  visited ??= <String>{};
  final body = methods[methodName];
  if (body == null || depth > 4) return <String>{};
  final ids = _chainIds(body, consts);
  for (final m
      in RegExp(r'(?:^|[^.\w$])([a-zA-Z_]\w*)\s*\(').allMatches(body)) {
    final fn = m.group(1)!;
    if (const {'if', 'for', 'while', 'switch', 'return', 'catch', 'setInt',
              'setFloat', 'setString'}.contains(fn)) {
      continue;
    }
    if (methods.containsKey(fn) && !visited.contains(fn)) {
      visited.add(fn);
      ids.addAll(_transitiveChainIds(fn, methods, consts, visited, depth + 1));
    }
  }
  return ids;
}

/// 模板串展开：'stereo.band${i + 1}' → stereo.band1..8 等已知形态。
Set<String> _expandTemplates(Iterable<String> ids) {
  final out = <String>{};
  for (final id in ids) {
    if (!id.contains(r'$')) {
      out.add(id);
      continue;
    }
    for (var n = 1; n <= 8; n++) {
      out.add(id.replaceAll(RegExp(r'\$\{[^}]*\}'), '$n'));
    }
  }
  return out;
}

class _ChainResult {
  final bool writesEngine; // false = setter 不向引擎下发任何参数
  final Set<String> chain; // 展开后的引擎 id 集合（writesEngine 时非空）
  final String? shapeError; // 形态无法解析 / 方法体缺失的说明
  _ChainResult(this.writesEngine, this.chain, this.shapeError);
}

/// setter 表达式的形态分类 + 引擎 id 链解析（Part B 两测试共用同一事实源）。
/// 形态：内联 m.setX('lit') / m.setX(v) / m.setX(N, v) / m.setX('UI名', v) /
///       字段直赋 / 空实现 / 块体 { ... m.setXxx(...) ... }。
_ChainResult _resolveSetterChain(
  _SpecInfo spec,
  Map<String, String> methods,
  Map<String, String> consts,
) {
  var sexp = spec.setter.trim();
  sexp = sexp.replaceFirst(RegExp(r'^\(m,\s*v\)\s*(?:=>\s*)?'), '').trim();

  // 字段直赋 m.xxx = v
  final field = RegExp(r'^m\.(\w+)\s*=\s*v').hasMatch(sexp);
  if (field || sexp == '{}') {
    return _ChainResult(false, <String>{}, null);
  }

  // 形态 1：单行内联 m.setX('literal', ...)
  final inl =
      RegExp(r"""^m\.set(?:Int|Float|String)\('([^']*)'""").firstMatch(sexp);
  if (inl != null) {
    return _ChainResult(true, _expandTemplates({inl.group(1)!}), null);
  }

  // 形态 2/3/4：m.setX(v) / m.setX(N, v) / m.setX('UI短名', v)
  final call = RegExp(r'^m\.(\w+)\(').firstMatch(sexp);
  if (call != null) {
    final methodName = call.group(1)!;
    final target = methods.containsKey(methodName)
        ? methodName
        : (kSetterHelper[methodName] ?? '');
    if (!methods.containsKey(target)) {
      return _ChainResult(false, <String>{}, '找不到 m.$methodName(...) 对应方法体');
    }
    // 传递追踪已覆盖 helper（setter 方法体内直接调用，如 setStereoBand →
    // _pushStereoChain）；helper 体不再需要手工拼接。
    final chain = _expandTemplates(
        _transitiveChainIds(target, methods, consts));
    if (chain.isEmpty) {
      return _ChainResult(false, <String>{}, null);
    }
    return _ChainResult(true, chain, null);
  }

  // 形态 5：块体 { ... m.setXxx(...) ... }（如 arbmag.string）
  if (sexp.startsWith('{')) {
    final chain = <String>{};
    for (final m in RegExp(r'm\.(\w+)\s*\(').allMatches(sexp)) {
      if (methods.containsKey(m.group(1)!)) {
        chain.addAll(_expandTemplates(
            _transitiveChainIds(m.group(1)!, methods, consts)));
      }
    }
    if (chain.isEmpty) {
      return _ChainResult(false, <String>{}, null);
    }
    return _ChainResult(true, chain, null);
  }

  return _ChainResult(false, <String>{}, 'setter 形态无法解析（$sexp）');
}

/// 通过库自带 generic 包装 write 调用 setter。
/// 不能直接访问 spec.setter 字段——裸泛型 `ParamSpec<dynamic>` 视图下字段读取
/// 会与具体闭包类型 `(AppModel, double) => void` 做函数子类型检查而抛
/// "is not a subtype of type '(AppModel, dynamic) => void'"；
/// write() 内部按接收者的 reified T 调用，规避该检查（实测可用）。
void _invokeSetter(ParamSpec spec, AppModel m, Object value) {
  spec.write(m, value);
}

void main() {
  final schemaSrc = _read('app/auradsp_app/lib/core/param_schema.dart');
  final stateSrc = _readStateLibrary();
  final ffiSrc = _read('app/auradsp_app/lib/engine/auradsp_ffi.dart');
  final engineParamTableSrc = _read('engine/engine_param_table.h');
  final engineInternalSrc = _read('engine/engine_internal.h');
  final engineCreateSrc = _read('engine/auradsp_engine.cpp');

  final specs = _parseSpecs(schemaSrc);
  final methods = _parseMethods(stateSrc);
  final consts = _parseParamIdConsts(ffiSrc);

  final engineAllIds = <String>{
    ...kParamDefaultRows.map((r) => r.engineId),
    ...kEngineCustomOnlyParamIds,
    ...kEngineDynamicParamIds,
  };

  // alias 反查：引擎 id → spec id（Part D 的 spec 定位）
  final aliasReverse = <String, String>{};
  kAliasToEngineId.forEach((specId, engineIds) {
    for (final e in engineIds) {
      aliasReverse[e] = specId;
    }
  });

  group('Part A — getter/setter 运行时闭环（allParams 全覆盖）', () {
    test('每个 spec 的 setter 必须可感知写入自身 getter 并可还原', () {
      final m = AppModel(testing: true);
      final failures = <String>[];
      var checked = 0;
      for (final spec in ParamRegistry.allParams) {
        if (kNonRoundtripSpecIds.contains(spec.id)) continue;
        checked++;
        final old = spec.getter(m);
        Object probe;
        if (spec.type == ParamType.boolean) {
          probe = !(old as bool);
        } else if (spec.type == ParamType.string) {
          probe = '__probe__';
        } else {
          final o = (old as num).toDouble();
          var p = (spec.min + spec.max) / 2;
          if ((p - o).abs() < 1e-9) {
            p = spec.max - (spec.max - spec.min) * 0.25;
          }
          probe = spec.type == ParamType.int32 ? p.round() : p;
        }
        try {
          _invokeSetter(spec, m, probe);
        } catch (e) {
          failures.add('${spec.id}: setter 抛异常 $e');
          continue;
        }
        final now = spec.getter(m);
        final same = (spec.type == ParamType.string ||
                spec.type == ParamType.boolean)
            ? (now == probe)
            : ((now as num).toDouble() - (probe as num).toDouble()).abs() <
                1e-9;
        if (!same) {
          failures.add('${spec.id}: setter 后 getter 读到 $now，期望 $probe'
              '（setter 写错字段？）');
        }
        // 还原
        _invokeSetter(spec, m, old as Object);
        final back = spec.getter(m);
        final restored = (spec.type == ParamType.string ||
                spec.type == ParamType.boolean)
            ? (back == old)
            : ((back as num).toDouble() - (old as num).toDouble()).abs() < 1e-9;
        if (!restored) {
          failures.add('${spec.id}: 还原失败 getter=$back，原值 $old');
        }
      }
      expect(checked, greaterThan(120),
          reason: 'Part A 实测覆盖 $checked 个 spec，覆盖度异常');
      expect(failures, isEmpty,
          reason: 'Part A 闭环失败 ${failures.length} 项：\n'
              '${failures.join('\n')}');
    });
  });

  group('Part B — setter→引擎 id 静态映射链（S-2 回归门禁）', () {
    test('全链解析：alias 命中或直连；无引擎下发的形态必须登记', () {
      final failures = <String>[];
      final detectedNoWrite = <String>{};
      for (final spec in specs) {
        final expected = kAliasToEngineId[spec.id] ?? <String>{spec.id};
        final r = _resolveSetterChain(spec, methods, consts);

        if (r.shapeError != null) {
          failures.add('${spec.id}: ${r.shapeError} —— 新形态须在此显式登记');
          continue;
        }
        if (!r.writesEngine) {
          detectedNoWrite.add(spec.id);
          if (!kNoEngineWriteSpecIds.contains(spec.id)) {
            failures.add('${spec.id}: setter 不向引擎下发任何参数，'
                '但未登记 kNoEngineWriteSpecIds');
          }
          continue;
        }

        final unresolved = r.chain.where((c) => c.startsWith('UNRESOLVED_'));
        if (unresolved.isNotEmpty) {
          failures.add('${spec.id}: 链中含未解析 ParamId ${unresolved.join(', ')}'
              '（auradsp_ffi.dart 常量表缺漏？）');
        }

        // UI-only spec：引擎无对应 id，跳过期望断言（形态已由上面检测）
        if (kUiOnlySpecIds.contains(spec.id)) continue;

        final missing = expected.where((e) => !r.chain.contains(e)).toList();
        if (missing.isNotEmpty) {
          failures.add('${spec.id}: setter 链 [${_sorted(r.chain).join(', ')}] '
              '不包含期望引擎 id ${missing.join(', ')}'
              '${kAliasToEngineId.containsKey(spec.id) ? '（已登记 alias）' : '（未登记 alias，若是合法差异请补）'}');
        }
      }
      expect(failures, isEmpty,
          reason: 'Part B 链校验失败 ${failures.length} 项：\n'
              '${failures.join('\n')}');
    });

    test('kNoEngineWriteSpecIds 与检测结果精确相等（双向）', () {
      final detectedNoWrite = <String>{};
      for (final spec in specs) {
        final r = _resolveSetterChain(spec, methods, consts);
        if (r.shapeError == null && !r.writesEngine) {
          detectedNoWrite.add(spec.id);
        }
      }
      expect(_sorted(detectedNoWrite), _sorted(kNoEngineWriteSpecIds),
          reason: 'kNoEngineWriteSpecIds 必须与实测"无引擎下发"集合精确相等：\n'
              '实测多出: ${_sorted(detectedNoWrite.difference(kNoEngineWriteSpecIds))}\n'
              '白名单多出: ${_sorted(kNoEngineWriteSpecIds.difference(detectedNoWrite))}');
    });
  });

  group('Part C — 引擎权威 id ↔ registry spec id 双向对账', () {
    test('差集必须与白名单精确相等（双向）', () {
      final specIds = ParamRegistry.allParams.map((s) => s.id).toSet();
      // spec 侧经 alias 归一到引擎名后比较（一对多全展开）
      final normalizedSpec = <String>{
        for (final id in specIds) ...(kAliasToEngineId[id] ?? <String>{id})
      };

      final uiOnly = normalizedSpec.difference(engineAllIds);
      final engineOnly = engineAllIds.difference(normalizedSpec);

      expect(_sorted(uiOnly), _sorted(kUiOnlySpecIds),
          reason: 'UI 有 / 引擎无的集合必须与 kUiOnlySpecIds 精确相等：\n'
              '实测多出: ${_sorted(uiOnly.difference(kUiOnlySpecIds))}\n'
              '白名单多出: ${_sorted(kUiOnlySpecIds.difference(uiOnly))}');
      expect(_sorted(engineOnly), _sorted(kEngineOnlyIds),
          reason: '引擎有 / UI 无的集合必须与 kEngineOnlyIds 精确相等：\n'
              '实测多出: ${_sorted(engineOnly.difference(kEngineOnlyIds))}\n'
              '白名单多出: ${_sorted(kEngineOnlyIds.difference(engineOnly))}');
    });

    test('fixture 覆盖引擎表全部参数（fixture 自身完整性）', () {
      final tableIds = RegExp(r'PARAM_(?:FLOAT|INT|BOOL|CUSTOM\w*)\("([^"]+)"')
          .allMatches(engineParamTableSrc)
          .map((m) => m.group(1)!)
          .toSet();
      expect(
        tableIds.length,
        greaterThan(150),
        reason: 'param_table 解析应覆盖 214 个参数（当前 ${tableIds.length}）',
      );
      final fixtureIds = <String>{
        ...kParamDefaultRows.map((r) => r.engineId),
        ...kEngineCustomOnlyParamIds,
      };
      final missing = tableIds.difference(fixtureIds);
      expect(missing, isEmpty,
          reason: 'fixture 未覆盖引擎表 id：\n${missing.join('\n')}');
    });
  });

  group('Part D — 默认值一致性（P-4 回归门禁）', () {
    test('fixture 行数哨兵匹配（引擎源码变更未重生即失败）', () {
      final expected = 'param_table:${const LineSplitter().convert(engineParamTableSrc).length}'
          ';internal:${const LineSplitter().convert(engineInternalSrc).length}'
          ';create:${const LineSplitter().convert(engineCreateSrc).length}';
      expect(kContractLineCounts, expected,
          reason: '引擎源码行数与 fixture 哨兵不一致'
              '（期望 $expected，fixture 为 $kContractLineCounts）。'
              '若刚改过 engine_param_table.h / engine_internal.h / '
              'auradsp_engine.cpp，请重跑 '
              'tools/gen_param_contract.py 再生 fixture');
    });

    test('spec.defaultValue 与引擎默认全量一致（分歧须登记）', () {
      final failures = <String>[];
      final mismatches = <String>[];
      for (final row in kParamDefaultRows) {
        // spec 定位：先按引擎 id 直查，再走 alias 反查
        final spec = ParamRegistry.byId[row.engineId] ??
            ParamRegistry.byId[aliasReverse[row.engineId] ?? ''];
        if (spec == null) {
          if (!kEngineOnlyIds.contains(row.engineId)) {
            failures.add('${row.engineId}: 引擎有默认值但无 spec（含 alias），'
                '且未登记 kEngineOnlyIds');
          }
          continue;
        }
        final dv = spec.defaultValue;
        final cd = row.cppDefault;
        bool ok;
        if (dv is bool) {
          ok = (cd as int) == (dv ? 1 : 0);
        } else if (dv is int) {
          ok = dv == cd;
        } else if (dv is double) {
          ok = (dv - (cd as double)).abs() < 1e-6;
        } else {
          ok = true; // string 等非数值默认跳过（引擎侧无默认概念）
        }
        if (!ok) {
          mismatches.add(row.engineId);
          if (!kKnownDefaultDivergences.containsKey(row.engineId)) {
            failures.add('${row.engineId}: 引擎默认 $cd ≠ '
                'spec.defaultValue $dv（成员 ${row.cppMember}）'
                ' —— 未登记 kKnownDefaultDivergences');
          }
        }
      }
      expect(failures, isEmpty,
          reason: 'Part D 默认值失败 ${failures.length} 项：\n'
              '${failures.join('\n')}');
      expect(_sorted(mismatches.toSet()), _sorted(kKnownDefaultDivergences.keys.toSet()),
          reason: '实测分歧必须与 kKnownDefaultDivergences 精确相等'
              '（修好一项请从表中删除）：\n'
              '实测多出: ${_sorted(mismatches.toSet().difference(kKnownDefaultDivergences.keys.toSet()))}\n'
              '表内多余: ${_sorted(kKnownDefaultDivergences.keys.toSet().difference(mismatches.toSet()))}');
    });

    test('同一引擎成员的 spec 默认不得互相打架', () {
      // row.engineId → spec（alias 归一）；按 cppMember 分组找冲突
      final byMember = <String, Set<String>>{};
      for (final row in kParamDefaultRows) {
        final spec = ParamRegistry.byId[row.engineId] ??
            ParamRegistry.byId[aliasReverse[row.engineId] ?? ''];
        if (spec == null) continue;
        final key = '${spec.defaultValue.runtimeType}:${spec.defaultValue}';
        byMember.putIfAbsent(row.cppMember, () => <String>{}).add(key);
      }
      final conflicts = byMember.entries
          .where((e) => e.value.length > 1)
          .map((e) => e.key)
          .toSet();
      expect(_sorted(conflicts), _sorted(kKnownMemberConflicts),
          reason: '同引擎成员多 spec 默认冲突必须与 kKnownMemberConflicts 精确相等：\n'
              '实测冲突: ${_sorted(conflicts)}\n'
              '登记表: ${_sorted(kKnownMemberConflicts)}\n'
              '明细: ${byMember.entries.where((e) => e.value.length > 1).map((e) => '${e.key}=${e.value}').join('; ')}');
    });
  });

  group('Part E — 覆盖度自检（防测试本身漏项）', () {
    test('registry 与静态解析的差集 = 已知孤儿 spec（精确相等）', () {
      final ids = specs.map((s) => s.id).toSet();
      expect(ids.length, specs.length,
          reason: 'param_schema 静态解析出现重复 id');
      final allIds = ParamRegistry.allParams.map((s) => s.id).toSet();
      expect(allIds.difference(ids), isEmpty,
          reason: 'ParamRegistry.allParams 含静态解析不到的 id'
              '（动态生成未在此登记？）：\n'
              '${allIds.difference(ids).join('\n')}');
      expect(_sorted(ids.difference(allIds)), _sorted(kOrphanStaticSpecIds),
          reason: '静态 spec 未挂 section（孤儿）集合必须与 '
              'kOrphanStaticSpecIds 精确相等：\n'
              '实测多出: ${_sorted(ids.difference(allIds).difference(kOrphanStaticSpecIds))}\n'
              '表内多余: ${_sorted(kOrphanStaticSpecIds.difference(ids.difference(allIds)))}');
      // 参与 Part B 的 spec 数（静态全量）与 Part A（registry）都要有量
      expect(specs.length, greaterThan(140));
      expect(allIds.length, greaterThan(120));
    });

    test('白名单完整性：登记项必须真实存在于对应集合', () {
      final allSpecIds = specs.map((s) => s.id).toSet();
      final registryIds = ParamRegistry.allParams.map((s) => s.id).toSet();
      // 形态/闭环类白名单 ⊆ 静态解析
      for (final id in {...kNoEngineWriteSpecIds, ...kNonRoundtripSpecIds}) {
        expect(allSpecIds, contains(id),
            reason: '$id 不在 param_schema 静态解析结果中（白名单腐烂？）');
      }
      // alias / uiOnly 的 key 必须存在于静态解析
      for (final id in kAliasToEngineId.keys) {
        expect(allSpecIds, contains(id),
            reason: 'alias key $id 不是已知 spec');
      }
      for (final id in kUiOnlySpecIds) {
        expect(registryIds, contains(id),
            reason: 'kUiOnlySpecIds 的 $id 不在 ParamRegistry.allParams'
                '（Part C 差集由 registry 推导，白名单腐烂？）');
      }
      // helper 指向的方法必须存在
      for (final h in kSetterHelper.values) {
        expect(methods.containsKey(h), isTrue,
            reason: 'kSetterHelper 指向的 $h 在 state.dart 不存在');
      }
    });
  });

  group('Part F — spec 数值范围 ↔ 引擎表范围一致性', () {
    test('范围分歧须登记（macro 换算别名除外）', () {
      final failures = <String>[];
      final diverged = <String>{};
      var compared = 0;
      for (final row in kEngineRangeRows) {
        final spec = ParamRegistry.byId[row.engineId] ??
            ParamRegistry.byId[aliasReverse[row.engineId] ?? ''];
        if (spec == null) continue; // 引擎独有 id：Part C 已管
        if (kRangeCheckSkipSpecIds.contains(spec.id)) continue;
        compared++;
        if ((spec.min - row.min).abs() > 1e-9 ||
            (spec.max - row.max).abs() > 1e-9) {
          diverged.add(row.engineId);
          if (!kKnownRangeDivergences.containsKey(row.engineId)) {
            failures.add('${row.engineId}: spec 范围 [${spec.min}, ${spec.max}] ≠ '
                '引擎 [${row.min}, ${row.max}]（spec ${spec.id}）'
                ' —— 未登记 kKnownRangeDivergences');
          }
        }
      }
      expect(compared, greaterThan(80),
          reason: 'Part F 实测仅比对 $compared 个 spec，覆盖度异常');
      expect(failures, isEmpty,
          reason: 'Part F 范围分歧失败 ${failures.length} 项：\n'
              '${failures.join('\n')}');
      expect(_sorted(diverged), _sorted(kKnownRangeDivergences.keys.toSet()),
          reason: '实测范围分歧必须与 kKnownRangeDivergences 精确相等'
              '（修好一项请从表中删除）：\n'
              '实测多出: ${_sorted(diverged.difference(kKnownRangeDivergences.keys.toSet()))}\n'
              '表内多余: ${_sorted(kKnownRangeDivergences.keys.toSet().difference(diverged))}');
    });
  });

  group('Part G — 延迟探针支持集 ↔ 引擎 probe_is_supported 一致', () {
    test('isLatencyProbeSupported 不得越过引擎 kSupported（资源型除外）', () {
      // 引擎侧权威表
      final probeSrc = _stripComments(_read('engine/chain/engine_probe.cpp'));
      final em = RegExp(r'kSupported\[\]\s*=\s*\{([^}]*)\}')
          .firstMatch(probeSrc);
      expect(em, isNotNull,
          reason: 'engine_probe.cpp 找不到 kSupported 表（重构了？）');
      final engineSupported = RegExp('"([^"]+)"')
          .allMatches(em!.group(1)!)
          .map((e) => e.group(1)!)
          .toSet();
      expect(engineSupported.length, greaterThanOrEqualTo(15),
          reason: '引擎 kSupported 解析异常: $engineSupported');

      // Dart 侧集合（剥注释后定位，注释里出现的组件名不得计入）
      final st = _stripComments(_readStateLibrary());
      final dm = RegExp(r'isLatencyProbeSupported\(String compId\)\s*=>\s*'
              r'const\s*\{([^}]*)\}\.contains\(compId\)')
          .firstMatch(st);
      expect(dm, isNotNull,
          reason: 'state.dart 解析不到 isLatencyProbeSupported 集合');
      final dartSet = RegExp("'([^']+)'")
          .allMatches(dm!.group(1)!)
          .map((e) => e.group(1)!)
          .toSet();
      expect(dartSet.length, greaterThanOrEqualTo(15),
          reason: 'Dart 探针集解析异常: $dartSet');

      // 资源型组件：引擎空探针返回 -1，但 IR/VDC 资源已加载时可测
      // （latencyProbeResource 提供路径）——显式白名单放行。
      const resourceBased = {'convolver', 'ddc'};
      final overreach = dartSet.difference(engineSupported).difference(resourceBased);
      expect(overreach, isEmpty,
          reason: 'isLatencyProbeSupported 含引擎 kSupported 之外的组件'
              '（↻ 显示但引擎返回 -1 = 假接通；且历史上配假测量分支冒充实测）: '
              '${_sorted(overreach)}');

      // 资源型白名单自身也要如实：这两个名字在 Dart 集合中必须存在且在
      // latencyProbeResource 有分支（防止白名单腐烂成永久豁免）。
      for (final c in resourceBased) {
        expect(dartSet.contains(c), isTrue, reason: '资源型 $c 不在 Dart 探针集');
      }
      final resSrc = _stripComments(_readStateLibrary());
      final rm = RegExp(r'latencyProbeResource\(String compId\)\s*\{([\s\S]*?)\n  \}')
          .firstMatch(resSrc);
      expect(rm, isNotNull, reason: '解析不到 latencyProbeResource');
      for (final c in resourceBased) {
        expect(rm!.group(1)!.contains("'$c'"), isTrue,
            reason: 'latencyProbeResource 缺少 $c 分支，白名单豁免失效');
      }

      // 2026-10-19 补：别名探针（合并卡 → 引擎实名）目标必须全部在
      // 引擎 kSupported 内（bass_shaping → shelf + bassmono）。
      final am = RegExp(r'kLatencyProbeAliases\s*=\s*\{([^;]*?)\};', dotAll: true)
          .firstMatch(st);
      expect(am, isNotNull, reason: '解析不到 kLatencyProbeAliases');
      final aliasEntries =
          RegExp(r"'([^']+)':\s*\[([^\]]*)\]").allMatches(am!.group(1)!).toList();
      expect(aliasEntries, isNotEmpty, reason: 'kLatencyProbeAliases 解析为空');
      for (final e in aliasEntries) {
        final targets =
            RegExp("'([^']+)'").allMatches(e.group(2)!).map((m) => m.group(1)!).toSet();
        expect(targets, isNotEmpty, reason: '别名 ${e.group(1)} 目标为空');
        final missing = targets.difference(engineSupported);
        expect(missing, isEmpty,
            reason: '别名探针 ${e.group(1)} 的目标 $missing 不在引擎 kSupported');
      }

      // 2026-10-19：haas/spatial 探针升级为「逐声道首非零取最大」，已可如实
      // 测量（haas 测当前延迟、spatial 测 0ms 诚实链延迟）——不再是
      // 「结构性不可测」，必须出现在引擎 kSupported 与 Dart 真探针集中，
      // 否则 ↻ 按钮显示却引擎返回 -1 就是假接通。
      for (final c in const {'haas', 'spatial'}) {
        expect(engineSupported.contains(c), isTrue,
            reason: '引擎 kSupported 缺失 $c（探针升级后必须可测）');
        expect(dartSet.contains(c), isTrue,
            reason: 'Dart 探针集缺失 $c');
      }
    });
  });

  // ---------------------------------------------------------------------------
  // Part H：引擎错误 reason-token 白名单契约（B-2 / 计划 D2 §4.3）
  // ---------------------------------------------------------------------------
  group('Part H 引擎错误 reason-token 契约', () {
    test('set_error 字面量全部匹配 <subject>: <token>[ (detail)] 语法', () {
      final tokens = kEngineReasonTokens;
      final grammar = RegExp('^[a-zA-Z][a-zA-Z0-9_.]*: ('
          '${tokens.map(RegExp.escape).join('|')}'
          r')( \(.*\))?$');
      final literal = RegExp(r'set_error\(\s*h\s*,\s*"([^"]*)"');
      final bad = <String>[];
      var checked = 0;
      final engineDir = _locateEngineDir();
      for (final f in engineDir.listSync(recursive: true).whereType<File>()
          .where((f) => f.path.endsWith('.h') || f.path.endsWith('.hpp')
              || f.path.endsWith('.c') || f.path.endsWith('.cpp'))) {
        final lines = f.readAsLinesSync();
        for (var n = 0; n < lines.length; n++) {
          for (final m in literal.allMatches(lines[n])) {
            checked++;
            if (!grammar.hasMatch(m.group(1)!)) {
              final rel = f.path.replaceFirst(engineDir.path, 'engine');
              bad.add('$rel:${n + 1}  ${m.group(1)}');
            }
          }
        }
      }
      expect(checked, greaterThan(60),
          reason: '引擎 set_error 字面量数量异常（扫描静默失败？）');
      expect(bad, isEmpty, reason: '''
未登记 token：请在 lib/core/engine_error_map.dart kEngineReasonTokens +
lib/l10n/app_{zh,en,ja}.arb（errXxx）+ 引擎侧三方同步登记后再落引擎（R4 登记指引）。
违规清单：
${bad.join('\n')}''');
    });

    test('null handle 特殊返回仍登记（bare 白名单唯一成员）', () {
      final src = _read('engine/auradsp_engine.cpp');
      expect(src, contains('h->last_error : "null handle"'),
          reason: 'auradsp_last_error 的 null-handle 兜底被改动（B-2 契约约束）');
    });

    test('arb 三语为全部 token 提供词条', () {
      for (final tok in kEngineReasonTokens) {
        final key = engineReasonArbKey(tok);
        for (final lang in const ['zh', 'en', 'ja']) {
          final arb = jsonDecode(_read('app/auradsp_app/lib/l10n/app_$lang.arb'))
              as Map<String, dynamic>;
          expect(arb.containsKey(key), isTrue,
              reason: 'token "$tok" → $key 缺失于 app_$lang.arb（新增 token 未登记）');
        }
      }
    });
  });

  // ---------------------------------------------------------------------------
  // Part I：别名收敛契约（B-3 / 计划 §5.2 第三步）——Dart 仅引用规范 id
  // ---------------------------------------------------------------------------
  group('Part I 别名收敛（Dart 仅引用规范 id）', () {
    test('lib/ 零引用引擎别名 id（channel_mask/dyneq 别名族/ms 别名/gr 别名）', () {
      final aliasRe = RegExp(
          r"(channel_mask|dyneq\.(?:low|mid|high|band[123])\.(?:attack|release)|"
          r"gate\.hold_ms|limiter\.release_ms|gr\.dyneq\.(?:low|mid|high))");
      final hits = <String>[];
      final libDir = _locateLibDir();
      final engineBoundary = '${Platform.pathSeparator}engine${Platform.pathSeparator}';
      for (final f in libDir.listSync(recursive: true).whereType<File>()
          .where((f) => f.path.endsWith('.dart')
              && !f.path.contains(engineBoundary))) {
        final lines = f.readAsLinesSync();
        for (var n = 0; n < lines.length; n++) {
          if (aliasRe.hasMatch(lines[n])) {
            hits.add('${f.path.replaceFirst(libDir.path, 'lib')}:${n + 1}  '
                '${lines[n].trim()}');
          }
        }
      }
      expect(hits, isEmpty, reason: '''
Dart 引用了引擎别名 id（非规范名）：请改用规范 id（*.channels / dyneq.b1..b3.* /
gate.hold / limiter.release / gr.dyneq.b1..b3），引擎表已标 deprecated。
违规清单：
${hits.join('\n')}''');
    });
  });

  // ---------------------------------------------------------------------------
  // Part J：kLat 延迟表契约（B-4 / 计划 §5.3；未决清单 C4 已"删表改实测"，
  // 本部分改为形态 + 防回退镜像守卫）
  // ---------------------------------------------------------------------------
  group('Part J kLat 延迟表契约', () {
    test('引擎 kLat* 5 条形态（tier>=0 且 frames/ms 恰有一项>0；comp/limiter/arbmag 走动态）', () {
      final src = _read('engine/engine_internal.h');
      // D1（2026-10-24）：LatencyItem 拆成 {tier, frames, ms} 三字段——
      // 结构性帧数延迟（comp 4096 帧）按采样率换算，名义毫秒值原样用。
      // 旧的 `{tier, ms}` 两字段正则因此匹配不到，且 `ms > 0` 对新形态失效。
      // 新契约：每条必须**恰有一项非零**——两者皆 0 = 等于没登记（占位蒙混），
      // 两者皆非零 = 口径含糊（不知道该用哪个），都判红。
      final re = RegExp(
          r'kLat(\w+)\s*\{\s*(\d+)\s*,\s*(\d+)\s*,\s*([\d.]+)f?\s*\}');
      final rows = re.allMatches(src).map((m) => (
            name: m.group(1)!,
            tier: int.parse(m.group(2)!),
            frames: int.parse(m.group(3)!),
            ms: double.parse(m.group(4)!),
          )).toList();
      // 5 条：arbmag / comp / limiter 三项刻意不在表内——
      //   arbmag = 单块帧数（随驱动块长变）；
      //   comp   = fftLen-ovpLen，随 tfresolution 变（D7 实测，见 kCompLatProfile）；
      //   limiter= 随 lookahead 模式在 0 / ~1.5ms 之间切（D7 实测）。
      // 三者都由 compute_latency 直接算，写常量必错。
      expect(rows.length, 5, reason: '引擎 kLat 表条目数应为 5（arbmag/comp/limiter 走动态）');
      for (final r in rows) {
        expect(r.tier, greaterThanOrEqualTo(0), reason: 'kLat${r.name} tier 应>=0');
        final hasFrames = r.frames > 0;
        final hasMs = r.ms > 0;
        expect(hasFrames ^ hasMs, isTrue,
            reason: 'kLat${r.name} 必须恰有一项非零'
                '（frames=${r.frames} ms=${r.ms}；皆 0=没登记，皆非 0=口径含糊）');
      }
      // D7：comp 的延迟不是固定 4096 帧（那是 FFTSIZE_DRS/2，从来不是运行时
      // 延迟量）。实测延迟 = fftLen-ovpLen，随 tfresolution 变；且块长不足
      // ovpLen 时整块直通（0ms）。故它必须走 kCompLatProfile 剖面表。
      expect(RegExp(r'kLatComp').hasMatch(src), isFalse,
          reason: 'kLatComp 不得存在——comp 延迟随 tfresolution 变，须查 kCompLatProfile');
      expect(RegExp(r'kLatLimiter').hasMatch(src), isFalse,
          reason: 'kLatLimiter 不得存在——limiter 延迟随 lookahead 模式变（0 / ~1.5ms）');
      final prof = RegExp(
              r'\{\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*\}')
          .allMatches(src)
          .where((m) => m.group(2) == '4096' || m.group(3) == '512')
          .toList();
      expect(prof.length, greaterThanOrEqualTo(2),
          reason: 'kCompLatProfile 应含 fftLen=4096 / ovpLen=512 的剖面行');
      expect(src.contains('kCompLatProfile'), isTrue,
          reason: 'comp 延迟剖面表 kCompLatProfile 必须存在');
      // arbmag 不得以任何形态回到表里（回退即"两张皮"重现）
      expect(RegExp(r'kLatArbMag').hasMatch(src), isFalse,
          reason: 'kLatArbMag 不得存在——arbmag 延迟=块长，写常量必错');
    });

    test('Dart 无 kLat 硬编码镜像（防回退"两张皮"；C4 已删表改实测）', () {
      final libHits = <String>[];
      final libDir = _locateLibDir();
      final engineBoundary = '${Platform.pathSeparator}engine${Platform.pathSeparator}';
      for (final f in libDir.listSync(recursive: true).whereType<File>()
          .where((f) => f.path.endsWith('.dart')
              && !f.path.contains(engineBoundary))) {
        for (final n in f.readAsLinesSync()) {
          if (RegExp(r'kLat[A-Z]\w*').hasMatch(n)) {  // kLatComp 等；排除 kLatencyProbeAliases
            libHits.add('${f.path.replaceFirst(libDir.path, 'lib')}: ${n.trim()}');
          }
        }
      }
      expect(libHits, isEmpty,
          reason: 'lib/ 出现 kLat 硬编码镜像（延迟须实测，见未决清单 C4）\n'
              '${libHits.join('\n')}');
      final stateSrc = _readStateLibrary();
      final sig = stateSrc.indexOf('componentLatency(String compId)');
      final end = stateSrc.indexOf('void _onComponentLatencyResult');
      expect(sig, isNot(-1));
      expect(end, greaterThan(sig));
      final body = stateSrc.substring(sig, end);
      for (final stale in const ['85.0', '2.67']) {
        expect(body.contains(stale), isFalse,
            reason: 'componentLatency 出现旧硬编码延迟标称 $stale（须实测，C4）');
      }
    });
  });

  // ---------------------------------------------------------------------------
  // Part K：参数默认 ∈ 范围契约（B-4 / 扫描汇报 B3 固化）
  // ---------------------------------------------------------------------------
  group('Part K 参数默认 ∈ 范围契约', () {
    test('有界参数默认全部落 [min,max]；comp 数组 14 条登记为设计预期', () {
      final table = _read('engine/engine_param_table.h');
      final internal = _read('engine/engine_internal.h');

      double fnum(String s) {
        var t = s.trim();
        if (t.endsWith('f')) t = t.substring(0, t.length - 1);
        if (t.toLowerCase().startsWith('0x')) {
          return int.parse(t.substring(2), radix: 16).toDouble();
        }
        return double.parse(t);
      }

      final rows = <({String id, String member, double min, double max})>[];
      final floatInt = RegExp(
          r'PARAM_(FLOAT|INT)\("([^"]+)",\s*(\w+(?:\[\d+\])?),\s*(-?\d+(?:\.\d+)?)f?,\s*(-?\d+(?:\.\d+)?)f?,');
      final boolRe = RegExp(r'PARAM_BOOL\("([^"]+)",\s*(\w+),');
      for (final m in floatInt.allMatches(table)) {
        rows.add((id: m.group(2)!, member: m.group(3)!,
            min: fnum(m.group(4)!), max: fnum(m.group(5)!)));
      }
      for (final m in boolRe.allMatches(table)) {
        rows.add((id: m.group(1)!, member: m.group(2)!, min: 0, max: 1));
      }

      final defRe = RegExp(r'std::atomic<\w+>\s+(\w+)\{([^}]*)\}');
      final defaults = <String, double>{};
      for (final m in defRe.allMatches(internal)) {
        final member = m.group(1)!;
        if (member.contains('[')) continue; // 数组无聚合默认
        final val = m.group(2)!.trim();
        // 非数值默认（如 state{AURADSP_STATE_BYPASS} 内部哨兵）不参与范围校验
        if (!RegExp(r'^-?(?:\d+(?:\.\d+)?|0x[0-9A-Fa-f]+)f?$').hasMatch(val)) {
          continue;
        }
        defaults[member] = fnum(val);
      }

      final outOfRange = <String>[];
      final missing = <String>[];
      var checked = 0;
      for (final r in rows) {
        final dv = defaults[r.member];
        if (dv == null) {
          missing.add(r.id);
          continue;
        }
        checked++;
        if (dv < r.min || dv > r.max) {
          outOfRange.add('${r.id} 默认 $dv ∉ [${r.min}, ${r.max}]');
        }
      }
      expect(checked, greaterThanOrEqualTo(159),
          reason: '有界参数检查数 <159（解析可能漏行）');
      expect(outOfRange, isEmpty, reason: '默认超界：\n${outOfRange.join('\n')}');
      expect(missing.toSet(), {
        'comp.freq1', 'comp.freq2', 'comp.freq3', 'comp.freq4', 'comp.freq5',
        'comp.freq6', 'comp.freq7', 'comp.gain1', 'comp.gain2', 'comp.gain3',
        'comp.gain4', 'comp.gain5', 'comp.gain6', 'comp.gain7',
        'post.gain.c0', 'post.gain.c1', 'post.gain.c2', 'post.gain.c3',
        'post.gain.c4', 'post.gain.c5', 'post.gain.c6', 'post.gain.c7',
      }, reason: '缺默认 id 集合应为 comp/post 数组 22 条（设计预期，见扫描汇报 B3）');
    });
  });

  // ---------------------------------------------------------------------------
  // Part L：混响预设 JSON 契约（B-4 / 扫描汇报 B4 固化）
  // ---------------------------------------------------------------------------
  group('Part L 混响预设矩阵契约', () {
    List<List<double>> engineRows() {
      final src = _read('engine/legacy/jdsp/Effects/reverb.c');
      final block = RegExp(r'ps\s*\[\]\s*=\s*\{(.*?)\n\s*\};', dotAll: true)
          .firstMatch(src)!.group(1)!;
      final numRe = RegExp(r'-?\d+(?:\.\d+)?f?');
      final rows = <List<double>>[];
      for (final line in block.split('\n')) {
        final t = line.trim();
        if (!t.startsWith('{')) continue;
        final nums = numRe.allMatches(t).map((m) {
          final s = m.group(0)!;
          return double.parse(s.endsWith('f') ? s.substring(0, s.length - 1) : s);
        }).toList();
        expect(nums.length, 17, reason: 'ps[] 行数值数 !=17: ${t.substring(0, 60)}');
        rows.add(nums);
      }
      return rows;
    }

    test('引擎 ps[] == test/data/reverb_presets.json（19×17 逐值）', () {
      final rows = engineRows();
      expect(rows.length, 19, reason: 'ps[] 预设数 != 19');
      final json = jsonDecode(_read('test/data/reverb_presets.json'))
          as Map<String, dynamic>;
      final presets = (json['presets'] as List).cast<Map<String, dynamic>>();
      expect(presets.length, 19, reason: 'JSON 预设数 != 19（跑 gen_reverb_presets.py 重生成）');
      for (var i = 0; i < 19; i++) {
        final vals = (presets[i]['values'] as Map<String, dynamic>)
            .values.cast<num>().toList();
        for (var c = 0; c < 17; c++) {
          expect(vals[c].toDouble(), closeTo(rows[i][c], 1e-6),
              reason: '预设 $i 列 $c 与引擎源码不一致（跑 tools/bin/gen_reverb_presets.py 重生成）');
        }
      }
    });

    test('JSON 预设名 0..18 齐全；UI reverb 卡索引 ⊆ 引擎域', () {
      final json = jsonDecode(_read('test/data/reverb_presets.json'))
          as Map<String, dynamic>;
      final presets = (json['presets'] as List).cast<Map<String, dynamic>>();
      expect(presets.map((p) => p['index'] as int).toSet(),
          {for (var i = 0; i < 19; i++) i},
          reason: 'JSON 预设 index 应覆盖 0..18');
      for (final p in presets) {
        expect((p['name'] as String).isNotEmpty, isTrue);
      }
      final stateSrc = _read('app/auradsp_app/lib/core/state.dart');
      final curated = RegExp(r'kReverbCuratedPresets\s*=\s*\[([^\]]+)\]')
          .firstMatch(stateSrc);
      expect(curated, isNotNull, reason: 'state.dart 缺少 kReverbCuratedPresets');
      final uiIdx = curated!
          .group(1)!
          .split(',')
          .map((s) => int.parse(s.trim()))
          .toSet();
      expect(uiIdx, isNotEmpty, reason: 'reverb_card 预设映射解析为空');
      expect(uiIdx.length, 8, reason: 'curated 预设应为 8 档');
      expect(uiIdx.every((i) => i >= 0 && i <= 18), isTrue,
          reason: 'UI reverb 卡索引越出引擎预设域 0..18: $uiIdx');
      final card = _read('app/auradsp_app/lib/features/effects/reverb_card.dart');
      expect(card.contains('kReverbCuratedPresets'), isTrue,
          reason: 'reverb_card 必须使用 curated 预设表，禁止硬编码另一套映射');
    });
  });
}
