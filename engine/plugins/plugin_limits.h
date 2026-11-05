/*
 * plugin_limits.h — 插件层跨格式/跨语言的容量常量唯一定义处（F-09）。
 *
 * 历史问题：插件槽位数在 Dart（PluginManager.kMaxSlots）、Win32 IPC 协议
 * （plugin_ipc_protocol.h）各写一份 4；总线通道上限 8 散落在 VST2/VST3/CLAP
 * 三个格式层；VST2 的 process 临时指针数组用 64，与"总线通道上限 8"语义
 * 混在一起（厂商 num_inputs/num_outputs 可远超总线通道数，数组按 64 分配，
 * 实际参与处理的通道仍由调用方按 kBusChannels 裁剪）。
 *
 * 约束：
 *   - 本头文件只允许 C++ TU 引用（formats/driver/platform 的宿主与引擎
 *     目标都把 ${API} 放进 include path，以 "plugins/plugin_limits.h" 引用）；
 *   - kBusChannels 直接取 ABI 的 AURADSP_CH_MAX，避免再抄一个 8；
 *   - 改任何常量必须同步 Dart 镜像值：test/plugin_limits_contract_test.dart
 *     会读取本文件做跨语言断言。
 */
#pragma once

#include <cstdint>

#include "auradsp_engine.h"

namespace auradsp {
namespace limits {

/* 插件槽位数（IPC SharedAudio 布局 + Dart PluginManager.kMaxSlots）。 */
constexpr uint32_t kMaxSlots = 4u;

/* 单条处理总线（AudioBlock / 引擎 ABI）的通道上限。 */
constexpr uint32_t kBusChannels = AURADSP_CH_MAX;

/* 格式层通道计数是 int/int32_t，这里给出同一常量的 int 形式，避免每处
 * 写 static_cast。 */
constexpr int kBusChannelsInt = static_cast<int>(kBusChannels);

/* VST2 processReplacing 的临时指针数组上限：厂商 num_inputs/num_outputs
 * 合法值可达 64，与总线通道上限无关；数组必须按厂商上限分配，否则越界。 */
constexpr int kVst2ArrayChannels = 64;

}  // namespace limits
}  // namespace auradsp
