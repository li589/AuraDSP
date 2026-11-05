# AuraDSP Windows 打包与安装体系

本目录管理 AuraDSP 在 Windows x64 平台上的全部发布与安装工具链。

## 1. 产物双轨制 (Two Release Tracks)

Windows 平台支持两种平行的分发模式：

1. **便携版 (Portable Edition)**：
   - 目录：`installer/windows/portable/`
   - 目标产物：`dist/AuraDSP-Windows-x64-v<ver>.zip`
   - 特点：绿色解压即用，支持便携模式（配置文件位于本地运行目录，不写系统注册表）。
2. **自研安装程序版 (Custom Installer Edition)**：
   - 目录：`installer/windows/custom_installer/`
   - 目标产物：`dist/AuraDSP-Setup-x64-v<ver>.exe`
   - 特点：拥有现代暗黑美学向导、自动关闭占用进程、集成 AuraASIO COM 注册、AuraVAIO 驱动配置、开始菜单/桌面快捷方式与 Windows 设置卸载支持。

---

## 2. 目录结构

- `pack.py`：**打包总入口**（全量可传参：`--mode driver,portable,setup`、`--resources core|full|addons|none`、`--build-staging`、`--build-installer`、`--sign` 钩子、`--verify` 自检）；逻辑自测在 `tests/test_pack_fixture.py`。
- `portable/`：便携版说明（归档逻辑在 pack.py 的 portable 模式内）。
- `custom_installer/`：自研安装程序子项目——`bootstrapper/`（C++ 引导壳）+ `wizard/`（Flutter 向导 auradsp_setup）。

## 3. 一键构建三件（Windows 本机）

前置（一次性）：Visual Studio（MSVC）+ Flutter 3.47.9 + Python 3；Steinberg ASIO SDK 解压到 `windows-drivers/CMakeLists.txt` 中 `ASIO_SDK_ROOT` 指向的路径（换机改该 cache 变量）；VAIO 内核驱动先在 VS + WDK 里构建 `01_vaio_driver/modern/AuraVaioDriver.vcxproj`（.sys/.inf/.cat 产物由 pack.py 自动发现）。

```powershell
# 1) 全量构建 staging（引擎/三桥/ASIO 驱动 auraasio_driver/App 本体）
powershell -File tools/build_windows.ps1
# 2) 资源包（如需 full/addons 策略；core 策略不需要）
python tools/resource_pipeline/build_packages.py
# 3) 打包三件到 dist/（driver zip + portable zip + Setup exe）
python installer/windows/pack.py --build-installer --mode all --resources core
```

要点：ASIO 驱动的规范文件名是 `auraasio_driver.dll`（ADR-008；pack.py 按此名收集、入包归一化，`AuraAsioDriver.dll` 别名仅兼容识别）；setup 模式缺该 DLL 或 VAIO 产物会直接报错并指明构建路径。驱动正式签名（Attestation/EV）未完成前，产物为测试签名口径，见 05 号规划风险项。编译与打包逻辑的持续验证见 `.github/workflows/windows-installer.yml`。

