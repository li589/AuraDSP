/*
 * channel_layout.dart — 声道布局唯一数据源（P1/F-06）
 *
 * 背景：频谱分析器（features/chain）与声道路由器（features/effects）各自
 * 手写 2/4/6/8ch 的声道代码表；两处一旦漂移，会出现「分析器可选声道」
 * 与「路由掩码位」不对应。本文件与 engine layout_for(ch) 严格对齐，
 * 两处 UI 只允许迭代本表。
 */

/// 单个声道：位索引 + 显示代码。
typedef ChannelSlot = ({int bit, String code});

const List<ChannelSlot> kChannelLayout2 = [
  (bit: 0, code: 'FL'),
  (bit: 1, code: 'FR'),
];

const List<ChannelSlot> kChannelLayout4 = [
  (bit: 0, code: 'FL'),
  (bit: 1, code: 'FR'),
  (bit: 2, code: 'BL'),
  (bit: 3, code: 'BR'),
];

const List<ChannelSlot> kChannelLayout6 = [
  (bit: 0, code: 'FL'),
  (bit: 1, code: 'FR'),
  (bit: 2, code: 'C'),
  (bit: 3, code: 'LFE'),
  (bit: 4, code: 'SL'),
  (bit: 5, code: 'SR'),
];

const List<ChannelSlot> kChannelLayout8 = [
  (bit: 0, code: 'FL'),
  (bit: 1, code: 'FR'),
  (bit: 2, code: 'C'),
  (bit: 3, code: 'LFE'),
  (bit: 4, code: 'SL'),
  (bit: 5, code: 'SR'),
  (bit: 6, code: 'BL'),
  (bit: 7, code: 'BR'),
];

/// 按声道数取布局；未知/超界按引擎约定：>=8 用 8ch，其余用 2ch。
List<ChannelSlot> channelLayoutFor(int count) {
  if (count == 4) return kChannelLayout4;
  if (count == 6) return kChannelLayout6;
  if (count >= 8) return kChannelLayout8;
  return kChannelLayout2;
}

/// 该布局的全开位掩码（由布局派生，禁止另写 0x0F/0x3F/0xFF）。
int channelFullMask(int count) =>
    channelLayoutFor(count).fold(0, (mask, c) => mask | (1 << c.bit));
