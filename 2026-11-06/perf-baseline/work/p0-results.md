# P0 施工复测记录（同一套脚本：measure.py / gpu_sampler.ps1）

窗口 1400x900，32 核；release 构建 `flutter build windows --release --no-tree-shake-icons`。
基线数据见 `outputs/baseline-stages.csv`（提交 50cbe83）。

## P0-1 静默门控（停 Ticker）

真实频谱峰值 > 0.001（约 −60 dBFS）或 level > −60 dBFS 判为有声，首个有声帧立即开闸；
连续静默 2 s 关闸。暂停/无媒体立即关闸。门控后的频谱代理不再向视口转发零值帧。

| 阶段 | | RSS avg/max (MB) | Private avg (MB) | CPU (avg %core / max) | GPU 3D avg | GPU shared avg |
|---|---|---|---|---|---|---|
| 播放态+频谱全零+关歌词（强制 playing） | 改前 | 602 / 662 | — | 163.8 / — | 32.0% | 188 MB |
| 同上 | 改后 | 334.4 / 335.0 | 333.6 | 1.1 / 4.7 | 0.00% | 170.6 MB(注) |
| 可视化页未播放 | 改前 | 349.5 / 350 | — | 1.2 / — | 1.9% | 43 MB |
| 同上 | 改后 | 378.6 / 379.0 | 373.8 | 0.19 / 1.6 | 0.00% | 179.8 MB(注) |

注：本轮 GPU Process Memory 计数器取到的 shared 是单个实例的常驻进程级值（改前后采样口径不同，
基线表里的 shared 为均值且含计数器抖动尖峰），只作参考；3D 引擎占用与 CPU 是可比的。
GPU 3D 采样：`work/gpu_p01_forced.csv`、`work/gpu_p01_idle.csv`；进程采样见 `work/stages_p01/`。

未播放页 RSS 较基线 +29 MB：该轮为启动后约 10 s 即测，基线为启动后数分钟稳定态；
后续项复测会拉长稳定时间复核。

设计上的装饰性呼吸动画：可视化舞台在无声/暂停时走 `VisualizerIdlePlaceholder`（纯静态），
未发现需要保留的常驻呼吸动画，因此无需另开 ≤10 fps 低功耗路径。

## P0-2 产帧节奏固定 30 Hz

用临时插桩（合成有声频谱 + 全局帧计数，测完已回退）在同一 1400x900 窗口复测。
基线 85 fps（中位，范围 70.6–111.4）。

| 阶段 | RSS avg/max (MB) | CPU avg %core | GPU 3D avg | 产帧 |
|---|---|---|---|---|
| 改前（vsync + 每两帧推进） | 602 / 662 | 163.8 | 32.0% | 85 fps（中位） |
| 改后（33 ms Timer.periodic） | 532 / 535 | 66.2 | 24.3% | 33 fps（27–51，500 ms 合成帧的额外重绘） |

144 Hz 路径：旧实现时间轴 = 刷新率/2 ≈ 72 Hz（时间轴 2.3 倍速）；改为固定 33 ms 后
任意刷新率都约 30 Hz、时间轴步长 0.032 s 接近真实时间。

GPU 3D 降幅小于帧数降幅：计数器含合成器等非帧率线性开销，且本轮为全屏覆盖绘制；
CPU/帧率是可比的硬指标。采样：`work/gpu_p02.csv`、`work/p02_out.log`。

## P0-3 去掉 HUD BackdropFilter

保持 HUD 可见（光标在画布内每 0.9 s 移动一次），其余条件不变。

| 阶段 | RSS avg/max (MB) | CPU avg %core | GPU 3D avg | GPU shared avg |
|---|---|---|---|---|
| 改前（sigma 12 BackdropFilter） | 609 / 611 | 91.0 | 31.9% | 332 MB |
| 改后（ClipRRect 无模糊，同 Linux 路径） | 531 / 533 | 88.2 | 29.0% | 267 MB |

差值为 −78 MB 内存、−65 MB 显存、−2.9pp GPU、−2.8pp CPU，未达到方案里
−210 MB / −96 MB 的预估。原因：该预估来自基线 85 fps + 全屏背景卷积的旧节奏；
本轮帧率已先降到 33 fps（P0-2），模糊层每帧只覆盖 HUD 岛区域而非整屏，
卷积与离屏纹理的绝对开销随之减小。方向正确，量级需按当前帧率修正。
采样：`work/gpu_p03_before.csv`、`work/gpu_p03_after.csv`、`work/stages_p03/`。

