# M0 专项调研：Android 14+ 音频 session / audio policy 变更与失效根因

> 里程碑：M0（立项调研） | 状态：已完成初版 | 日期：2026-10-08
> 调研对象：JamesDSP v6.1 Magisk 模块在 Android 14/15/16（MIUI14 / HyperOS2 / ColorOS16）失效根因；RootlessJamesDSP 机制与其问题。

---

## 1. 结论速览（TL;DR）

**你最初猜测的「session 0 政策变了」只对了一小半。真正的根因是：**

1. **Audio HAL 从 HIDL 迁移到 Stable AIDL**（Android 14 起），音效框架的加载/注册路径随之重构。旧模块用 HIDL 时代方式注册的 `libjamesdsp.so`（写 `audio_effects.conf` + 拷到 `/system/lib/soundfx`）在新链路上**不再被效果工厂拾取** → 表现为「找不到 libjamesdsp.so」或「无法初始化引擎」。
2. **APEX 化**：Android 14+ 部分设备的音效配置与库挂载点进入 APEX 模块（`/apex` 下）。社区模块 v6.5 专门新增了 `mount_apex()` 扫描 `/apex` 下的 soundfx 才恢复可用。
3. **AIDL 库版本兼容问题**：不同 Android 版本编译的 AIDL 效果库接口版本不一致，v6.5-RC3 需要用 `patchelf` 动态修补才能跨版本运行。
4. **session 0 本身**：官方文档明确「attach insert effects 到全局输出 mix（session 0）已弃用多年，但仍支持」。它不是 14+ 才坏掉的，**真正的断点是效果库的注册与加载链路**。
5. RootlessJamesDSP 的降级根因不同：它依赖 **AudioPlaybackCapture（内部音频捕获）**，Android 15 新增「屏幕共享隐私防护」直接冲击其通知/捕获链路，需要在开发者选项中关闭防护才能工作。

**一句话：Android 14+ 的失效 = AIDL 迁移（主因）+ APEX 挂载点变化（次因）+ AIDL 版本碎片（工程债），三者叠加。社区已有证明可行的修复路径（见第 5 节），但全是 hack——这恰好验证了我们「从零重做」的决策。**

---

## 2. Android 12 → 16 音频栈变更时间线（证据）

| 版本 | 变更 | 对音效类应用的影响 | 证据来源 |
|---|---|---|---|
| Android 8.1 | 引入 `audio_effects.xml`，优先级高于旧 `audio_effects.conf` | 双配置并存，老方式仍兼容 | AOSP EffectsFactory 源码解析（EffectLoadXmlEffectConfig → fallback conf） |
| Android 11 | 新增「设备级音效」：效果必须由 vendor 库实现并列于 `audio_effects.xml` | 效果注册进一步向 vendor 分区收敛 | source.android.com Audio Effects |
| Android 12 (API 31) | Audio HAL V7：框架/HAL 数据模型统一、XML 枚举改字符串；厂商开始收紧 soundfx | 兼容尚可 | source.android.com HIDL Audio HAL |
| **Android 14 (API 34)** | **Audio HAL 迁移 Stable AIDL**；音频策略配置从 vendor XML 改为由 HAL 提供（APM 从 HAL 拿配置）；Effects HAL AIDL 化（IFactory/Descriptor/IEffect）；多 USB 设备路由、sound dose | **核心断点**：HIDL 时代的效果注册链路失效；CAP（可配置音频策略）未实现 | source.android.com AIDL Audio HAL、Android 14 release notes |
| **Android 15 (API 35)** | 直接/分流（offload）音轨达资源上限时**使已打开的 AudioTrack 失效**；targetSdk 35 请求音频焦点受限；**屏幕共享隐私防护**（敏感内容向远程查看者隐藏）；16KB page size 支持 | Rootless 捕获类应用被冲击（需关防护）；native 库需 16KB 对齐 | developer.android.com 15 行为变更、RootlessJamesDSP README |
| Android 16 (API 36) | **CAP 在 AIDL HAL 落地**（14/15 缺失的部分补齐）；Auracast；AIDL 配置加载机制变更 | 效果注册路径进一步变化，AIDL 库需按版本适配 | source.android.com Android 16 release notes |

**为什么 12/13 大部分正常、14+ 几乎必挂**：12/13 设备（尤其 MIUI 12/13）绝大多数仍是 HIDL 音频 HAL，旧的注册方式依然有效；14 起厂商（HyperOS2、ColorOS16）转向 AIDL 音频 HAL，旧模块的注册/挂载路径同时被 APEX 化改造切断。

---

## 3. 三类故障的根因链

### 3.1 Magisk 模块：「找不到 libjamesdsp.so」/「无法初始化引擎」

故障链：

```
Android 14+ 设备启用 AIDL 音频 HAL
  → 音效配置/加载路径 APEX 化（/apex 下 soundfx）
  → 旧模块只写 audio_effects.conf + 拷贝 .so 到 /system/lib/soundfx
  → 新效果工厂（AIDL EffectsFactory）不拾取该库
  → 效果 UUID 未注册
  → App 侧 AudioEffect 创建失败
     · lib 检查失败 → 「Magisk module not installed. Failed to load libjamesdsp.so」
     · 或运行时抛 「Cannot initialize effect engine for type: <uuid> Error: -3」
```

佐证：
- JamesDSPManager 官方 issue #6 中，缺库时的报错正是 `Cannot initialize effect engine ... Error: -3`（AudioEffect 创建失败）。
- App 侧的「找不到 so」检测是**应用自己的前置检查**（检查效果是否已注册可用），并非真正的文件缺失——文件在 `/vendor/lib/soundfx/` 里也照样报错（XDA 案例：库文件存在但检测失败）。
- **社区修复完全吻合**（见第 5 节）：v6.4 适配 AIDL + 自带 AIDL 音效库后恢复可用。

另注意：部分 12/13 上的偶发失败与 **Magisk 26 的模块挂载机制变更**（mmt-ex 脚本兼容性，需 "Huawei method"）有关，属另一条独立故障线。

### 3.2 session 0 的真实角色

- 官方文档：*"attaching insert effects (equalizer, bass boost, virtualizer) to the global audio output mix by use of session 0 is **deprecated**"*（弃用多年但**仍支持**）；在输出 mix 上创建效果需要 `MODIFY_AUDIO_SETTINGS` 权限。
- 音效链架构（AudioFlinger 源码注释）：`AUDIO_SESSION_OUTPUT_MIX == 0` 的效果链插在 output stage 之前、track 特定效果之后；全局效果挂在**首选 mixPort**（offload > spatializer > deep buffer > primary…）上。
- **关键坑**：打了 `fast` flag 的轨道/fast mixer **不走全局软件效果**（为降低延迟故意省略），offload 轨道同样绕过。这是「部分应用无效果/无效」的底层原因，与 Android 版本无关，但各 ROM 的 mixPort 策略不同放大了它。
- 结论：**session 0 是「弃用但可用」**；14+ 的批量失效不应归因于它。新项目如果走 AIDL 效果库路线，session 0 仍可工作，但要为 fast/offload 轨道做兜底策略。

### 3.3 RootlessJamesDSP：机制与其问题

机制（README 官方确认）：**通过 Android 内部音频捕获（AudioPlaybackCapture）拿到其他应用的音频流 → libjamesdsp 处理 → 自行播放输出**。不依赖系统内置效果。

其问题与根因一一对应：

| 症状 | 根因 |
|---|---|
| 部分应用不支持（Spotify/Chrome/SoundCloud） | 应用主动**阻止内部音频捕获**（DRM），无法绕过，只能改 APK（ReVanced「移除屏幕捕获限制」补丁，但对 AAudio native 播放的应用无效） |
| 双重声音 | 捕获路径与原始输出叠加（应用未被正确静音/或走了 fallback） |
| 切应用无声音 | 捕获会话随媒体会话切换的时序问题 |
| 挂后台死掉 | 前台服务保活问题（Android 14 起前台服务强制声明类型、系统管得更严） |
| 偶发闪退 | MediaProjection/捕获授权链路异常 |
| **Android 15+ 进一步劣化** | 系统新增**屏幕共享隐私防护**，通知内容被隐藏，需手动开「停用屏幕共享防护」开发者选项 |
| 与 Wavelet 等冲突 | 两者都用系统效果/DynamicsProcessing，路径冲突 |
| 延迟增加 | 捕获→处理→回放的额外缓冲，天然缺陷 |

---

## 4. 社区修复方案盘点（证明可行，但全是 hack）

来自酷安 2026-03-22 更新的实测生态（含版本与机制）：

| 方案 | 机制 | 适用 |
|---|---|---|
| **JamesDSP v6.4** | 适配 AIDL 框架，**自带 AIDL 音效库**；免按键版自动识别架构 | Android 14+ 通用（AIDL 设备） |
| **JamesDSP v6.5-RC3-test4** | `service.sh` 新增 `mount_apex()` 扫描 `/apex` 下的 soundfx 并挂载；`patch.sh` 用 **patchelf 动态修补 AIDL 库版本**；调试日志落 `logs/service_debug.txt` | 解决 AIDL 库版本兼容问题（跨版本通用） |
| JamesDSP v5.8 | 旧版 | Magisk ≤ 25.2 的老设备 |
| **PIXAML v0.9-RC3** | Pixel 设备的 **AIDL 桥接层** | Pixel 上 AIDL 版不生效时 |
| **Viper4Android RE (AIDL) v1.2.0** | 自带 AIDL 音效库 `libv4a_aidl.so`；**API<35 拒绝安装**；支持 APEX 挂载 | Android 15+，无需桥接层 |
| Viper4Android RE (HIDL) | HIDL 版 | Android 14 及以下 |
| AML 音频兼容层 | 合并多个音效模块的配置，防互相覆盖 | 多模块共存（不保证效果） |

**推论**：
1. 「AIDL 效果库 + APEX 感知挂载 + 按版本 patch」这条路**已被社区验证可行**——这直接决定了新项目 Android 端的技术路线。
2. 但这些修复都靠运行时 hack（patchelf 二进制补丁、mount 脚本扫 /apex），**版本升级随时再断**。v6.5-RC3 是 test 版、PIXAML 是 RC，维护成本极高、极不稳定。

---

## 5. 取证验证计划（在我们自己的设备上跑一遍）

> 目的：把第 3 节的推断变成实锤。以下命令按 Android 12/13 与 14/15/16 各跑一组，对比差异。

| 步骤 | 命令 | 看什么 |
|---|---|---|
| 1. 确认 HAL 类型 | `adb shell getprop \| grep -i audio`（`audio.hal.*`、`ro.audio.silent` 等）；`adb shell dumpsys media.audio_flinger` | AIDL vs HIDL 的服务形态 |
| 2. 音效配置文件 | `adb shell ls /apex \| grep -i audio`；`adb shell cat /vendor/etc/audio_effects.xml`；`adb shell cat /system/etc/audio_effects.conf` | XML/conf 双轨？APEX 内有无 soundfx |
| 3. 刷 v6.1 复现故障 | `adb logcat -b all \| grep -iE "EffectsFactory\|EffectsConfig\|libjamesdsp\|AudioEffect"` | 捕捉 EffectsFactory 加载失败的具体行（xml 解析失败？库 dlopen 失败？UUID 未注册？） |
| 4. SELinux 取证 | `adb shell dmesg \| grep avc`（或 `logcat -b events`） | 是否有 audioserver 相关 avc denied |
| 5. 效果链现状 | `adb shell dumpsys media.audio_flinger` 的 Effect Chains 段 | 效果挂在哪个 mixPort/session；有无 fast/offload 轨道绕过 |
| 6. 刷 v6.5-RC3 对照 | 同步骤 3 + 看模块自带 `logs/service_debug.txt` | APEX 挂载与 patchelf 补丁是否生效；确定 AIDL 库版本号差异 |
| 7. Rootless 对照 | 开「停用屏幕共享防护」前后对比；`adb shell dumpsys media_projection` | 捕获授权与 15+ 防护的实际影响 |

产出：一份对比表（12/13 vs 14/15/16 的 EffectsFactory 日志 + 配置文件 diff），归档到 `docs/`。

---

## 6. 对新项目 Android 架构的影响与推荐路线

### 路线评估

| 路线 | 做法 | 优点 | 缺点 | 判定 |
|---|---|---|---|---|
| **A. AIDL 效果库（Root）** | 把 DSP 实现为 **AIDL Effects HAL / AIDL 兼容的框架效果库**，按 API Level 编译多版本（34/35/36），APEX 感知挂载，HIDL 兜底（≤13） | 真·系统级全局；社区已验证可行性；无捕获延迟 | 需 Root；维护多版本 AIDL 编译矩阵；每次 Android 升级要跟进 | ✅ **Root 端主路线** |
| B. 播放捕获（Rootless） | AudioPlaybackCapture + 前台服务（mediaPlayback 类型） | 免 Root | 应用可拒绝（DRM）；有延迟；15+ 防护；后台被杀；双声风险 | ⚠️ 仅作降级模式，明确能力边界 |
| C. 私有 API/hidden hook | 反射/隐藏 API 挂 audioserver | — | 14+ hidden API 拦截收紧，随时断 | ❌ 放弃 |

### 落进架构的具体设计要求（更新到架构决策）

1. **效果注册层抽象**：`EffectRegistrar` 接口 → `HidlRegistrar`（≤13，conf/xml 双写）/ `AidlRegistrar`（14+，AIDL 库 + APEX 感知挂载）。版本探测用 `Build.VERSION.SDK_INT` + 实际 HAL 类型探测（不信任 SDK 等级单一判据）。
2. **AIDL 多版本编译矩阵**：libjamesdsp 适配层按 API 34/35/36 分别编译（AIDL 接口有版本差异），构建产物分目录；**16KB page size 对齐**（Android 15+ 设备新要求，旧 NDK 产物可能直接加载失败）。
3. **状态自检（直击「静默失效」痛点）**：App 端周期性验证效果链是否真的在处理（例如读取引擎的旁路/处理计数器），UI 明示「处理中 / 旁路 / 未注册 / fast 轨道绕过」四种状态——EqualizerAPO「表面运行实则未处理」的教训。
4. **mixPort/轨道策略兜底**：检测 fast/offload 轨道绕过（`dumpsys media.audio_flinger` 的思路内置），对绕过的会话给出明确提示，而不是静默无声。
5. **Rootless 模式**：前台服务用 `mediaPlayback` 类型 + 双进程保活 + 捕获会话重连逻辑；明确告知用户能力边界（哪些应用处理不了），不做虚假承诺。
6. **AVC/SELinux 适配清单**：新项目 effect 库的 SELinux 域策略按 14/15/16 分别验证，避免靠「setenforce 0」这类粗暴方案。

### 风险登记

| 风险 | 等级 | 缓解 |
|---|---|---|
| AIDL 接口随 Android 版本持续变动 | 高 | 版本化编译矩阵 + CI 上跑 34/35/36 模拟器回归 |
| 厂商 ROM（HyperOS/ColorOS）私有改动 | 高 | 建立实机兼容矩阵，用户反馈驱动；不做白名单式死适配 |
| 16KB page size 导致旧 so 挂载失败 | 中 | 构建期强制 `-Wl,-z,max-page-size=16384` |
| session 0 未来被移除（弃用多年） | 中 | 架构上保留「设备级效果（Android 11+ deviceEffects）」备选路径 |
| Rootless 在 15+ 持续劣化 | 中 | 定位为降级模式，UI 明示限制 |

---

## 7. 下一步行动

- [ ] **取证验证**（第 5 节）：在 12/13 与 14/15/16 实机上跑对比，产出日志 diff（预计半天）
- [ ] **对照实验**：刷 v6.5-RC3-test4 复盘其 `mount_apex()` + `patchelf` 实现，抄作业转正为正式设计（预计 1 天）
- [ ] **技术验证 spike**：最小 AIDL 效果库（一个 biquad EQ）在 Android 14/15/16 模拟器 + 一台实机上完成注册与生效（预计 3~5 天，决定性节点）
- [ ] Spike 通过后：更新《项目初衷》第 6 章架构图，把 `EffectRegistrar` 纳入 core/ 抽象层
- [ ] 风险同步：Windows 端 APO 路线与签名计划并行启动（M0 另一半）

---

## 附：参考来源

1. AOSP — AIDL Audio HAL（Android 14 起迁移，APM 配置移至 HAL）：source.android.com/docs/core/audio/aidl-implement
2. AOSP — Android 14/15/16 release notes（AIDL 迁移、CAP 14/15 缺失 16 补齐）
3. Android Developers — Android 15 行为变更（offload 音轨失效、音频焦点限制、屏幕共享防护）
4. AOSP — Audio Effects（效果须列于 audio_effects.xml、设备级效果、HAL v6.0）
5. AudioEffect 官方文档（session 0 attach 已弃用；MODIFY_AUDIO_SETTINGS 权限）+ AudioFlinger 源码注释（AUDIO_SESSION_OUTPUT_MIX==0、fast 轨道绕过全局效果）
6. nift4.org《The Android audio stack from a music player's perspective》（效果链 mixPort 优先级、fast/raw 无全局效果）
7. RootlessJamesDSP README（内部音频捕获机制、Spotify DRM 限制、Android 15 屏幕共享防护、ReVanced 补丁）
8. james34602/JamesDSPManager issue #6（`Cannot initialize effect engine ... Error: -3` 报错实锤）
9. XDA JamesDSP [MMT-EX] 帖（Magisk 26 挂载兼容线、"Huawei method"）
10. 酷安音效模块汇总帖 2026-03-22 更新（v6.4 AIDL 适配、v6.5 mount_apex/patchelf、PIXAML、V4A RE AIDL API35 门槛、AML）
