# Linux Snap 商店打包规范 (Canonical Snapcraft 预留)

本目录预留 AuraDSP 在 Ubuntu Snap 商店（Snapcraft）生态下的打包规范。

---

## 1. 基础配置规格

- **应用名称**：`auradsp`
- **基础镜像**：`base: core24`
- **等级模式**：`confinement: strict`
- **清单文件**：`snapcraft.yaml`

---

## 2. 关键权限插槽 (Plugs)

AuraDSP 处理实时音频需要接入系统的音频插槽：

```yaml
apps:
  auradsp:
    command: usr/bin/auradsp_app
    extensions: [gnome]
    plugs:
      - audio-playback     # 播放音频核心权限
      - audio-record       # 声谱分析与输入监测权限
      - pulseaudio         # PulseAudio/PipeWire 连接通道
      - home               # 读写预设与脉冲文件权限
      - network            # 预设在线下载/更新检查
      - removable-media    # 访问外部存储设备中的音频脉冲
```

---

## 3. 输出目标
后续执行 `snapcraft` 构建后，产物归集到 `dist/auradsp_{VERSION}_amd64.snap`。

