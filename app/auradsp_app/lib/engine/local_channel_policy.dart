// B2b：本地播放时引擎工作声道策略（纯函数，无副作用，便于单测）。
//
// 本地文件源若带 raw 多声道（4/6/8），默认把真实 Nch 送入引擎多声道路径
// （`channels.count` + `spatial.binaural`/矩阵），替代 Dart 侧预折叠；直通
// （passthrough51，true-bypass 到多声道端点）与旁路（bypass，无 DSP）仍走
// 立体声 fold。引擎 `channels.count` 只接受 2/4/6/8——3/5/7 声道文件回落
// Dart fold（decodeWavFile 已支持 3/>=5 折叠）。
//
// 立体声设备上还要看引擎会不会把 Nch 折成 L/R：矩阵模式（0）本身下混、
// binaural 分支优先于模式且恒出立体声；离散模式（1）则原样逐声道输出，
// 喂给立体声设备会丢中置/环绕——此时回落 Dart fold。
//
// 返回引擎应设置的 `channels.count`；2 表示立体声（fold）路径。
int localEngineChannels({
  required bool hasRaw,
  required int rawCh,
  required bool passthrough51,
  required bool bypass,
  required int devCh,
  required int channelsMode,
  required bool binauralActive,
}) {
  if (bypass || passthrough51 || !hasRaw) return 2;
  if (rawCh != 4 && rawCh != 6 && rawCh != 8) return 2;
  // 设备声道兜得住 → 原样多声道（矩阵/离散监听均可）。
  if (devCh >= rawCh) return rawCh;
  // 立体声设备：仅当引擎会把 Nch 折成 L/R 时才喂多声道。
  if (channelsMode == 0 || binauralActive) return rawCh;
  return 2;
}

/// 第四十二轮 S1：声道能力自动回退（纯函数）。用户设置的声道数
/// 超过当前输出路径（设备/端点/桥流）的实际声道能力时，自动钳
/// 到能力内最大的合法值 {2,4,6,8}，不需用户手动改设置；能力
/// 恢复后随重派发自动回升。钳制只改生效值，不动用户设置值。
///
/// [want] 非法（非 4/6/8）按 2 处理；[cap] 先归一到合法集内
/// 不大于它的最大值（cap>=8 → 8，6..7 → 6，4..5 → 4，其余 2）。
int clampChannelsToCapability(int want, int cap) {
  final w = (want == 4 || want == 6 || want == 8) ? want : 2;
  final c = cap >= 8 ? 8 : cap >= 6 ? 6 : cap >= 4 ? 4 : 2;
  return w <= c ? w : c;
}
