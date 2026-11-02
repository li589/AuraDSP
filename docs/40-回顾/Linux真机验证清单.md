# Linux 真机验证清单

> 用途：在真实 Linux 桌面机器上验证 AuraDSP 的 Linux 移植（一期 S0–S5c）。
> 无头 VM / CI 只能覆盖门禁与协议层；本文的项目都依赖真实硬件或真实
> 桌面环境（声卡缓冲、snd-aloop 内核模块、StatusNotifier 面板、软件
> OpenGL 渲染），**每次合入 dev 前应至少完整跑一遍**。
>
> 基准环境（2026-11-02 首次全量通过）：Ubuntu 24.04 + PipeWire（pulse
> 兼容层）+ Xubuntu/XFCE 4.18；软件 OpenGL（VMware SVGA3d / llvmpipe）。
> 期望值以当时的门禁口径书写，门禁数量变化时以 runner 实际输出为准。

## 0. 准备

```bash
git checkout feature/linux   # 或待验证的目标分支
sudo apt install clang cmake ninja-build pkg-config \
  libgtk-3-dev liblzma-dev pulseaudio-utils python3
# Flutter stable（Dart >= 3.13.5）
```

发行版自带 PipeWire 的无需装 PulseAudio 本体：应用走 PulseAudio
协议，pipewire-pulse 兼容层即可（基准环境即此形态）。

## 1. 自动化门禁（约 12 分钟）

```bash
cd app/auradsp_app && flutter analyze
#   期望：No issues found!
cd ../.. && python3 test/runner.py --smoke
#   期望：PASS 12 / SKIP 125 / FAIL 0
#   （125 SKIP 是 Windows 专属门禁在 Linux 的正确跳过，不是失败；
#    smoke_linux_driver_loopback 在未加载 snd-aloop 时计 PASS-自跳过，
#    第 3 节加载模块后应复跑一次确认其真跑通过）
python3 tools/bin/run_dart_tests.py   # 需 flutter 在 PATH
#   期望：PASS 59 / FAIL 0 / SKIP-PLATFORM 4
```

## 2. 构建与启动

```bash
cmake --preset linux-x64 && cmake --build --preset linux-x64-release
cd app/auradsp_app
flutter build linux --release --no-tree-shake-icons   # 标志不可省（仓库硬性要求）
./build/linux/x64/release/bundle/auradsp_app
```

- [ ] 窗口正常打开，主页频谱/电平区无渲染损坏
- [ ] **软件 OpenGL 专项**（Impeller 已在 Linux runner 关闭、走 Skia GL）：
      连续滚动设置页、开关对话框、切换页面，观察有无整窗重绘损坏
      （描边消失、文字变纯色块、控件错位、异常色扇形）。出现即回归
      `080beb0` 的修复

## 3. 三模式（设置页 → 音频）

前置（driver 模式）：

```bash
sudo modprobe snd-aloop index=2 enable=1
cat /proc/asound/cards    # 应出现 Loopback
```

注意：`enable` 是每卡数组，**只写 `enable=1`**。写 `enable=1,1` 会
创建两张回环卡，且 PA 枚举顺序与 `index=2` 不一致（2026-11-02 实机
教训，已同步修正应用内提示文案与 ADR-012）。

- [ ] **system**：默认模式播放测试音/文件，真实声卡出声；拖动 EQ
      有可闻变化
- [ ] **默认输出热切换**：播放中在系统设置里切换默认输出设备
      （如拔插 USB 声卡/耳机），声音应跟随到新设备。机制在服务端：
      PulseAudio 核心会迁移未被显式钉住的流（VM 已实测，同一条流
      双向跟随）；PipeWire 侧由 WirePlumber 默认策略迁移——本项即
      为确认 PipeWire 侧行为与此一致，若不跟随再议客户端方案
      （pa_simple 无流落点查询能力，不做盲目客户端迁移）
- [ ] **virtual**：切到 virtual 后 `pactl list short sinks` 出现
      `auradsp_virtual`；用任意播放器把输出指到该设备，处理后的声音
      从真实默认设备出；主页频谱与可视化舞台随外部音频活动
      （频谱门已含 `linuxCaptureActive`，装睡即回归 `476fb8e`）
- [ ] **driver**：切到 driver，设置页无「未加载 snd-aloop」提示；
      播放器输出指到 Loopback 设备后，处理声从默认设备出。
      采集源应为回环 sink 的同名 `.monitor`（`alsa_input.*` 恒为 0，
      采它即回归 `76e8c14`）；可跑
      `python3 test/smoke/smoke_linux_driver_loopback.py` 应真跑 PASS
- [ ] **输出泵饿死回归**（`0d79cd3`）：以上三项必须在**真实声卡**
      （非 null-sink）上验出声——真机 `pa_simple_get_latency` 含设备
      侧缓冲（实测 ~10.4k 帧），曾使泵的可用帧恒负而永不写入、无声；
      null-sink 环境验不出此问题

## 3b. ALSA 专家模式（二期，设置页 → Linux 设备卡切换后端）

- [ ] 后端切到「ALSA 直连（专家模式）」后引擎自动重启，状态区
      显示 ALSA 协商结果（目标：period 256 帧、buffer 1024、
      float32 或 s16 回退）；切回 PulseAudio 同样自动恢复
- [ ] **真实声卡直开**：设备名填 `hw:<卡>,<设备>`（如 `hw:1,0`）
      播放出声，与 PA 模式对比主观延迟（专家模式应明显更低）；
      设备名留空走 `default`
- [ ] **PipeWire 占用行为**：在 PipeWire 系统上对被 WirePlumber
      占用的声卡直开 hw:，预期为明确的打开失败（EBUSY 文案出现
      在状态/日志），不崩溃、不静默回退 PA；释放设备后可正常打开
- [ ] **driver 直采**：加载 snd-aloop（`enable=1` 单卡）后切
      driver 模式，采集应走 ALSA 直连（日志 `LINUXMODE capture
      attached (ALSA): hw:Loopback`），播放器灌入回环后处理声
      出声、频谱活动；与 PA 路径（.monitor）各验一遍

## 3c. 插件宿主（二期：进程内 + 双宿主隔离）

前置：release bundle 的 lib/ 内含 libauradsp_engine.so 与
plugin_host_x64（开 multilib 构建时另有 plugin_host_x86）。

- [ ] 插件页可打开（不再是「不支持」占位），扫描目录区可见，
      预置目录含 ~/.vst3、~/.clap 等
- [ ] 把任一真实 VST3/CLAP 插件放进扫描目录 → 扫描出现条目 →
      挂载到插槽出声（进程内路径，出声即通）
- [ ] 隔离模式：以 `AURA_PLUGIN_HOST_MODE=process ./auradsp_app`
      启动后重复上项；任务管理器/`pgrep plugin_host_x64` 应见
      宿主进程；播放中 `kill` 掉宿主，引擎应降级存活（不崩主
      程序），重载插件可恢复
- [ ] （装有 32 位插件时）32 位 VST3 插件经 plugin_host_x86
      桥加载出声（需系统支持 IA32 执行：`gcc -m32` 的 hello
      world 能跑通即满足；VM 内核禁用 IA32 的环境此项跳过，
      属环境限制非产品缺陷）
- [ ] 插件编辑器按钮：Linux 下应明确不可用（能力层 canEdit=false），
      不假死、不崩溃

## 3d. 打磨验收（2026-11-02 打磨三期，设置页 → Linux 设备卡/模式卡）

- [ ] ALSA 后端下设备卡出现「ALSA 采集设备」行：编辑对话框枚举只列可采集
      设备（IOID=Input），选 hw:Loopback 或手填后保存，driver 模式出声正常
      （三期 B3/C1：此前该字段只能手改配置文件）
- [ ] virtual/driver 模式运行中停掉 PipeWire/PulseAudio（或拔掉采集设备）：
      模式卡出现「音频采集中断」类提示，不再静默无声而状态显示正常
      （二期 B2 capture-lost 回推）
- [ ] virtual 模式下把系统默认输出切成 auradsp_virtual：模式卡出现反馈环
      警告；system 模式下默认输出为虚拟设备时出现软提示（二期 B5）
- [ ] 故意让采集失败（如 ALSA 后端填不存在的采集设备名切 driver 模式）：
      模式卡显示具体失败原因文案，而非只有通用提示（二期 B1 note 渲染）

## 4. 桌面集成

- [ ] **托盘**：面板出现 AuraDSP 图标（PNG）；关窗最小化到托盘不退出；
      右键菜单（显示主窗口 / 开机自启 / 退出）可用。
      已知桌面差异（2026-11-02 XFCE 实测）：XFCE systray 的
      `menu-is-primary=true` 时左键弹菜单（菜单项恢复窗口为可靠路径）；
      GNOME/KDE 按 ItemIsMenu=false 走 Activate 左键恢复。原生 GNOME
      无 AppIndicators 扩展时托盘图标不显示，属环境缺件、非应用缺陷；
      面板重启后已有 SNI 项不会被重新读取，图标需重启应用恢复
- [ ] **开机自启**：设置页打开开关 →
      `~/.config/autostart/auradsp.desktop` 出现；注销重登录自动启动；
      关闭开关文件消失
- [ ] **XDG 目录**：改几个设置后退出：
      `~/.config/auradsp/` 应只有 `config.json`、`file_paths.json`；
      `~/.local/share/auradsp/` 应有 `session_state.json`、`presets/`、
      `plugin_data/`、`plugins/`、`liveprog/`。
      若机器上留有拆分前旧数据（全在 `.config/auradsp` 下），首次启动
      应自动迁入数据根、旧位置不残留
- [ ] **MPRIS**：用 VLC / Spotify / 浏览器播放歌曲，AuraDSP 歌词同步
      能拿到标题、艺术家、专辑与进度推进

## 5. 故障取证

任一项不过，先留这三样再报：

```bash
/tmp/auradsp_debug.log            # 搜 LINUXMODE / PULSE / AudioOut started
pactl list short sinks; pactl list short sources
cat /proc/asound/cards            # driver 问题时
```

并注明：哪一步、期望、实际、桌面环境与音频栈（PulseAudio 本体 /
PipeWire 版本）。
