#!/usr/bin/env python3
"""runner.py — AuraDSP 测试总入口

支持运行：
1. 全量引擎 smoke 测试: python test/runner.py --smoke
2. UI 自动化验证测试: python test/runner.py --ui [test_name]
3. 默认全量验证 (smoke): python test/runner.py
"""

import argparse
import os
import subprocess
import sys

# 子进程继承：GBK 控制台下 smoke/UI 脚本 print 含 '⟹'、替换字符等会
# UnicodeEncodeError 崩溃（2026-10-26 实测 smoke_rt_vendor_flags / smoke_d6_
# patch_ids / smoke_g7_1 / smoke_d4b_swallow / smoke_g7_5 / smoke_abi_consistency
# 均为编码崩溃而非断言失败），固定 UTF-8 输出编码。子进程在启动时读取本变量，
# runner 自身已初始化的 stdout 不受影响。
os.environ["PYTHONIOENCODING"] = "utf-8"

ROOT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TEST_DIR = os.path.join(ROOT_DIR, "test")
SMOKE_DIR = os.path.join(TEST_DIR, "smoke")
UI_DIR = os.path.join(TEST_DIR, "ui")

# M5（2026-10-29）平台标记：'windows' = 依赖 Win32 / 引擎 DLL / 注册表 / COM；
# 'any' = 纯源码扫描，可在任意平台运行。
# S1（2026-11-01）口径翻转：旧口径「未列出默认 windows」会让新加的跨平台
# smoke 在 Linux 上被静默 SKIP 造成假绿。现改为：PLATFORM_WINDOWS 显式列出
# 全部 Windows 专属 smoke（翻转时由旧注册表全量生成，行为与旧口径逐项等价），
# 未列出的 smoke 默认 'any'。新 smoke 若依赖 Windows，必须显式登记到
# PLATFORM_WINDOWS；能在 Linux 跑通的既有 smoke，从 PLATFORM_WINDOWS 摘除即可。
PLATFORM_ANY = {
    "smoke_platform_isolation.py",
    "smoke_dart_platform_quarantine.py",
    # S2（2026-11-01）：Linux 源表闭包门禁，纯文本/源表扫描，任意平台可跑。
    "smoke_linux_source_table.py",
    # S1（2026-11-01）：Linux 引擎信号链功能门禁（产物缺失时自 SKIP）。
    "smoke_linux_engine_process.py",
    # S4 补强（2026-11-01）：同步工具与 CI 骨架门禁，两平台可跑。
    "smoke_sync_artifacts_tool.py",
    "smoke_ci_workflow.py",
}

# PLATFORM_LINUX（2026-11-01，测试补强轮）：与 PLATFORM_WINDOWS 对称的
# 显式标记 —— 只在 Linux 有意义的门禁（ELF 导出集 / PulseAudio 通路 /
# Linux bundle 布局）。runner 按当前平台自动切换：非 Linux 主机上
# 这些条目计 SKIP 而不是误跑或误红。
PLATFORM_LINUX = {
    "smoke_linux_engine_exports.py",
    "smoke_linux_pulse_output.py",
    "smoke_linux_bundle_layout.py",
}

PLATFORM_WINDOWS = {
    "smoke_convolver_spectrum.py",
    "smoke_chain_meter.py",
    "smoke_convolver.py",
    "smoke_guard_flow.py",
    "smoke_liveprog.py",
    "smoke_liveprog_gmem.py",
    "smoke_viz_lowfreq.py",
    "smoke_latency_probe.py",
    "smoke_block1056.py",
    "smoke_plugin_host.py",
    "smoke_plugin_host_process.py",
    "smoke_plugin_host_editor.py",
    "smoke_plugin_izotope_setproc.py",
    "smoke_three_key_plugins.py",
    "smoke_plugin_pdc.py",
    "smoke_plugin_bus.py",
    "smoke_plugin_chain.py",
    "smoke_plugin_chain_stages.py",
    "smoke_plugin_channels.py",
    "smoke_plugin_metadata.py",
    "smoke_plugin_arch_detect.py",
    "smoke_multislot_and_stages.py",
    "smoke_cross_mode_consistency.py",
    "smoke_plugin_prime_no_double_send.py",
    "smoke_plugin_chain_enable.py",
    "smoke_plugin_bypass_lifecycle.py",
    "smoke_vm_plugin_load_fast.py",
    "smoke_plugin_host_priority.py",
    "smoke_plugin_quarantine.py",
    "smoke_config_and_matrix.py",
    "smoke_mc_channel_levels.py",
    "smoke_rt_vendor_flags.py",
    "smoke_dll_dirs.py",
    "smoke_d2_rt_drain.py",
    "smoke_d3_vaio_pump_wait.py",
    "smoke_b1d_comp_startup.py",
    "smoke_d1_latency_sr.py",
    "smoke_d7_asrc_consistency.py",
    "smoke_d5_slot_timeout.py",
    "smoke_d4b_swallow.py",
    "smoke_d6_patch_ids.py",
    "smoke_sr_rate_alignment.py",
    "smoke_eq_response.py",
    "smoke_latency_real_resource.py",
    "smoke_g7_1_viz_mirror.py",
    "smoke_g7_2_bridge_abi.py",
    "smoke_g7_5_bridge_exports.py",
    "smoke_e4_stage16_crossmode.py",
    "smoke_abi_consistency.py",
    "smoke_bridge_unified_abi.py",
    "smoke_release_strings.py",
    "smoke_ir_block_jitter.py",
    "smoke_eq_viz_tap.py",
    "smoke_bassmono.py",
    "smoke_haas.py",
    "smoke_spatial.py",
    "smoke_spatial_binaural.py",
    "smoke_exciter.py",
    "smoke_fx_gain.py",
    "smoke_arbmag.py",
    "smoke_string_readback.py",
    "smoke_gate_deesser.py",
    "smoke_dyneq.py",
    "smoke_mp3.py",
    "smoke_vm_detect.py",
    "smoke_vm_pump.py",
    "smoke_vm_bridge.py",
    "smoke_vm_protect.py",
    "smoke_vm_parallel.py",
    "smoke_apo_inspect.py",
    "smoke_apo_register.py",
    "smoke_apo_selftest.py",
    "smoke_asio_probe.py",
    "smoke_asio_tone.py",
    "smoke_asio_driver.py",
    "smoke_asio_bridge.py",
    "smoke_asio_multichannel.py",
    "smoke_vaio_bridge.py",
    "smoke_crossfeed.py",
    "smoke_basspsycho.py",
    "smoke_filter.py",
    "smoke_loudness.py",
    "smoke_tube.py",
    "smoke_stereo.py",
    "smoke_shelf.py",
    "smoke_input.py",
    "smoke_bass.py",
    "smoke_comp.py",
    "smoke_comp_band_order.py",
    "smoke_comp_race.py",
    "smoke_ddc_race.py",
    "smoke_liveprog_race.py",
    "smoke_limiter.py",
    "smoke_lookahead_limiter.py",
    "smoke_limiter_final_gate.py",
    "smoke_pool_race.py",
    "smoke_dynamic_gr_and_gate.py",
    "smoke_multichannel_discrete.py",
    "smoke_effects_allparams.py",
    "smoke_debug_policy.py",
    "smoke_oversample_aliasing.py",
    "smoke_reverb.py",
    "smoke_wp0_scaffold.py",
    "smoke_reverb_boundary.py",
    "smoke_mc_reverb.py",
    "smoke_reverb_native_params.py",
    "smoke_spatial_fdn_removed.py",
    "smoke_mc_comp_persch.py",
    "smoke_mc_eq_persch.py",
    "smoke_bassmono_pairs.py",
    "smoke_postgain_persch.py",
    "smoke_channel_switch_reset.py",
    "smoke_channel_mask_default_follow.py",
    "smoke_spatial_style_custom.py",
    "smoke_eq_freq_clamp.py",
    "smoke_vb_8x8_budget.py",
    "smoke_silence_gate.py",
    "smoke_graph_order.py",
    "smoke_ddc.py",
    "test_editor_topology.py",
    "probe_component.py",
    "test_cross_system_verify.py",
    "bench_scan_c2.py",
    "bench_load_async_c3.py",
    "test_editor_size_c4.py",
}

if sys.platform.startswith("win"):
    CURRENT_PLATFORM = "windows"
elif sys.platform.startswith("linux"):
    CURRENT_PLATFORM = "linux"
elif sys.platform == "darwin":
    CURRENT_PLATFORM = "macos"
else:
    CURRENT_PLATFORM = "other"


def required_platform(smoke_file):
    if smoke_file in PLATFORM_ANY:
        return "any"
    if smoke_file in PLATFORM_WINDOWS:
        return "windows"
    if smoke_file in PLATFORM_LINUX:
        return "linux"
    return "any"  # S1 翻转后的默认：未登记者按跨平台处理，禁止静默 SKIP


def platform_supported(required):
    return required == "any" or required == CURRENT_PLATFORM


def run_smoke_tests():
    print("========================================")
    print("  Running AuraDSP Engine Smoke Tests   ")
    print("========================================")
    smoke_files = [
        "smoke_convolver_spectrum.py",
        "smoke_chain_meter.py",
        "smoke_convolver.py",
        "smoke_guard_flow.py",
        "smoke_liveprog.py",
        # 2026-10-30：gmem 区从「每 VM 内嵌 64MB」改为按需分配，防止回归
        "smoke_liveprog_gmem.py",
        "smoke_viz_lowfreq.py",
        "smoke_latency_probe.py",
        "smoke_block1056.py",
        "smoke_plugin_host.py",
        "smoke_plugin_host_process.py",
        "smoke_plugin_host_editor.py",
        # iZotope Ozone/RX 12 加载契约：setProcessing 返回 kNotImplemented 不得致命，
        # 且 process() 音频必须存活；机器上无 iZotope 插件时自动 SKIP
        "smoke_plugin_izotope_setproc.py",
        # T-01：三大商业插件（Pro-Q 3 / Ozone 12 / Element FX）load→unload
        # 全链路。默认无 GUI（`--gui` 才开编辑器）；本机未安装目标插件时 SKIP。
        "smoke_three_key_plugins.py",
        "smoke_plugin_pdc.py",
        "smoke_plugin_bus.py",
        "smoke_plugin_chain.py",
        "smoke_plugin_chain_stages.py",
        "smoke_plugin_channels.py",
        "smoke_plugin_metadata.py",
        "smoke_plugin_arch_detect.py",
        "smoke_multislot_and_stages.py",
        # E9 跨模式一致性（进程内 vs 进程外逐位比对）。历史：建门禁时对 HEAD
        # 报红抓出 E12 P0（missStreak 自毁）；E12/E13 修复后转绿，现为常驻
        # 回归守卫（slot 健康 + processCalls 推进 + 对齐逐位一致）。
        "smoke_cross_mode_consistency.py",
        # E14 预热直通双发门禁：直通块不得被宿主回放（prime 补位机制守卫）
        "smoke_plugin_prime_no_double_send.py",
        # 链级启用开关（VB 按路插件处理底层）：关=逐位直通+latency 归零，
        # 重启用=延迟线复位后效果恢复，槽位挂载状态全程保留
        "smoke_plugin_chain_enable.py",
        # F-2 真旁路生命周期门禁：旁路=空链同值（链层跳过槽位）、取消旁路
        # 必须恢复激活处理（泵线程生命周期切换 + 在途 process 握手）
        "smoke_plugin_bypass_lifecycle.py",
        # 桥挂载提速门禁（2026-10-23）：eng[0] 同步 + 其余组后台补齐；
        # 掩码外组不加载、掩码新使能组自动补挂。App 占槽时自动让路。
        "smoke_vm_plugin_load_fast.py",
        # F-4 裁定守卫（2026-10-23）：宿主进程 BELOW_NORMAL 不得外溢到 RT
        # 音频线程（实测音频线程仍 15=TIME_CRITICAL，降级只作用于工作线程）。
        "smoke_plugin_host_priority.py",
        # B3 卸载隔离门禁（2026-10-24）：RT 滞留（假实例 process 阻塞）时卸载
        # 必须按墙钟上界返回并保留实例，不得硬清零后照常销毁（use-after-free）。
        "smoke_plugin_quarantine.py",
        "smoke_config_and_matrix.py",
        # ADR-003 Phase B 多声道电平门禁（2026-10-24）：ABI v2 尺寸/版本 +
        # ch=8/6 逐声道异幅电平 + gate 动态行更新 + vendor/GR 作用域语义 +
        # stereo 回归（MC→stereo 切换无残留泄漏）
        "smoke_mc_channel_levels.py",
        # B4 门禁（2026-10-24）：RT 不得改写 vendor 开关（lost update）。
        # 源码不变式 + 调用级门控接线（comp FL/FR mask）+ 60 轮竞态
        # （MC 处理中翻转 tube.enable，结束后 vendor 开关必须为 0）。
        "smoke_rt_vendor_flags.py",
        # F1 门禁（2026-10-24）：插件 DLL 目录通用化 + AddDllDirectory cookie
        # 引用计数回收。不得识别任何厂商名（源码不变式），卸载必须 RemoveDllDirectory
        # 否则进程搜索路径单调增长 → 后续插件解析同名 DLL 绑到私有副本 → ABI 崩溃。
        "smoke_dll_dirs.py",
        # D2 门禁（2026-10-24）：三桥释放前的 Sleep(50) 猜测改 rtInBlock 确定
        # 性排空（含审查漏点 VmBridge.FreeTestFile）。三层：源码不变式 /
        # guard+排空单测 / ASIO 实测 test_stop 不再是固定 50ms。
        "smoke_d2_rt_drain.py",
        "smoke_d3_vaio_pump_wait.py",
        # B1-d 门禁（2026-10-24）：comp 启动段原声直通。旧实现的抽干循环在
        # 管线首块产出前不执行，输出缓冲里仍是未处理输入（调用方 in==out）；
        # 块长不整除 hop 时还会周期性复发。改为显式启动缺额 D（吐静音）+
        # 抽干不足补静音，延迟 = frames + D 且计入上报。
        "smoke_b1d_comp_startup.py",
        # D1 门禁（2026-10-24）：延迟表口径——结构性帧数不再当毫秒常量。
        # D7（同日）修正其换算基准为工作采样率，具体标定值移入 D7 门禁。
        "smoke_d1_latency_sr.py",
        # D7 门禁（2026-10-24）：ASRC taps 单点定义（64/32 分叉已收）+ 延迟口径
        # 按工作采样率域 + comp 剖面随 tf 变（块长口径后来被 B1-d 推翻并重写，
        # 见下）+ limiter 按 lookahead 模式（默认 0ms）+ ASRC 环形缓冲分量 +
        # 上报值==脉冲实测。
        "smoke_d7_asrc_consistency.py",
        # D5 门禁（2026-10-24）：插件槽异步等待上界 150s → 5s + 墙钟收口 +
        # 超时兜底（同步 unload）+ timedOut 上报。数值与链路任一项回退即红。
        "smoke_d5_slot_timeout.py",
        # D4-b 门禁（2026-10-24）：全仓静默异常。97 处 catch 既不留痕也不绑定
        # 异常，泵循环更是整个迭代体包在 catch (_) {} + continue 里——一次类型
        # 错误就能让可视化永远冻结且日志无痕。四类分治 + 四条规则（R1 空块必留痕
        # /R2 循环包壳必限流/R3 禁匿名 catch/R4 理由不得敷衍），含规则引擎单测、
        # 全仓扫描、接线完整性（part 共享 library import）与两处反向判红。
        "smoke_d4b_swallow.py",
        # D6 门禁（2026-10-24）：补丁编号单点化。77 处 PATCHED 标记里 45 处不带
        # P-NNN，PATCHES.md 号称唯一真相源却九套编号并存（拿代码里的 B5 去查表
        # 查不到；P2.4 全仓只命中一处 PDF）。P-NNN 成为唯一权威标识，专项代号
        # 降级为别名。含两种真实漏网形态（编号写在说明文字里 / 日期在编号前）的
        # 判红断言——它们按行 grep 都看着"有编号"。
        "smoke_d6_patch_ids.py",
        # P-029/P-030 门禁（2026-10-24）：采样率域一致性 + 两个静默失效。
        # 自研 DSP 链在 ASRC 之外却用工作率算系数 → 96k 下 filter -3dB 漂到
        # 2000Hz、192k 漂到 3986Hz（对照组 vendor EQ 三档恒定）；eq.enable=0
        # 关不掉 vendor EQ（上游 Enable 无 else）；多声道 IR（3/5/6/7/8ch）
        # 曾"加载成功但无卷积"，现须显式拒绝。
        "smoke_sr_rate_alignment.py",
        "smoke_eq_response.py",
        "smoke_latency_real_resource.py",
        # §7-1 门禁（2026-10-24）：viz 帧的 Python 镜像单源。改造前
        # tools/ 与 test/ 下各有 8 份彼此独立的手抄 ctypes 定义，ABI v1→v2
        # 时漏改其中几份 → 脚本按旧尺寸申请缓冲、引擎按新尺寸写 → 静默堆
        # 越界（审查 A1/A2/A3 三处其实是同一个 bug 的三个副本）。现在镜像
        # 只在 tools/bin/viz_frame.py 定义一次，M1 抓第二份定义、M2 逐字段比
        # 偏移（只比 sizeof 会放行"字段顺序错但总长凑巧相同"）、M3 管版本联动。
        # 含四级反向判红 + 0xCD 哨兵包裹缓冲的越界活体守卫。
        "smoke_g7_1_viz_mirror.py",
        # §7-2 门禁（T-02 登记）：三桥 abi 与引擎 auradsp_abi 同代际 + gcc
        # 合成假引擎验证 ABI 不匹配拒绝 / 匹配放行。
        "smoke_g7_2_bridge_abi.py",
        # §7-5 门禁（2026-10-24）：三座桥的 .def ↔ 头文件 ↔ Dart 绑定。实测
        # 三桥全漂且方向不同：asio/vaio 各漏导出 slot_{set,get}_channels（Dart
        # 硬 lookup，ASIO/VAIO 后端下插件槽构造即抛 ArgumentError 再被上层吞
        # 掉）、vb 的 auto_protect/protect_test 一直在 .def 里导出而头文件没
        # 声明。含活体层：真相源 DLL 必须真的导出 Dart 硬绑定符号（.def 改了
        # 没重新编译，纯清单门禁照样绿——只有这一层能抓到）。
        "smoke_g7_5_bridge_exports.py",
        # E4 门禁（2026-10-24）：viz Stage 16 采样点跨模式同语义。MC 侧原在
        # basspsycho 之后采样、stereo 在之前——同一 "BassMono" 槽两种模式量的
        # 不是同一链位置，切模式该柱跳变（实测 pre-fix MC 虚高 1.47dB）。判红
        # 原理：采样点在 basspsycho 之前 ⇔ bass 开/关两态 stage16 读数逐位相等；
        # 另附输出 RMS 非空转证明与 stereo 回归守卫。
        "smoke_e4_stage16_crossmode.py",
        "smoke_abi_consistency.py",
        # P5 统一桥契约（2026-10-29）：清单门禁之外，查真相源 DLL 是否真导出
        # 14 个 ab_*、ab_abi_version、capabilities 自报、ab_detect 与旧前缀同源，
        # 以及 VM 运行态 ab_start→status(gated/idleMs)→ab_stop。
        "smoke_bridge_unified_abi.py",
        # B-1 调试串门禁：源码零 cout [DBG + Release DLL 无 [DBG（计划 D1 §3.3）
        "smoke_release_strings.py",
        # M1 平台隔离门禁（2026-10-29）：引擎可移植核心零 OS 头/Win32 符号；
        # 端口头纯声明 + Windows 实现存在 + 扫描器反向自检。
        "smoke_platform_isolation.py",
        # M4 Dart 平台隔离门禁（2026-10-29）：lib/ 业务文件零 Platform.is；
        # PlatformProfile 成员齐全；AudioOut 端口/工厂/WASAPI 实现归位。
        "smoke_dart_platform_quarantine.py",
        # S2 Linux 源表门禁（2026-11-01，ADR-012 §4.3）：Linux 编译闭包不含
        # jamesdsp.c / Win32 源、gcc shim 与 stdint 前置注入在场、.map 同源。
        "smoke_linux_source_table.py",
        # S1 Linux 引擎功能门禁（2026-11-01）：.so 信号链真实跑通（EQ tap
        # 非零，与 verify_dll_copies 同口径）；产物经 engine_artifact 解析，
        # 缺失时自 SKIP。Windows 上该产物不存在 → 自 SKIP 不误红。
        "smoke_linux_engine_process.py",
        # 测试补强轮（2026-11-01）：Linux 三门禁（PLATFORM_LINUX，非 Linux
        # 主机由 runner 自动 SKIP）——.so 导出集 == .def 恒等、PulseAudio
        # 输出通路契约、发布 bundle 布局；外加两条跨平台工具门禁：
        # sync_artifacts 干跑语义、CI 工作流骨架。
        "smoke_linux_engine_exports.py",
        "smoke_linux_pulse_output.py",
        "smoke_linux_bundle_layout.py",
        "smoke_sync_artifacts_tool.py",
        "smoke_ci_workflow.py",
    "smoke_ir_block_jitter.py",
    "smoke_eq_viz_tap.py",
    "smoke_bassmono.py",
    "smoke_haas.py",
    "smoke_spatial.py",
    "smoke_spatial_binaural.py",
    "smoke_exciter.py",
    "smoke_fx_gain.py",
    "smoke_arbmag.py",
    "smoke_string_readback.py",
    "smoke_gate_deesser.py",
    "smoke_dyneq.py",
    "smoke_mp3.py",
        "smoke_vm_detect.py",
        "smoke_vm_pump.py",
        "smoke_vm_bridge.py",
        # Z12 超预算自动保护门禁（2026-10-23）：注入观测值 → 收窄到热组 →
        # 回落自动恢复；手动改掩码立即取消；关保护不进入。App 占槽时让路。
        "smoke_vm_protect.py",
        # Z17 组间并行处理门禁（2026-10-24）：串/并行双路位级对账 + 语义断言
        # + 遥测相等 + 墙钟（8 组 × 250µs 假插件：并行 <60% 串行）。不依赖 VM 在线。
        "smoke_vm_parallel.py",
    "smoke_apo_inspect.py",
    "smoke_apo_register.py",
    "smoke_apo_selftest.py",
    # ASIO 宿主（Phase 1）：枚举对账注册表 + 双驱动发声；无 ASIO 驱动时自动 SKIP
    "smoke_asio_probe.py",
    "smoke_asio_tone.py",
    # ASIO 自研驱动（Driver 线 Phase 1）：COM In-Proc Server 握手 + 能力协商 + MMCSS 双缓冲泵
    "smoke_asio_driver.py",
    # ASIO 常驻桥（Phase 2）：VM 虚拟 ASIO 上 10s，bypass 开/关峰值差 +
    # vizGrp/peak 断言 + slot 被占优雅让路（-3 语义同 05）
    "smoke_asio_bridge.py",
    # ASIO 多声道传输（B2c）：asio_start_ex(Nch) + 引擎 channels.count 对齐 +
    # 6ch 文件注入/bypass + 驱动能力降级；无 in/out>=6 驱动时自动 SKIP
    "smoke_asio_multichannel.py",
    # AuraVAIO 虚拟声卡桥（Mode 1）：探测端点与无驱动防御 / 有驱动回环断言
    "smoke_vaio_bridge.py",
    "smoke_crossfeed.py",
    "smoke_basspsycho.py",
    "smoke_filter.py",
    "smoke_loudness.py",
    "smoke_tube.py",
    "smoke_stereo.py",
    "smoke_shelf.py",
    "smoke_input.py",
    "smoke_bass.py",
    "smoke_comp.py",
    # E-01 门禁：comp 频点交叉/等值/全 20000Hz 时输出有限 + 参数回读不变；
    # 子进程日志层断言 pchip 不再刷 "Abscissas..." 报警。
    "smoke_comp_band_order.py",
    # Z13 compander 控制线程/RT 竞争门禁（2026-10-23）：双 UI 线程高频拖
    # comp.gain*/结构参数 + RT 连续 process。修复前实测访问违例（生产崩溃
    # 同根：FFTCompanderInit 重置 count/指针表与 RT 消耗循环无互斥）。
    "smoke_comp_race.py",
    # Z14 DDC 控制线程/RT 竞争门禁（2026-10-23）：高频 ddc.enable +
    # 交替 ddc.load 两份大 VDC + RT 连续 process。修复前 enable 落入
    # DDCStringParser 解析瞬窗即误拒；修复后控制侧同锁零误拒。
    "smoke_ddc_race.py",
    # B1 liveprog 影子 VM 编译门禁（2026-10-24）：RT 连续 process 逐块
    # 计时 + UI 线程高频加载重脚本（~26ms 编译）/坏脚本/变增益脚本。
    # 修复前（持 jdsp_lock 原地编译）RT 每窗口被挡 ~26ms、总产出仅 ~400
    # 块、最大块 ~50ms；修复后产出 ~74k 块、最大块 <1ms、编译窗口内
    # 每窗口 ~300 块，且停流连发加载经 eelInFlight==0 守卫全部成功。
    "smoke_liveprog_race.py",
    "smoke_limiter.py",
    "smoke_lookahead_limiter.py",
    # ADR-010 门禁（2026-10-31 D-1 裁定）：限幅器是链尾最后一道门——
    # 总输出增益 / 逐声道 trim 必须排在限幅器之前。四条路径（立体声 / 矩阵 /
    # 双耳 / 离散多声道）各跑「限幅开 → 峰值 ≤ 门限」与「限幅关 → 峰值显著
    # 超门限」两组对照，后者是反向验证：post gain 若被挪到限幅器之后，
    # 前者必红而后者仍绿 → 门禁非空转。此前该不变量只写在注释里，无人执行。
    "smoke_limiter_final_gate.py",
    # P-047 逐声道卷积池 / 主卷积 / 拓扑重置的并发门禁（L-01 / L-02 / L-03）：
    # 控制线程高频改 EQ/arbmag 曲线与开关（触发池重载）+ 切 channels.mode/
    # count/spatial（触发 reset_channel_state），RT 线程连续 process。
    # 修复前为单池实现：控制线程 LoadImpulseResponse 释放池内卷积器内存与 RT
    # 的 Process 竞争 ⇒ UAF（访问违例 / 输出被野指针污染）。
    "smoke_pool_race.py",
    "smoke_dynamic_gr_and_gate.py",
    "smoke_multichannel_discrete.py",
    # B 轮补充：全参数扫描（159 有界参数 roundtrip/clamp/NaN/默认回读）+ 多声道掩码
    # （8 按声道效果器 mask=0 不变式 + arbmag/comp/eq 立体声实现语义登记）
    "smoke_effects_allparams.py",
    # 调试体系门禁（2026-11-01）：禁止业务代码直接 print/debugPrint；
    # DebugTrace/HUD/命令行启动器必须存在，控件动作与引擎回执统一进 JSONL。
    "smoke_debug_policy.py",
    "smoke_oversample_aliasing.py",
    "smoke_reverb.py",
    # WP0 脚手架（多声道重构与混响边界 2026-10-25）：新参数默认/往返/越界拒绝、
    # reverb.engine 只读与路径映射、stereo 逐位不变。后续 WP 的 smoke 骨架
    # 一并登记（当前打印 SKIP 退出 0，实现后转真断言）。
    "smoke_wp0_scaffold.py",
    "smoke_reverb_boundary.py",
    "smoke_mc_reverb.py",
    "smoke_reverb_native_params.py",
    "smoke_spatial_fdn_removed.py",
    "smoke_mc_comp_persch.py",
    "smoke_mc_eq_persch.py",
    "smoke_bassmono_pairs.py",
    "smoke_postgain_persch.py",
    "smoke_channel_switch_reset.py",
    # X-6 修复（2026-10-26）：dyneq/exciter no-LFE 默认掩码随 channels.count
    # 按布局平移（4ch 0x0F / 6ch 0x37）+ 自定义掩码保留 + 4ch BR 音频级断言。
    "smoke_channel_mask_default_follow.py",
    "smoke_spatial_style_custom.py",
    "smoke_eq_freq_clamp.py",
    "smoke_vb_8x8_budget.py",
    # P2/P3 静音门控（2026-10-29）：引擎 gated 快路径（hold 2s + 残量
    # -120dB 双条件、同块退出、viz 照常发射、开效果器后 gated 耗时
    # <25%）+ 桥层状态机单测（silence_gate_test.exe，三桥共用头）。
    "smoke_silence_gate.py",
    "smoke_graph_order.py",
    "smoke_ddc.py",
        "test_editor_topology.py",
        "probe_component.py",
        "test_cross_system_verify.py",
        # C2：扫描基准（无插件环境自动 SKIP，故可值守）
        "bench_scan_c2.py",
        # C3：异步挂载/卸载（无插件环境自动 SKIP，故可值守）
        "bench_load_async_c3.py",
        # C4：编辑器容器与子窗口尺寸一致 + 拉伸跟随（无插件环境自动 SKIP）
        "test_editor_size_c4.py",
    ]
    all_pass = True
    passed = skipped = failed = 0
    skipped_files = []
    for sf in smoke_files:
        path = os.path.join(SMOKE_DIR, sf)
        if not os.path.exists(path):
            print(f"[WARN] File not found: {sf}")
            continue
        req = required_platform(sf)
        if not platform_supported(req):
            print(f"[SKIP] {sf} (requires {req}, current {CURRENT_PLATFORM})")
            skipped += 1
            skipped_files.append(sf)
            continue
        print(f"\n---> Running {sf}...")
        res = subprocess.run([sys.executable, path], cwd=ROOT_DIR, check=False)
        if res.returncode != 0:
            print(f"[FAIL] {sf} returned code {res.returncode}")
            failed += 1
            all_pass = False
        else:
            print(f"[PASS] {sf}")
            passed += 1
    print("\n========================================")
    if all_pass:
        print("  ALL SMOKE TESTS PASSED [100%]        ")
    else:
        print("  SOME SMOKE TESTS FAILED!             ")
    print(f"  PASS {passed} | SKIP {skipped} | FAIL {failed}   ")
    if skipped_files:
        print("  SKIPPED: " + ", ".join(skipped_files))
    print("========================================")
    return 0 if all_pass else 1


def run_ui_tests(target=None):
    print("========================================")
    print("  Running AuraDSP UI Automation Tests  ")
    print("========================================")
    # target 先解析校验：非 Windows 整体跳过时也不吞掉拼写错误。
    target_path = None
    if target:
        target_path = os.path.join(UI_DIR, target if target.endswith(".py") else f"{target}.py")
        if not os.path.exists(target_path):
            print(f"[ERROR] UI test not found: {target_path}")
            return 1
    # M5：UI 自动化全部依赖 Windows 窗口栈与 ui_test_kit，非 Windows 统一跳过。
    if not platform_supported("windows"):
        print(f"  ALL UI TESTS SKIPPED (requires windows, current {CURRENT_PLATFORM})")
        print("========================================")
        return 0
    if target_path:
        targets = [target_path]
    else:
        targets = [
            os.path.join(UI_DIR, "ui_verify_slider_reset.py"),
            os.path.join(UI_DIR, "ui_verify_chain_meter.py"),
            os.path.join(UI_DIR, "ui_verify_effects_3d.py"),
            os.path.join(UI_DIR, "ui_verify_preset_and_memory.py"),
            os.path.join(UI_DIR, "ui_verify_plugins.py"),
            os.path.join(UI_DIR, "ui_verify_vst_and_eel.py"),
            os.path.join(UI_DIR, "ui_verify_advanced_sections.py"),
        ]
    all_pass = True
    for tp in targets:
        name = os.path.basename(tp)
        # 每个用例前统一保证 APP 在运行。各测试文件对生命周期的管理并不一致：
        # 有的用 AuraAppSession（__enter__ 杀+重启、__exit__ 关闭），
        # 有的用裸 Win32 并在收尾自行 kill，而 ui_verify_effects_3d 这类
        # 只做 find_auradsp()、**要求 APP 已在运行**，否则直接 FATAL。
        # 于是「前一个用例收尾把 APP 杀掉」会让后一个用例莫名失败。
        if sys.path and UI_DIR not in sys.path:
            sys.path.insert(0, UI_DIR)
        try:
            import ui_test_kit
            if ui_test_kit.ensure_running() is None:
                print(f"[FAIL] {name} 无法启动 APP，前置条件不满足")
                all_pass = False
                continue
        except Exception as e:  # noqa: BLE001
            print(f"[FAIL] {name} 前置检查异常: {e}")
            all_pass = False
            continue
        print(f"\n---> Running UI verification: {name} (Top-most & Activated)...")
        res = subprocess.run([sys.executable, tp], cwd=ROOT_DIR, check=False)
        if res.returncode != 0:
            print(f"[FAIL] {name} failed with code {res.returncode}")
            all_pass = False
        else:
            print(f"[PASS] {name}")
    return 0 if all_pass else 1


def main():
    parser = argparse.ArgumentParser(description="AuraDSP Test Runner")
    parser.add_argument("--smoke", action="store_true", help="Run C++ engine smoke tests")
    parser.add_argument("--ui", nargs="?", const="all", help="Run UI automation tests (or specify test name)")
    args = parser.parse_args()

    if args.ui:
        target = None if args.ui == "all" else args.ui
        return run_ui_tests(target)
    else:
        return run_smoke_tests()


if __name__ == "__main__":
    sys.exit(main())
