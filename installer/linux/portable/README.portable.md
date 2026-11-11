# AuraDSP for Linux — 便携包

解压后直接运行：

```bash
./auradsp
```

说明：

- 需要系统已装 GTK 3、PulseAudio 或 PipeWire（pipewire-pulse）、
  ALSA 库（libasound2）——便携包不捆绑宿主音频/图形库，这是刻意
  的设计（见 installer/docs/03_linux_packaging_spec.md §1）。
- 「驱动模式」需要 snd-aloop 内核模块：临时启用执行
  `sudo modprobe snd-aloop`；长期启用请安装发行包中的
  `auradsp-driver-loopback` 驱动配置包，或手动把 `snd-aloop`
  写入 `/etc/modules-load.d/`。
- 32 位插件桥 `lib/plugin_host_x86` 需要目标机装有 32 位运行库
  （multilib）；缺失时 32 位插件会显示为不兼容，64 位插件不受影响。
- 配置与数据目录遵循 XDG：`~/.config/auradsp`、`~/.local/share/auradsp`。
