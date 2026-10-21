#pragma once
// 插件 bundle 内二进制解析。格式驱动只传入自己的扩展名。

#include <string>

namespace auradsp {

/* 解析 bundle 内的真实二进制。探测顺序：x86_64-win（本进程架构）→
 * x86-win（32 位，仅识别不加载）。outArch 非空时写入命中目录名
 * （"x86_64-win" / "x86-win"），未命中留空。 */
std::string resolvePluginBundleBinary(const std::string& bundlePath,
                                     const char* lowerExtension,
                                     std::string* outArch = nullptr);

} // namespace auradsp
