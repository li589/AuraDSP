/*
 * auradsp_plugin_host.cpp — AuraDSP M1 Plugin Host Engine (VST3 / CLAP 64-bit)
 *
 * Implements in-process plugin hosting for VST3 and CLAP plugins on Windows x64.
 */


#include "auradsp_plugin_host.h"

// P1：本文件已按区拆分（见上 switch）；此处仅保留 C++ TU 骨架。
// VST3 静态链接锚点（vst3_static.h）在 host_instances.cpp，
// 全仓仅此一处 include（DEF_CLASS_IID 单包含设计）。

namespace auradsp {
} // namespace auradsp
