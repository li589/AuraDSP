# tools/remote — 远程测试 / 传输 / 控制脚本登记

开发机（kavl-4s88og）与宾机（vm-win10）之间的实测通道工具集。此前这些
脚本以一次性文件散落在开发机 `C:\Users\likr\` 与 VM 的临时目录里、每轮
重写；2026-11-24 按 user 指示收编入仓，此后改脚本先改这里。

## 机器与通道约定

- **开发机**：Win11，克隆在 `D:\temp_desktop\Proj\JamesDSP`，VM 经
  Tailscale + SSH 免密到达（梯子/VPN 开着会打断 Tailscale 中继，先关）。
- **宾机 vm-win10**：`192.168.204.129`，用户 `li`；从开发机走局域网直连
  `ssh/scp -i C:\Users\likr\guest_key li@192.168.204.129`（秒达）。经
  Tailscale 中继给宾机传大文件必须 `scp -l 4096` 限速且仍可能截断，
  大文件一律走开发机直连。
- **可靠执行通道**：嵌套交互 ssh 会话会挂死（实测最长 45 分钟无回，
  且杀本地客户端不影响远端进程）。长任务一律用**开发机计划任务**
  承载（`Invoke-DevTask.ps1`），宾机侧命令用 `Start-Process ssh -Wait`
  + 输出重定向落盘后读文件（`Invoke-GuestScript.ps1` 的形态）。
- **交付只认回读核对**：scp 退出码不作数；文件落地以宾机侧回算的
  大小 + SHA-256 与源端一致为准（`Send-ToGuest.ps1` 内建）。
- PS 脚本保持纯 ASCII：PS 5.1 按系统码页读无 BOM 的 .ps1，中文字面量
  会乱码；中文判读走原始字节 + Python 严格解码。宾机/开发机上跑
  Python 冒烟时设 `PYTHONIOENCODING=utf-8`，防 GBK 控制台打印崩溃
  造成假红。

## 脚本登记

| 脚本 | 跑在哪 | 用途 |
|---|---|---|
| `guest_telemetry.py` | 宾机 | 采样 ASIO 遥测块 `Global\AuraDSP_AsioDriverTelemetry`：dawCh/running + 逐声道 peakInCh/peakOutCh。判读口径见脚本头注。`--samples/--interval` 可调 |
| `guest_file_info.py` | 宾机 | 打印指定文件大小 + SHA-256（交付回读核对的宾机侧一半） |
| `guest_reaper_state.py` | 宾机 | 回读 reaper.ini 的 `[asiochan]` 声道范围。注意范围全开 ≠ 路由正确：轨道与主轨 Track channels 仍须各自设 8（2026-11-24 ASIO 三至八声道案的定罪点） |
| `asio_registration_probe.py` | 任意 Windows 主机 | 枚举 HKLM/HKCU ASIO 注册名单、AuraDSP Driver 的 CLSID 与 InprocServer32 指向 DLL 的 mtime/大小。开发机当前无注册属正常（REAPER 实测在宾机） |
| `Invoke-GuestScript.ps1` | 开发机 | 把同目录的宾机 Python 脚本 scp 过去并经 ssh 执行，输出落盘回读。长任务请再套 `Invoke-DevTask.ps1` |
| `Invoke-DevTask.ps1` | 开发机 | 以一次性计划任务启动一个 .ps1（脱离 ssh 会话，长任务标准通道） |
| `Send-ToGuest.ps1` | 开发机 | 投递文件到宾机桌面（或指定目录）并回读哈希验证 |
| `Restore-DriverCertTrust.ps1` | 开发机（提权） | 从已签名的 .cat 提取内嵌签名者证书，导入 LocalMachine Root + TrustedPublisher，恢复打包签名门所需的信任（2026-11-23 r66 事故的修复脚本） |
| `sync_to_vm.py` / `vm_exec.py` | VM | 早期 vm-linux 同步/执行工具（paramiko），保留登记，现状以脚本头注为准 |

## 已知不可行

- **读 ASIO 参数块** `Global\AuraDSP_AsioDriverParams`：块的 DACL 拒绝
  App 进程之外的 MapViewOfFile（宾机交互会话计划任务里实测 err 5）。
  参数是否送达驱动，只能从遥测图案与行为侧判别，不要再写外部读块
  脚本。
- 宾机 ssh 令牌未提权：驱动安装/卸载只能由 user 在宾机 App/向导里
  触发，脚本侧不要尝试。
