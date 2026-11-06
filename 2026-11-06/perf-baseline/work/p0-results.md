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
