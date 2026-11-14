// apo_plugin_block.dart — System APO 插件块布局常量（Part I Q2）
//
// 与 core/desktop/windows-drivers/03_system_apo/ApoShared.h 的
// 插件块定义严格对应（手工契约，非引擎表派生，故不用生成器）；
// 漂移由 test/smoke/smoke_apo_plugin_layout.py 交叉断言。
// 布局：头 64B → 每槽 [槽头 64B][路径 1024B][id 256B][状态
// 512KiB]，槽步长 525632B，映射总 2105344B。

/// 块魔数 'AUPG' 与版本。
const int kApoPluginsMagic = 0x47505541;
const int kApoPluginsVersion = 1;

/// 槽数（与引擎 kMaxSlots 同为 4，独立钉死防漂移）。
const int kApoPluginSlots = 4;
const int kApoPluginPathBytes = 1024;
const int kApoPluginIdBytes = 256;
const int kApoPluginStateBytes = 524288;
const int kApoPluginBlockHeaderBytes = 64;
const int kApoPluginSlotHeaderBytes = 64;
const int kApoPluginSlotStride = 525632;
const int kApoPluginBlockUsedBytes = 2102592;
const int kApoPluginBlockBytes = 2105344;

/// 格式码（发布侧自述；引擎按路径找驱动）：0 无 1 VST3 2 CLAP 3 VST2。
const int kApoPluginFormatNone = 0;
const int kApoPluginFormatVst3 = 1;
const int kApoPluginFormatClap = 2;
const int kApoPluginFormatVst2 = 3;

int apoPluginFormatCode(String format) {
  switch (format.toUpperCase()) {
    case 'VST3':
      return kApoPluginFormatVst3;
    case 'CLAP':
      return kApoPluginFormatClap;
    case 'VST2':
    case 'VST':
      return kApoPluginFormatVst2;
    default:
      return kApoPluginFormatNone;
  }
}

/// 槽 s 的起始偏移。
int apoPluginSlotOffset(int slot) =>
    kApoPluginBlockHeaderBytes + slot * kApoPluginSlotStride;

/// 槽内路径/id/状态区偏移（相对槽起始）。
const int kApoPluginSlotPathOffset = 64;
const int kApoPluginSlotIdOffset = 64 + 1024;
const int kApoPluginSlotStateOffset = 64 + 1024 + 256;

/// telemetry v3 插件段（ApoTelemetryBlock offset 608 起，每槽
/// 32B = 8 个 u32）：flags 打包字节序 loaded/bypass/fault/
/// faultCategory（低→高），其后 latency/inRms/outRms/
/// processCalls/appliedLoadGen/appliedStateGen/reserved。
const int kApoTelemetryPluginsOffset = 608;
const int kApoTelemetryPluginSlotU32 = 8;

/// telemetry v4 加载诊断（offset 736 起，第五轮 S3）：u32[184] =
/// loadStage（0 未试 / 1 自目录失败 / 2 三候选加载失败 / 3 ABI
/// 不符 / 4 create 失败 / 5 就绪），u32[185] = loadErr（Win32 码）。
const int kApoTelemetryLoadDiagU32 = 184;

/// telemetry v6 引擎生效值回读（offset 1452 起，第三十五轮）：
/// u32[363] = effChannelsMode、u32[364] = effUpmixFill、
/// u32[365] = effValid（1 后前两值可信）。v6 以前整段不存在。
const int kApoTelemetryEffU32 = 363;
