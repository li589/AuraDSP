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
├── dsp/                         # 自研效果，一效果一文件（10 个）
└── host/                        # 插件宿主 TU：auradsp_plugin_host / host_gui /
                                 #   host_metadata_scan / host_instances / host_slots
```

引用链/宿主文件时用 `chain/xxx.cpp`、`host/xxx.cpp` 相对路径；**旧扁平路径（`engine_chain.cpp`
直接躺在 engine/ 根）自 P4b（`cec8064`）起失效**，文档/脚本/CMake 一律按新结构写。

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
   当前链序：gate → deesser → filter → bassmono → basspsycho → Stage 0 Pre-DSP 插件 →
   shelf → dyneq → Stage 1 Pre-Vendor 插件 → vendor 12 级链 → Stage 2 Post-Vendor 插件 →
   haas → exciter → freeverb → Stage 3 Post-Reverb 插件 → loudness → NaN/Inf 清洗 + ±10 钳位 →
   Stage 4 Post-Limiter 插件。
5. `core/desktop/windows/CMakeLists.txt`：源表加文件。
6. `test/smoke/smoke_xxx.py` + `test/runner.py` 登记（未登记 = 废测）。
7. `graph.effects` 注册表加条目 **并同步计数注释**；容量门 2048（payload 近 1KB，
   小 buffer 宁可 E_PARAM 也不断尾残 JSON）。
8. 探针决策：包络动态类（gate/dyneq）**不进**探针（测出来是假数字，haas 前车之鉴）；
   纯 IIR 静态类可进（测得 0 即如实返回 0）。

## 3. 参数 id 与命名

- `domain.name`（如 `dyneq.mid.freq`）；多段用 `low/mid/high` 后缀，勿发明新分隔符。
- vendor 链 12 stage 白名单见 `vendor/libjamesdsp/jamesdsp/jdsp/jdspController.c` 的
  `kAuraStages[]`（P-004 补丁；第 12 级 id 是 `output`，`graph.effects` 注册表中拆为
  `post`+`limiter` 两条展示）；`graph.order` 经 `JamesDSPRebuildChain` 严格校验
  （12 个恰好一次，集合非法返回 -1 且保持原表）。
  engine 自研 stage 顺序钉死在 chain 里，重排页只动展示序（Issue #4）。

## 4. vendor 边界

- `vendor/` 只读；补丁必须 `[PATCHED-AuraDSP P-xxx]` + `vendor/libjamesdsp/PATCHES.md`
  登记；comment 级改动也要登记。升级 = 重提覆盖。
- vendor 黑盒内的效果（如 tube），engine 侧只能开关+调参；要动音色必须走 vendor 补丁
  （P-011 范例），禁止在 engine 侧“包一层假装”。
