# Spike2 技术报告：AIDL-native 效果库全链路验证（Android 16 / Ace 6T）

**日期**：2026-10-08
**结论**：✅ **AIDL-native 路径完全打通**。JamesDSP 在 Android 14+ 的正式实现路线已验证可行。

---

## 1. 验证目标

Phase 1（legacy AELI 库）已证明：Android 16 的 QTI effects HAL **拒绝** legacy `audio_effect_library_t` ABI，
要求 AIDL-native 的 `createEffect` / `queryEffect` / `destroyEffect` 导出。Phase 2 的目标是构建一个完整的
AIDL-native 效果库（biquad EQ），验证从 HAL 加载 → AudioFlinger 枚举 → app 侧 attach → FMQ 数据面 →
状态机 → 销毁的**全链路**。

## 2. 架构与产物

```
out/libspikeeq.so (5.8MB, 16KB 页对齐)
├── src/aidl/SpikeEffect.{h,cpp}   IEffect/BnEffect 实现（状态机 + FMQ + biquad 工作线程）
├── src/aidl/SpikeExports.cpp      extern "C" 三导出（HAL dlsym 入口）
├── gen/                           138 cpp + 414 h（aidl --lang=ndk --structured --stability=vintf）
│   ├── effect V3 / audio.common V4 / hw.common V2 / fmq V1 / media V4
├── aidl-src/libfmq                LineageOS libfmq（静态编入，提供 AidlMessageQueue）
├── aidl-src/frameworks_native     binder ndk 头（NDK sysroot 缺 binder_interface_utils.h）
├── third-party/                   自写 stub 层（见 §4）
└── version_script.txt             只导出 createEffect / queryEffect / destroyEffect
```

**导出符号（与设备 QTI 库 libdownmixaidl.so 模式一致，全部 extern "C"）**：

```cpp
binder_exception_t createEffect(const AudioUuid*, std::shared_ptr<IEffect>*);
binder_exception_t destroyEffect(const std::shared_ptr<IEffect>&);
binder_exception_t queryEffect(const AudioUuid*, Descriptor*);
```

签名依据：本地 sparse checkout 的 AOSP `audio/aidl/default/include/effect-impl/EffectTypes.h`
（EffectCreateFunctor / EffectDestroyFunctor / EffectQueryFunctor 三个 typedef），并经设备库符号反解佐证。

## 3. 全链路验证结果（Enforcing 模式）

| 阶段 | 证据 |
|---|---|
| HAL 加载 | `openEffectLibrary` dlopen 成功（前期失败的 UND 符号逐一修复后） |
| 效果枚举 | `EffectsFactoryHalAidl with 10 nonProxyEffects`（注入前 9）；`queryEffect: SpikeEQ descriptor returned` |
| AudioFlinger 枚举 | `BufferProvider: effect 4 is called SpikeEQ Aidl, type bed4300` |
| App 侧 attach | MiniAttach（app_process + 反射 hidden 构造）attach session 0：`created, id=43` |
| open() | `sr=48000 inF=1920(ch2)`；3×FMQ 建立（status 1 深度带 EventFlag / input 15360B / output 15360B） |
| biquad 初始化 | `fs=48000 b=[1.094420 -1.920086 0.842234] a=[1 -1.920086 0.936654]`（1 kHz +12 dB peak） |
| 状态机 | `command: 1 (state=1)`：START 触发 IDLE→PROCESSING，工作线程就绪 |
| 销毁 | `enabled OK` → 20s 后 `released.` → destroyEffect 干净返回 |

## 4. 关键实现决策

1. **不依赖进程内 VNDK 库**：cutils（native_handle/ashmem）、libbase（unique_fd/logging）、libutils
   （Log/Errors/SystemClock）全部用自写 stub + 自带实现编译进库，`-fvisibility=hidden` +
   version script 保证只有 3 个符号导出，与进程内真库零冲突。
2. **memfd 被拒**：Oplus 收紧 `hal_audio_default` 域 —— `memfd_create` 后 `ftruncate` EACCES、
   `/dev/ashmem` open EACCES（dmesg avc 实证）。`ksud sepolicy patch` 仅对 ashmem_device 生效，
   file:write 类未生效。
3. **终极方案：file-backed FMQ**。在 HAL 自己的可写目录 `/data/vendor/audio/` 创建
   `.spike_fmq_*` 文件（O_RDWR|O_CREAT + ftruncate），MAP_SHARED 的普通文件 fd 经 binder 传给
   audioserver 后 mmap 同一页缓存 —— 跨进程共享成立，且 **fd 接收方（audioserver）无需任何新 SELinux 权限**
   （fd 打开时的 LSM 检查已完成）。三级回退链：memfd → /dev/ashmem → file-backed。
4. **FMQ 位常量**（`system/audio_effects/aidl_effects_utils.h` 实证）：V3 用
   `kEventFlagDataMqNotEmpty = 0x1 << 11`；bit 0x1/0x2 是 FMQ 内部位，不可占用。
5. **MiniAttach**（`attach-test/`）：shell 级 app_process + 反射调用 hidden 的
   `AudioEffect(UUID,UUID,int,int)` 构造，shell/root uid 免去 app 安装，可作为后续所有验证的标尺工具。

## 5. 踩坑清单（已全部回写到脚本）

| # | 坑 | 修复 |
|---|---|---|
| 1 | 生成 cpp 的 obj 用 basename 撞名（`effect/Capability.cpp` vs `eraser/Capability.cpp`）→ UND | obj 名用相对路径转 `_` |
| 2 | NDK sysroot 无 `binder_interface_utils.h` | 加 frameworks_native `include_cpp/ndk/platform` |
| 3 | xml `<effect>` 缺 `type` 属性 → QTI HAL `loadEffectLibs` skipping | patch_xml.py 注入 type（Phase 1 教训曾未回写，本次双写） |
| 4 | `makeUuid` 定义落在全局 namespace → UND | 定义移入 `aidl::android::hardware::audio::effect` |
| 5 | stub 实现漏 `extern "C"`（android_errorWriteLog）→ UND | 补 extern "C" |
| 6 | NDK `.cmd` wrapper 从 Git Bash 调用不可靠 | 直接调 `clang++.exe` + `--target/--sysroot` |
| 7 | libfmq 用 `std::format` | `-std=c++20` |
| 8 | rollback 顺序：先 umount 后 kill → tmpfs busy | 先 `killall audioserver` 再 umount，`umount -l` 兜底 |

## 6. 发现的平台限制（影响正式设计）

- **QTI HAL 的 `queryProcessing` 原生失败**（`EX_ILLEGAL_ARGUMENT: getDescriptorFailed`，部署 Spike 前即存在）：
  xml `<postprocess>` 自动挂链在此设备不可用。正式版 EffectRegistrar 需走 **app 侧显式 attach**
  （RootlessJamesDSP 式），或联合 Oplus 修该路径。
- **Oplus 收紧 SELinux**：`hal_audio_default` 无 ashmem/memfd 权限 —— 正式版部署（magisk/KSU 模块）
  必须自带 sepolicy 规则或采用本报告的 file-backed 方案。
- spike 期间注入的 ksud sepolicy 规则为 live patch，重启即失效，无残留。

## 7. 下一步（Spike3 / 正式化）

1. **EffectRegistrar**：HidlRegistrar(≤13) / AidlRegistrar(14+) 双实现收敛进 core/；
   Aidl 侧封装本 spike 的库骨架（Descriptor 工厂、FMQ 生命周期、file-backed 分配器）。
2. **接 libjamesdsp**：把 spike 的 biquad 处理点替换为 libjamesdsp 引擎（float 48k 路径）。
3. **真实音频流验证**：MiniAttach + 播放，验证 process 线程实际吞吐与音效可闻性。
4. **部署形态**：KSU 模块（tmpfs overlay + bind xml + sepolicy.rule）固化为 install 脚本。
