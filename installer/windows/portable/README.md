# Windows 便携版 (Portable Zip) 规范

本模块负责从 Staging 目录（`dist/AuraDSP-Windows-x64/`）生成开箱即用的便携式 `.zip` 归档。

## 1. 规整清单 (Staged Files)

便携包内必须包含以下核心组件：
- **主可执行程序**：`auradsp_app.exe`
- **核心音效引擎**：`auradsp_engine.dll`
- **驱动桥动态库**：`auravaio_bridge.dll`, `auraasio_bridge.dll`, `auravm_bridge.dll`
- **插件隔离宿主**：`plugin_host_x64.exe`, `plugin_host_x86.exe`
- **Flutter 运行时**：`flutter_windows.dll`, `cnativeapi.dll`, 以及插件 DLLs
- **数据与资产目录**：`data/` (Dart snapshot, shaders, fonts)
- **声学核心资源**：`resources/` (DDC, Convolver, Liveprog 核心脚本)
- **便携标志标记**：`portable.dat`（告知应用以当前可执行文件所在目录作为配置和预设根目录，不写入 `%APPDATA%`）

## 2. 输出要求
- 输出路径：`dist/AuraDSP-Windows-x64-v{VERSION}.zip`
- 压缩标准：ZIP64 规范，最高压缩比（Deflate 或 7z LZMA 压缩），保持相对目录树。

