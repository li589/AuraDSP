AuraDSP 驱动手动安装说明 / Manual Driver Installation
================================================================

本目录中的驱动与脚本会一直保留在安装目录，即使安装向导里取消勾选
「AuraASIO / AuraVAIO」，也不会被删除。任何时候都可以用管理员权限补装。
The files in this folder are always kept in the install directory, even when
the driver checkboxes were cleared during setup. You can install them later.

----------------------------------------------------------------
1. 目录内容 / Contents
----------------------------------------------------------------
  AuraVaioDriver.inf / .sys / auravaiodriver.cat   AuraVAIO 内核驱动包
  AuraDSP_TestSign.cer                            自签名测试证书
  devcon.exe                                       WDK 工具，创建 root 枚举设备节点
  auraasio_driver.dll                              AuraASIO 用户态 COM 驱动
  install_vaio.ps1                                ★ 随包自包含安装/卸载/体检脚本
  register_asio.ps1                               AuraASIO 注册/反注册脚本
  install_driver.ps1                              开发期体检脚本（需源码树，仅供参考）

----------------------------------------------------------------
2. 手动安装（务必先以管理员身份打开 PowerShell）
----------------------------------------------------------------
  cd "<安装目录>\driver"
  powershell -NoProfile -ExecutionPolicy Bypass -File .\install_vaio.ps1 -Action status
  powershell -NoProfile -ExecutionPolicy Bypass -File .\install_vaio.ps1 -Action install
  powershell -NoProfile -ExecutionPolicy Bypass -File .\register_asio.ps1
  powershell -NoProfile -ExecutionPolicy Bypass -File .\install_vaio.ps1 -Action uninstall -RemoveTestCert
  powershell -NoProfile -ExecutionPolicy Bypass -File .\register_asio.ps1 -Unregister

  -RemoveTestCert 会按随包证书指纹精确删除 Root / TrustedPublisher / My 三个存储中的测试证书；
  不传该开关则保留证书（多版本共存时避免互相影响）。

  日志：%TEMP%\auradsp-vaio-install.log
  退出码：0 成功 / 2 需管理员 / 3 需先开启测试签名 / 4 缺驱动文件
          5 pnputil 失败 / 6 devcon 失败 / 7 缺 devcon.exe

  Register / unregister AuraASIO (user-mode, no signing needed):
      powershell -NoProfile -ExecutionPolicy Bypass -File .\register_asio.ps1
      powershell -NoProfile -ExecutionPolicy Bypass -File .\register_asio.ps1 -Unregister

----------------------------------------------------------------
3. 重要事实：哪些系统需要开启测试签名？
----------------------------------------------------------------
  AuraVAIO 使用「自签名测试证书」，不是微软 Attestation / EV 正式签名。
  微软的内核模式代码签名策略适用于【所有 64 位 Windows】——
  Windows 7 / 8.1 / 10 / 11 默认都拒绝加载测试签名驱动。
  只有 32 位 Windows 基本不强制。因此「Win10 以下不受影响」并不成立。

  Windows 11 与 Win10 的区别只是【门槛更多】：Secure Boot、内存完整性
  （HVCI / VBS）、较新版本对 bcdedit 的写入限制，而不是「老系统免检」。
  另外，自 Windows 10 1507 起若开启内存完整性，驱动二进制必须带有
  测试证书签名（本包已满足），但 HVCI 仍可能阻止安装。

  AuraASIO 是用户态 COM 组件，通过 DllRegisterServer 注册，
  【不需要】开启测试签名，也不受上述限制。

  AuraVAIO is TEST-SIGNED, not Attestation/EV signed. Windows kernel-mode
  code signing applies to EVERY 64-bit edition (Win7/8.1/10/11); only 32-bit
  editions generally allow unsigned drivers. Windows 11 merely adds Secure
  Boot / Memory Integrity (HVCI) hurdles. AuraASIO is user-mode and exempt.

----------------------------------------------------------------
4. 方案 A：持久开启测试签名（推荐 / persistent）
----------------------------------------------------------------
  1) 以管理员身份打开「命令提示符」，执行：
         bcdedit /set testsigning on
  2) 重启电脑。桌面右下角出现「测试模式 / Test Mode」水印属正常。
  3) 若提示「该值受 Secure Boot 策略保护」：进 BIOS 关闭 Secure Boot
     （若有 BitLocker，先暂停保护并准备恢复密钥）。
  4) 若 Windows 11 仍失败：Windows 安全中心 → 设备安全性 → 核心隔离
     → 关闭「内存完整性」，再重启一次。
  5) 回到本目录，以管理员身份运行 install_vaio.ps1 -Action install。
  6) 恢复默认安全状态：bcdedit /set testsigning off 后重启，
     并重新开启 Secure Boot / 内存完整性。

  1) Elevated cmd:  bcdedit /set testsigning on      2) Reboot.
  3) If "protected by Secure Boot policy": disable Secure Boot in BIOS
     (suspend BitLocker first).
  4) Windows 11: Windows Security > Device security > Core isolation >
     turn off Memory Integrity, then reboot.
  5) Run install_vaio.ps1 -Action install as administrator.
  6) Revert: bcdedit /set testsigning off, reboot, re-enable Secure Boot/HVCI.

----------------------------------------------------------------
5. 方案 B：临时禁用驱动签名强制（仅本次开机有效）
----------------------------------------------------------------
  设置 → 系统 → 恢复 → 高级启动「立即重新启动」
    → 疑难解答 → 高级选项 → 启动设置 → 重启
    → 按 7 或 F7「禁用驱动程序签名强制」。
  进入系统后立刻以管理员身份运行 install_vaio.ps1 -Action install。
  注意：下一次正常重启后该设置自动失效，驱动会再次被拒绝加载。

  Settings > System > Recovery > Advanced startup > Restart now
    > Troubleshoot > Advanced options > Startup Settings > Restart
    > press 7 / F7 "Disable driver signature enforcement".
  This is ONE-BOOT ONLY: it resets on the next normal reboot.

----------------------------------------------------------------
6. 无法开启测试签名时 / If you cannot enable test-signing
----------------------------------------------------------------
  可以照常使用 AuraDSP 的进程内 WASAPI / Voicemeeter / 系统 APO 等形态，
  但 AuraVAIO 虚拟声卡设备不会出现，也无法作为系统默认输出设备使用。
  正式分发需要微软 Attestation 或 EV 签名，属项目已登记的外部待办项。

  AuraDSP itself still works (WASAPI / Voicemeeter / APO modes), but the
  AuraVAIO virtual device will NOT be available. A production release needs
  a Microsoft Attestation/EV signature; that is a known external TODO.

  参考 / References (Microsoft Learn):
   - "Loading Test Signed Code - Windows drivers"
   - "Preparing a Computer for Manual Driver Deployment"
