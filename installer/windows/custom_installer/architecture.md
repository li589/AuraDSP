# 自研安装向导架构与底层实现规格 (Architecture Specification)

## 1. 物理封装架构 (Packaging Architecture)

安装程序最终以单一可执行文件 `AuraDSP-Setup-x64-v<ver>.exe` 分发。内部结构由三部分咬合：

1. **宿主执行壳 (Host Executable)**：
   - 包含 UI 界面、逻辑控制与解包引擎的可执行 PE 程序。
   - 带有清单（Manifest），支持高 DPI 感知（Per-Monitor V2）与 Windows 10/11 现代外观。
2. **内嵌载荷 (Embedded Payload)**：
   - 将 `dist/AuraDSP-Windows-x64/` 目录中的全部文件通过 Zstandard (zstd) 或 7z LZMA2 算法压缩为单一大包 `payload.zst`。
   - 采用 Windows 资源嵌入方式（放入 PE 文件的 `RT_RCDATA` 资源节中），或以 Overlay 方式追加在 PE 文件末尾。
3. **数字签名区 (Authenticode Signature)**：
   - 使用开发者证书对合并后的单体 `.exe` 执行标准签名与时间戳打标，防止 Windows Defender 误报或 SmartScreen 拦截。

---

## 2. 核心模块与职责划分

```text
[AuraDSP Setup Wizard]
   ├── ProcessGuard        # 检测并终止旧版运行中实例 (auradsp_app.exe / 驱动宿主)
   ├── PayloadExtractor    # 从资源节解压 payload.zst 到目标目录，实时汇报进度条
   ├── AudioIntegrator     # 核心驱动与桥接注册:
   │     ├── RegisterAsioComServer(auraasio_bridge.dll)
   │     ├── CheckVaioDriverStatus()
   │     └── ConfigureFirewallLoopback()
   ├── ShortcutManager     # 创建桌面快捷方式 (.lnk)、开始菜单目录与程序组
   ├── RegistryManager     # 注册系统卸载表项 (HKCU\...\Uninstall\AuraDSP)
   └── UninstallerEmitter  # 向安装目录输出 uninstall.exe 与已安装文件清单 (manifest.json)
```

---

## 3. 驱动与 COM 注册规范

### 3.1 ASIO COM 组件注册
AuraDSP 作为专业音频效果处理中心，提供 `auraasio_bridge.dll` 供宿主数字音频工作站（Cubase, Reaper, FL Studio 等）作为声卡输入输出调用。
- **注册操作**：
  直接加载 `auraasio_bridge.dll` 并调用其导出的 `DllRegisterServer()`，或在注册表中建立映射：
  - `HKEY_CLASSES_ROOT\CLSID\{AURA-ASIO-GUID}`
  - `HKEY_LOCAL_MACHINE\SOFTWARE\ASIO\AuraASIO` (或 HKCU 映射)
- **卸载操作**：
  卸载时调用 `DllUnregisterServer()`，并清理对应的注册表键值。

### 3.2 运行中进程冲突防护 (Process Locking Guard)
在解压覆盖前，调用 Win32 `CreateToolhelp32Snapshot` 或 `EnumProcesses`：
1. 检查是否存在 `auradsp_app.exe` 或 `plugin_host_x64.exe`。
2. 若存在，弹窗提示：“检测到 AuraDSP 正在运行，是否自动退出并继续安装？”。
3. 若用户同意，发送 `WM_CLOSE` 优雅退出；若 3 秒内未退出，调用 `TerminateProcess` 强制释放文件锁。

---

## 4. 卸载器 (`uninstall.exe`) 运行机制

为了避免“无法删除正在运行的 uninstall.exe 本身”这一常见 Windows 痛点，卸载器遵循“**自复制执行与延迟自删**”模式：
1. 用户在“控制面板 / Windows 设置”点击卸载时，启动 `C:\Program Files\AuraDSP\uninstall.exe`。
2. `uninstall.exe` 识别自身处于安装目录，立刻将自身复制到 `%TEMP%\AuraDSP_Uninstall\uninstall.exe`，并使用子进程唤醒 `%TEMP%` 副本，原进程立即退出。
3. `%TEMP%` 副本运行后：
   - 弹窗确认是否卸载。
   - 询问是否保留用户声学预设（`%APPDATA%\AuraDSP`）。
   - 反注册 `auraasio_bridge.dll`。
   - 读取并逐一删除 `install_manifest.json` 中记录的全部已安装文件。
   - 删除快捷方式。
   - 清除注册表 `Uninstall\AuraDSP` 项。
   - 通过 Win32 API 注册关机自删或生成自删批处理脚本清除临时目录。

