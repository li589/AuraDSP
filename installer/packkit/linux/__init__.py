"""Linux 平台层（与 `packkit/windows/` 对称）。

依赖方向仍是单向的：`packkit/linux/*` 可以 import `packkit.*` 平台无关
内核，反向禁止。对外只有 `cli.main` 一个入口。

模块职责：

    bundle.py       校验 + staging 副本 + 资源合并 + 默认层
    perms.py        权限规范化 / ELF 识别（不依赖 `file` 命令）
    deb.py          主安装包 auradsp_<ver>_amd64.deb
    driver_deb.py   snd-aloop 配置包 auradsp-driver-loopback_<ver>_all.deb
    appimage.py     便携 AppImage（工具钉版 + 铁律自检）
    portable.py     tar.gz 便携包
    build.py        --build：cmake → flutter → sync_artifacts
    modes.py        模式调度与「单档位」门禁
    cli.py          参数解析
"""

from __future__ import annotations

__all__ = ["cli"]
