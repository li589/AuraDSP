"""AuraDSP 发行打包工具链内核（packkit）。

分层口径（2026-11-20 工具链规范化）：

  packkit/            平台无关内核：版本、命名、哈希、归档、资源档位、
                      默认层、staging 副本、交付归集。
  packkit/windows/    Windows 平台层：VAIO 驱动域、Authenticode 签名门、
                      Setup 单体拼装、引导壳/向导构建、四个打包模式。
  windows/pack.py     Windows 打包 CLI 薄壳（保持历史命令行不变）。
  release.py          跨平台发布编排：预检 → 构建 → 分档打包 → 交付归集。

为什么拆：原 `pack.py` 单文件 1318 行，驱动签名、资源合并、Setup 拼装、
哈希清单交织在一起，改任一处都要通读全篇；平台层与内核层也不可分，
Linux 侧无法复用命名单一真相。拆分后每层只依赖下一层，且**命令行与
错误文案逐字不变**——CI 的 fixture 断言就是这条契约的执行点。

不变量：
- 命名只有一个真相源（`naming.py`），禁止在模式实现里拼字符串。
- 版本只有一个真相源（`shared/version_resolver.py`）。
- 发行门禁（驱动新鲜度、驱动签名、资源哈希对账）在调用链上单点执行，
  staging 便利路径只允许降级为警告，发行路径必须拒绝。
"""

from __future__ import annotations

from .common import reconfigure_streams

# 历史行为：pack.py 在模块导入期就把标准流改成 UTF-8，避免 Windows 旧
# 代码页下 print 中文崩溃。任何入口（pack.py / release.py / 测试）导入
# packkit 即获得同一口径，不必各自重复。
reconfigure_streams()

__all__ = ["reconfigure_streams"]
