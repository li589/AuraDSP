# JamesDSP Effect Registrar (core/android/registrar)

Android 14+ AIDL 效果库正式核心，从 Spike2 验证骨架收敛而来（见
`docs/Spike2-AIDL效果库验证报告.md`）。

## 架构

```
┌──────────────────────────────────────────────┐
│ 效果库（如 libjamesdsp.so）                    │
│                                              │
│  main.cpp ──► RegistrarEntry（3 个 extern "C"）│
│                  │                           │
│  AidlEffectBase  ◄── IAudioEngine（你的 DSP） │
│  · 状态机 INIT/IDLE/PROCESSING/DRAINING      │
│  · FMQ 数据面（status/in/out）+ EventFlag    │
│  · 工作线程（kEventFlagDataMqNotEmpty 驱动）  │
│  · common 参数（session/mode/volume）往返     │
└──────────────────────────────────────────────┘
         ▲ dlopen+dlsym
┌────────┴─────────────────────────────────────┐
│ effects HAL（AHAL_EffectFactoryQti）          │
└──────────────────────────────────────────────┘
```

## 接入一个新效果只需三步

1. 实现 `registrar::IAudioEngine`（open/process/reset/close，实时安全）；
2. 写 `main.cpp`：构造 `RegistrarEntry`（impl uuid、type uuid、名称、引擎工厂）；
3. 三个 extern "C" 导出委托给 `RegistrarEntry`。

## 构建

```bash
cd core/android/registrar
bash build.sh        # 产出 out/libspikeeq.so（复用 ../spike-global-effect 的
                     # gen/、aidl-src/、third-party/ 基础设施）
```

部署验证：把 `out/libspikeeq.so` 复制到 `../spike-global-effect/out/` 后执行
`bash ../spike-global-effect/deploy/deploy.sh`，再用 `attach-test/MiniAttach.dex` 挂载验证。

## 已验证行为（Android 16 / Ace 6T，Enforcing）

- HAL 枚举（nonProxyEffects 9→10）、AudioFlinger 列出效果
- createEffect → setParameter → open（FMQ 建立）→ command(START/STOP/RESET)
- 引擎插拔点正常工作（SpikeEqEngine 日志独立于 Registrar 日志）
- release → destroyEffect 干净返回
- FMQ 共享内存三级回退：memfd → /dev/ashmem → /data/vendor/audio 文件
  （Oplus 收紧 SELinux 后 file-backed 为实际生效路径）

## 已知平台限制

- QTI HAL `queryProcessing` 原生失败 → xml `<postprocess>` 自动挂链不可用，
  必须由 app/宿主显式 attach。
- 正式部署（KSU 模块）需固化 sepolicy 规则或依赖 file-backed 分配器。

## 迁移待办

- `../spike-global-effect/gen`、`aidl-src/`、`third-party/` 将迁入
  `core/android/`（aidl-gen / third-party）成为统一基础设施。
- libjamesdsp 引擎接入：实现 IAudioEngine，替换 SpikeEqEngine。
