# Linux 驱动包：auradsp-driver-loopback

规格：[03_linux_packaging_spec.md](../../docs/03_linux_packaging_spec.md) §6。

Linux 无自研内核驱动；AuraDSP「驱动模式」依赖发行版自带的
**snd-aloop** 回环声卡模块。本包是纯配置包（架构 `all`、无二进制），
职责是把模块的开机自启与参数固化，并附自检工具：

| 路径 | 作用 |
| :--- | :--- |
| `/etc/modules-load.d/auradsp-loopback.conf` | 开机自动加载 `snd-aloop` |
| `/etc/modprobe.d/auradsp-loopback.conf` | `options snd-aloop enable=1` |
| `/usr/lib/auradsp-driver-loopback/auradsp-loopback-check` | 自检：模块已加载 / Loopback 声卡可见 / `aplay -l` 可见 |

- `postinst` 尽力即时 `modprobe snd-aloop` 一次（失败不中断安装，
  配置仍在下次开机生效）。
- 与主包 `auradsp` 无硬依赖，可独立安装/卸载；主包将其列为
  Recommends。
- 构建：`build_driver_deb.sh`（由 `../pack.sh` 调用）。
