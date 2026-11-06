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

## 4. 覆盖升级与驱动签名（2026-11-06 追加）

- 安装目录最后一段不是 AuraDSP 时自动补上（大小写不敏感）；覆盖升级/修复沿用旧目录并锁定输入框。
- 更新：读 HKCU/HKLM 的 Software\AuraDSP 版本与目录，按 4 段版本号判定「全新 / 升级 / 修复 / 降级拦截」。升级沿用旧组件选择，解压前备份旧程序文件，失败自动恢复，用户数据路径不覆盖不删除；不自动降级。在线检查更新未纳入本轮。
- 双驱动（AuraASIO / AuraVAIO）默认勾选、可取消；取消只跳过自动安装，driver/ 目录恒保留在安装目录。
- VAIO 安装改调随包自包含脚本 `driver/install_vaio.ps1 -Action install`。原 `install_driver.ps1` 默认只做 status 体检且依赖源码树/WDK signtool，随包不可用，仅保留供诊断。
- VAIO 为测试签名驱动：所有 64 位 Windows（Win7/8.1/10/11）默认拒绝加载，32 位基本不强制；Win11 另有 Secure Boot / 内存完整性门槛。选项页提供教程弹窗，安装目录 `driver/README.txt` 给出持久（testsigning）与一次性（F7）两套方案。AuraASIO 为用户态 COM 组件，不受此限制。
- 完整依据、决策、待确认项与验收口径见 `installer/docs/06_安装向导更新与驱动签名-2026-11-06.md`。

## 5. 卸载语义（2026-11-06 第三轮修正）

- 勾选「保留我的配置、预设与校准数据」时：保留 %APPDATA%\AuraDSP、%LOCALAPPDATA%\AuraDSP
  以及安装目录内所有非随包文件（清单外文件）；不勾选时一并删除。
- 无论是否保留用户数据，都清理：随包程序文件、VAIO 驱动/设备节点/测试证书、ASIO 注册、
  两个 hive 的卸载项与 Run 自启项、桌面/开始菜单快捷方式与空程序组、临时日志。
- 完成页列出实际保留的数据路径；未删除项会逐条出现在 warnings。

## 6. 提权与 ASIO 注册口径（2026-11-06 第四轮）

- 安装：勾选「为所有用户安装」或「AuraVAIO」时点「开始安装」才请求 UAC；
  授权后自动继续安装，不再需要二次点击；拒绝后由用户选择重试 / 降级继续 / 返回。
- 卸载：一律请求 UAC（含从 Windows 设置 → 应用 → 卸载触发），授权后自动卸载。
- ASIO 注册/反注册走系统注册子进程，**不在向导进程内加载 DLL**，避免卸载时报
  auraasio_driver.dll 被占用，也避免同步 FFI 冻结界面。
- 完成页可最后决定「创建桌面快捷方式」，点击完成时按勾选状态补建或删除。

## 7. 退出后清理（2026-11-06 第五轮）

- 不再弹可见 cmd 窗口：会话目录与卸载残留文件由隐藏的 PowerShell 脚本清理，
  避免 QuickEdit「选择」模式挂起导致黑窗口关不掉。
- 卸载前按镜像名强杀 auradsp_app / plugin_host_x64 / plugin_host_x86，
  删除阶段再守卫一次并重试；仍被占用的文件在向导退出后由隐藏脚本自动补删。

## 8. 进程守卫安全与性能口径（2026-11-06 第六轮）

- 守卫进程按可执行文件完整路径核对（只处理本安装目录下的
  auradsp_app.exe / plugin_host_x64.exe / plugin_host_x86.exe），
  不再按进程名匹配或按镜像名强杀，避免误伤同名软件与别家插件宿主；
  路径查询失败时宁可不杀。
- 极光背景由 60fps 全窗重绘改为 24 档 / 900ms 低频重绘 + 图层隔离；
  进度事件 60ms 节流、日志上限 120 条，显著降低内存与 GPU 占用。
