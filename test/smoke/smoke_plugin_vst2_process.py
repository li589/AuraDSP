# -*- coding: utf-8 -*-
"""smoke_plugin_vst2_process.py — VST2 进程外路径门禁（2026-11-03）。

复用 smoke_plugin_vst2.py 的全部断言，但在创建引擎前强制
AURA_PLUGIN_HOST_MODE=process，覆盖：
  - 64 位 VST2 经 plugin_host_x64 沙箱加载/扫描/编辑器/预设；
  - 32 位 VST2 经 plugin_host_x86 位桥；
  - 进程外重载（同一槽连续 load→unload→load）的共享环清空逻辑
    （2026-11-03 修：旧会话残留输出块会让新代理持续直通）。
"""

import os
import sys

os.environ["AURA_PLUGIN_HOST_MODE"] = "process"

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

from smoke_plugin_vst2 import main  # noqa: E402

if __name__ == "__main__":
    sys.exit(main())
