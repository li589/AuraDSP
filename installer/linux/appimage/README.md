# Linux AppImage 打包方案与规范

本模块负责构建免安装、单文件、跨发行版双击可运行的 `AuraDSP-v<ver>-x86_64.AppImage`。

---

## 1. 设计核心要点

1. **宿主音频透传 (Host Audio Passthrough)**：
   - 严禁打包 `libpulse.so`、`libasound.so`。
   - 依赖宿主系统的 PulseAudio / PipeWire UNIX Socket，保持声效透明路由。
2. **免 `libfuse2` 依赖 (Static Type 2 Runtime)**：
   - 使用维护线 `appimagetool`（1.9.1）结合静态链接的 type2 runtime，规避 Ubuntu 24.04+ 因移除 `libfuse2` 造成的无法启动问题。
   - **供应链钉死**：工具与 runtime 均按 `tools.pins` 的版本 + SHA256 校验，runtime 经 `--runtime-file` 钉死日期版（20251108），禁止构建时现下滚动标签。
3. **AppRun 封装器**：
   - 自动导出正确的 `LD_LIBRARY_PATH`。
   - 自动关联 XDG 字体与图标环境。

---

## 2. AppDir 目录结构

实现：`build_appimage.sh`（由 `../pack.sh` 调用）。AppDir 布局与 deb
一致地保留 bundle 原生结构（整包位于 `usr/lib/auradsp/`，AppRun 直启
主程序），与 §2 的早期示意（usr/bin 拆分）不同，以 runner 的相对路径
要求为准。

```text
AuraDSP.AppDir/
├── AppRun
├── auradsp.desktop
├── auradsp.png
└── usr/
    └── lib/
        └── auradsp/   （Flutter bundle 原样：auradsp_app、lib/、data/、resources/）
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

