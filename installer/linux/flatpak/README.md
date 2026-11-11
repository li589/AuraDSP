# Linux Flatpak 商店打包规范 (Flathub 预留)

本目录预留 AuraDSP 在 Flathub 及 Flatpak 体系下的打包规范与清单配置。

---

## 1. 基础配置规格

- **应用 ID**：`org.auradsp.AuraDSP`
- **运行时环境**：`org.freedesktop.Platform // 25.08`
- **SDK 环境**：`org.freedesktop.Sdk // 25.08`
- **清单文件**：`org.auradsp.AuraDSP.yml`

---

## 2. 关键沙盒权限 (`finish-args`)

Flatpak 作为强沙盒环境，音频与桌面显示权限是运行的关键：

```yaml
finish-args:
  - --share=ipc
  - --socket=x11
  - --socket=wayland
  - --socket=pulseaudio           # 核心：必须开启 pulseaudio 套接字权限（自动映射宿主 PipeWire）
  - --filesystem=home:ro          # 允许读取用户目录下的声学脉冲 (.irs) 和预设文件
  - --filesystem=xdg-run/pipewire-0 # 允许原生 PipeWire 控制套接字直接握手
```

---

## 3. 输出目标
后续执行 `flatpak-builder` 构建后，产物归集到 `dist/org.auradsp.AuraDSP.flatpak`。

