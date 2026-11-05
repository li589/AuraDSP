# Linux AppImage 打包方案与规范

本模块负责构建免安装、单文件、跨发行版双击可运行的 `AuraDSP-v<ver>-x86_64.AppImage`。

---

## 1. 设计核心要点

1. **宿主音频透传 (Host Audio Passthrough)**：
   - 严禁打包 `libpulse.so`、`libasound.so`。
   - 依赖宿主系统的 PulseAudio / PipeWire UNIX Socket，保持声效透明路由。
2. **免 `libfuse2` 依赖 (Static Type 2 Runtime)**：
   - 使用现代 `appimagetool` 或 `go-appimagetool` 结合静态链接的 runtime，规避 Ubuntu 24.04+ 因移除 `libfuse2` 造成的无法启动问题。
3. **AppRun 封装器**：
   - 自动导出正确的 `LD_LIBRARY_PATH`。
   - 自动关联 XDG 字体与图标环境。

---

## 2. AppDir 目录结构

```text
AuraDSP.AppDir/
├── AppRun
├── auradsp.desktop
├── auradsp.png
└── usr/
    ├── bin/
    │   ├── auradsp_app
    │   └── plugin_host_x64
    ├── lib/
    │   ├── libauradsp_engine.so
    │   └── libflutter_linux_gtk.so
    └── share/
        └── auradsp/
            ├── data/
            └── resources/
```

---

## 3. 输出目标
最终生成：`dist/AuraDSP-v{VERSION}-x86_64.AppImage`。

