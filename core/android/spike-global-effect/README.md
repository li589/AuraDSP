# SpikeEQ — M0 全局音效效果库 Spike（Android 16 / AIDL 时代）

> 目标：证明「自研效果库 → 注册进系统效果工厂 → 挂上全局 session 0」这条路在
> OnePlus Ace 6T（ColorOS 16.0.8 / API 36 / AIDL HAL / KSU Next）上可行。
> 通过后，libjamesdsp 以同样方式接入，`EffectRegistrar` 即可正式进 `core/`。

## 原理（实测定案，见 docs/forensics/2026-10-08_Ace6T_A16/）

- 效果工厂加载顺序：`/vendor/etc/audio_effects.xml` → **`/odm/etc/audio_effects_config.xml`（本机生效）** → `/system/etc/audio_effects.xml`，取第一个存在的。
- 库检索：`checkLibraryPath` 按 `/odm/lib64/soundfx` → `/vendor/lib64/soundfx` → `/system/lib64/soundfx` 顺序 dlopen（XML 里写裸文件名即可）。
- **接口形态：legacy `audio_effect_library_t`（API 2.0）**——本机 OplusAudioX 的 apiVersion=0x20000 证实，AIDL 时代依旧兼容，无需实现真 AIDL 接口。libjamesdsp 即此接口。
- session 0 全局效果链活跃（OplusAudioX 正挂在 AudioOut_1D，insert/first）。
- 本设备无音频 APEX；/system/lib64/soundfx 不存在；SELinux Enforcing。

## SpikeEQ 行为

- 自定义 impl UUID `8e73f7a1-3c92-4f6b-9d5e-7a1b2c3d4e5f`，type=标准 EQ。
- 1kHz 峰值均衡 +12dB、Q=1.0（RBJ cookbook），float/s16 双格式，最多 8 声道。
- 经 `<postprocess><stream type="music">` 自动附加，**无需写测试 App**：放音乐即可验证。
- logcat 标签 `SpikeEQ`：create/SET_CONFIG/ENABLE 各有日志，`ENABLE` 打印即全局生效铁证。

## 构建

```bash
# NDK r30: D:/myPrograms/AndroidDevelop/Android-SDK/ndk/30.0.14904198
cd core/android/spike-global-effect
aarch64-linux-android34-clang -O2 -fPIC -shared -Wall src/spike_eq.c \
  -o out/libspikeeq.so -llog -lm -Wl,-z,max-page-size=16384
```
- `-Wl,-z,max-page-size=16384`：Android 15+ 16KB page size 必须。
- 已验证产物：AArch64，LOAD align 0x4000，导出符号 `AELI`。

## 部署（临时挂载，reboot 即失效——安全设计）

```bash
bash deploy/deploy.sh     # KSU 授权弹窗请在手机上确认
bash deploy/rollback.sh   # 撤销
```
步骤：tmpfs 覆盖 `/vendor/lib64/soundfx`（含原库全量拷贝 + spike so，chcon 保持 vendor_soundfx 标签）→ bind-mount 补丁版 odm xml（chcon odm_etc 标签）→ `killall audioserver`（init 自动拉起）→ logcat + dumpsys 验证。

## 验证清单（Spike 通过标准）

1. `logcat` 出现 `EffectsFactoryConfigLoader` 无报错 + `SpikeEQ: create SpikeEQ sessionId=...`
2. `dumpsys media.audio_flinger` 的 music 输出线程出现 SpikeEQ Effect Chain（Registered）
3. 主观听音：1kHz 附近明显凸起（+12dB），关掉（rollback）声音恢复
4. 与 OplusAudioX 共存：两者同链，无 audioserver 崩溃循环

## 已知风险

- 代码崩溃 = audioserver 崩溃循环（init 自动重启，rollback 即恢复）。
- bind/tmpfs 挂载在 su 会话的全局 namespace 执行；OTA/重启自动清除。
- 若 SET_CONFIG 声道掩码异常（如原始流非标准掩码），nch 回退 2。

## 对正式架构的输出

- `EffectRegistrar.AidlRegistrar` = 「AIDL 库进 soundfx 目录 + XML 注册 + （Root）挂载持久化为 KSU/Magisk 模块」三件套；Spike 的 patch_xml.py 即其雏形。
- 正式库替换 `spike_eq.c` 的 DSP 为 libjamesdsp（同接口、float 管线已验证）。
- 共存策略需处理 OplusAudioX 的 `insert pref: first`（Spike 未指定 pref，默认 any，排在其后）。
