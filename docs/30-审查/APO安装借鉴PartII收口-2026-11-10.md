# APO 安装借鉴 Part II 收口（2026-11-10）

依据：《APO 插件托管与安装借鉴及文件类中转计划书-2026-11-10》（`docs/10-架构/`）Part II——向 EqualizerAPO 借鉴其安装/运维口径中归 `apo_config` 的四项（跨模式清理、状态反推与推荐档、前后混独立开关、doctor 自检自修、书签版本化；子 APO 链明确不借）。排期为计划书三部分之首（Part I 插件托管、Part III 文件中转在本收口之后）。

三阶全部落于 `feature/linux`，纯逻辑下沉至 `apo_install_plan.h`（STL-only，可在 Linux 以 g++ 直接编译 `apo_plan_test.cpp` 验证），最终累计头 `d9f73d4b` 的 CI run 42775380640 **九作业全绿**（J5b 含 plan 矩阵与 doctor 契约冒烟两步）。

## W1 跨模式清理 + 前后混独立开关（`bf516d9f`）

- install 时先清理其他模式的槽位：外来槽位按首快照恢复原值；快照条目缺失时降级为仅剥离我方 CLSID；删除失败忽略、写回失败如实计入 `fxOk`。
- `--only pre|post`：流侧（LFX/SFX/CompSFX）与设备侧（GFX/MFX/EFX/CompMFX）独立安装；ProcModes 只写实际安装的位置；`sfx-only` + post 为非法组合（`invalid_only`）。采集端点默认 pre-only，结果 JSON 增 `only` 与 `capture_pre_only`。
- 纯逻辑矩阵 35 项检查钉死：全模式写集与 W1 之前逐字一致（清理是增量行为，不改变本模式落点）。
- App 面板未接 `--only`（无 UI 需求；跨模式清理对面板的模式切换自动生效）。

## W2 状态反推 + 推荐档 + 书签版本化（`d2533b93`）

- `status` 改为活扫全部端点：逐端点反推 `inferred_mode`（win7-sapo / sfx-efx / composite / sfx-only / partial / none；其中 {SFX} 单槽与 sfx-efx 的 `--only pre` 不可区分，按 sfx-only 标注并在文档注明）、我方 pre/post 在位、跨代原厂 APO（pre 取 SFX>LFX>compSFX，post 取 EFX>MFX>GFX>compEFX>compMFX）。
- `recommended_mode`：OS < Win8.1 → win7-sapo；外来复合槽占用 → composite；外来 SFX 代占用 → sfx-efx；仅旧代占用 → win7-sapo；空端点 → sfx-efx。JSON 增补 `endpoints` 数组（附加式，App 既有解析不受影响），文本报告增反推段。
- OS 版本改读注册表 `CurrentBuildNumber`（GetVersionEx 在无清单的 Win10 上谎报 6.2）。
- 书签版本化：新快照写注册表 Version `"2"` + 磁盘 JSON `"schema": 2`；还原时高于 2 的版本拒绝执行，磁盘侧过新文件跳过、回退到更旧的兼容快照；1 / 缺失视为兼容。`apo_plan_test` 增至 57 项全过。

## W3 doctor 自检自修（`c974aec8`，修复 `a851304b` / `d9f73d4b`）

- 新动词 `apo_config doctor [--fix]`，六项只读检查：`testenv`、`com_registration`（注册项齐全且注册路径 DLL 真实存在）、`apo_dll`、`engine_dll`（apo 变体优先）、`fx_writable`（已挂载端点 FxProperties 可写探针）、`snapshot_versions`（与 W2 守卫同口径）。
- `--fix`（需管理员）：testenv 直写、注册走 regsvr32 重注册 + EnsureComRegistered、fx_writable 走接管退路（启用 SeTakeOwnershipPrivilege → 所有权归 Administrators → DACL 授 Administrators/SYSTEM 完全控制 → 复探裁定）；snapshot_versions 只报告不自动修。裁定走既有通道（JSON + `--result-file` 名单增 doctor），退出码 0 = 全过。
- 门禁 `smoke_apo_doctor` 为契约冒烟：只验 JSON 结构与六项齐名——检查结论随机器环境变（CI 裸机必然有 FAIL 项），不作门禁对象。
- 两轮 CI 定罪记录（均为新面首次进 CI 的存量/环境问题，已逐层修净）：① `SE_TAKE_OWNERSHIP_NAME` 在 winnt.h 为窄字符串常量，与宽形参不合（C2664）→ 直传宽字面量；② 冒烟包装以 `text=True` 按控制台 cp1252 解码 doctor 的 UTF-8 中文 JSON，解码线程自爆 → 改字节捕获 + 显式 UTF-8 解码（同门族其他包装输出为纯 ASCII 标签，未受影响）。

## 保持项

我方既有优势不动：复合槽（,13/,14/,15）、首快照保全、全量还原（DisableEnhancements / ProcModes / FxTitle 均还原）——三者均为 EAPO 所缺。W1 的跨模式清理以首快照为据，不回退以上口径。

## 真机验收（用户侧）

1. 面板附加 APO 后跑 `apo_config status --json`：看逐端点 `inferred_mode` 与 `recommended_mode` 是否与实际相符。
2. `apo_config doctor` 只读跑一次：六项结论应与机器实况相符（已装机预期全 OK 或仅 testenv 类可解释项）。
3. 若有 FAIL 项，管理员跑 `apo_config doctor --fix` 后复跑 doctor，应转全 OK（尤其 fx_writable 的接管退路）。
4. 跨模式切换回归：装 sfx-efx 后改装 composite（或反之），原厂 APO 应恢复在位、我方槽位无残留。

## 后续

Part I（APO 插件托管 + 全平台通用逐槽 SEH 闩锁 + ModeCaps）待用户发话后以 Q0 设计附记先行；Part III（IR/VDC 文件中转）骨架已在计划书锁定，排期实施。
