# engine/ — 桌面引擎源码约定（C++20，人 + AI 必读）

> 顶层总纲见仓库根 `AGENT.md`。本文件只收 **engine/ 内才成立** 的硬约定。

## 0. 目录分层（P4b 后，2026-10-14）

```
engine/
├── auradsp_engine.{h,cpp,def}   # C ABI 契约 + set/get_param 总入口（根）
├── engine_internal.h            # 私有状态 Params/Handle + 跨文件符号（内部单一入口）
├── auradsp_msvc_shim.h          # MSVC 兼容强制包含层（/FI）
├── chain/                       # 链与 IO：engine_chain / engine_convolver / engine_viz /
│                                #   engine_probe / engine_audiofile
├── dsp/                         # 自研效果，一效果一文件（11 个）
├── platform/                    # 平台端口-适配器（M1，2026-10-29）
│   ├── port/                    #   纯声明 fs.h / env.h / log.h（核心唯一允许的平台抽象）
│   └── windows/                 #   唯一 OS 落点：fs_win / env_win / log_win / win_compat
└── plugins/                     # 插件宿主：api/plugin_host.h + driver/ + formats/ +
                                 #   platform/win32/ + integration/ + tests/
```

引用链/宿主文件时用 `chain/xxx.cpp`、`plugins/{api,driver,formats,platform/win32,integration,tests}/xxx.cpp`
相对路径；**旧扁平路径（`engine_chain.cpp` 直接躺在 engine/ 根）自 P4b（`cec8064`）起失效，
旧 `engine/host/` 自 P1（2026-10-20）起失效**，文档/脚本/CMake 一律按新结构写。

平台约束（M1 起）：根目录 / `chain/` / `dsp/` / `plugins/integration/` 的代码**禁止**出现
OS 头（`windows.h` / `mmdeviceapi.h` 等）与平台符号（`_WIN32` / `_wfopen` / `OutputDebugString` /
`GetEnvironmentVariable` 等）；文件、环境变量、日志一律走 `platform/port/*.h`，实现只加在
`platform/windows/`。门禁：`python test/smoke/smoke_platform_isolation.py`（每次 runner）。

## 1. RT 安全（铁律）

- 音频线程（`process_stereo_chain` 及以下 `*_process`）：**零分配、零锁、零 syscall**。
  系数要么每块现算（bassmono/dyneq 模式，~100 flops 可忽略），要么控制线程重算 +
  原子表（shelf/filter 模式：`std::atomic<double>` 系数 + `*_recalc`）。
- 控制线程（`auradsp_set_param`）可以分配/加锁；RT 只读对齐字（x86 无撕裂）。
- 状态放 handle 结构体 RT 独占区；次正常数截断（`1e-15`/`1e-18`）；NaN/Inf 由链尾
  全局守卫统一处理，单效果不重复设防。

## 2. 新增效果检查表（按序，缺一不可）

1. `engine_internal.h`：`Params` 加字段（含范围注释）+ handle 状态 + 函数声明。
2. `dsp/dsp_xxx.cpp`：一效果一文件；文件头注明位置语义（链 head/pre-vendor/post…）。
3. `auradsp_engine.cpp`：`set_param`（存值+钳位；需即时下发才调 vendor setter）
   + `get_param` 回读。钳位与 dsp 内双保险。
4. `chain/engine_chain.cpp`：`process_stereo_chain` 内按链序调用（注释写清相对位置）。
   当前立体声链序：gate(+deesser) → filter → bassmono → basspsycho → Stage 0 Pre-DSP 插件 →
   shelf → dyneq → Stage 1 Pre-Vendor 插件 → vendor 12 级链 → Stage 2 Post-Vendor 插件 →
   haas → spatial → exciter → Stage 3 Post-Reverb 插件 → loudness → NaN/Inf 清洗 +
   ±10 钳位 → Stage 4 Post-Limiter 插件。
   混响边界（WP1）：立体声/矩阵/双耳路径由 vendor Progenitor2 承担；离散多声道路径在
   exciter 之后、Stage 3 之前调用 MC FDN（`dsp_mc_reverb.cpp`），两套混响不会同时运行。
5. `core/desktop/windows/CMakeLists.txt`：源表加文件。
6. `test/smoke/smoke_xxx.py` + `test/runner.py` 登记（未登记 = 废测）。
7. `graph.effects` 注册表加条目 **并同步计数注释**；容量门 2048（payload 近 1KB，
   小 buffer 宁可 E_PARAM 也不断尾残 JSON）。
8. 可视化槽位：自研 stage 输出电平映射到 `stage_levels_*[13..20]`（gate/dyneq/filter/
   bassmono/haas/exciter/loudness/spatial），GR 计量映射到 `[24..29]`；新增节点必须同步
   `engine/chain/engine_viz.cpp`、`auradsp_engine.h` 注释、Dart `stageMeterIndex` 与
   `smoke_chain_meter.py`。
9. 探针决策：包络动态类（gate/dyneq）**不进**探针（测出来是假数字，haas 前车之鉴）；
   纯 IIR 静态类可进（测得 0 即如实返回 0）。

## 3. 参数 id 与命名

- `domain.name`（如 `dyneq.mid.freq`）；多段用 `low/mid/high` 后缀，勿发明新分隔符。
- legacy 链 12 stage 白名单见 `engine/legacy/jdsp/jdspController.c` 的
  `kAuraStages[]`（P-004 补丁；第 12 级 id 是 `output`，`graph.effects` 注册表中拆为
  `post`+`limiter` 两条展示）；`graph.order` 经 `JamesDSPRebuildChain` 严格校验
  （12 个恰好一次，集合非法返回 -1 且保持原表）。
  engine 自研 stage 顺序钉死在 chain 里，重排页只动展示序（Issue #4）。
  ⚠️ App 侧下发的是**全量** 19 个 id（含 8 个自研 stage），必须先过
  `JamesDSPFilterVendorOrder`（P-013）过滤成 vendor 的 12 个再喂 `RebuildChain`，
  否则任何 App 载荷都必然 -1（2026-10-16 修复）。

## 4. legacy 边界（原 vendor/libjamesdsp，2026-10-16 收编至 engine/legacy/）

- `engine/legacy/` 视同 vendor 只读；补丁必须 `[PATCHED-AuraDSP P-xxx]` +
  `engine/legacy/PATCHES.md` 登记；comment 级改动也要登记。升级 = 重提覆盖。
  当前登记 14 条（P-001~P-014，P-003 保留编号），源码内 38 处标记（以 PATCHES.md 实测为准）。
- legacy 黑盒内的效果（如 tube），engine 侧只能开关+调参；要动音色必须走 legacy 补丁
  （P-011 范例），禁止在 engine 侧“包一层假装”。
- 目录内 include 一律相对/裸名；engine 侧引用 legacy 头必须写 `legacy/jdsp/...`
  （依赖 `${API}` 即 `engine/` 在包含路径上），勿再写裸 `jdsp/...`。
