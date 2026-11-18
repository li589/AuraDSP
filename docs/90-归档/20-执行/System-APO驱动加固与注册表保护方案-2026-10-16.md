# System APO 驱动加固与注册表安全保护方案

> 日期：2026-10-16  
> 状态：✅ 已落地并完成实测验证（已闭环解决 GitHub Issue [#5](https://github.com/li589/AuraDSP/issues/5)）  
> 关联 Issue：[#5 [engine] APO E2E: audiodg 不载入 AuraApo（Win11 24H2 静默拒载）](https://github.com/li589/AuraDSP/issues/5)  
> 关联代码：
> - 核心驱动：`core/desktop/windows-drivers/03_system_apo/` (`AuraApo.h`, `AuraApo.cpp`, `ApoClassFactory.cpp`, `AuraApoMain.cpp`)
> - 注册表与服务管理：`core/desktop/windows-drivers/03_system_apo/apo_config.py`
> - Flutter 状态与 UI：`app/auradsp_app/lib/core/state.dart`, `app/auradsp_app/lib/features/settings_page.dart`
> - 自动化测试：`test/smoke/smoke_apo_selftest.py`, `smoke_apo_register.py`, `smoke_apo_inspect.py`

---

## 1. 方案背景与参考项目设计提炼

Windows System Audio Processing Object (System APO) 运行在由系统服务托管的受保护进程 `audiodg.exe` 内部。在实现系统全局音频处理时，必须严格解决三大硬核挑战：
1. **进程隔离与 COM 聚合陷阱**：`audiodg.exe` 会以 COM Aggregation 方式聚合 APO 对象，传入非空 `outer_unknown`；若驱动未实现合规的 COM 聚合支持，系统将静默丢弃 APO 并在 `IAudioClient::Initialize` 时返回 `E_NOTIMPL`。
2. **注册表原子保护与 100% 可逆性**：挂载端点涉及修改 `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render\{guid}\FxProperties`。若不妥善备份原始厂商配置（如 Realtek、Dolby Atmos、DTS、Intel 等），可能破坏用户的系统音效。
3. **LPAC (Less Privileged AppContainer) 权限隔离**：`audiodg.exe` 运行在 LPAC 沙箱环境下，无法随意读写常规共享内存；若权限配置不当，心跳检测和跨进程通信将静默失败。

本项目充分吸收了 `source/` 下四大关键参考项目的工程设计：

| 参考项目 | 核心设计提炼与 AuraDSP 落地 |
|---|---|
| **EqualizerAPO** | ① **Child APOs 注册表隔离机制** (`HKLM\SOFTWARE\AuraDSP\Child APOs\{guid}`)，在专属键下保存所有被修改槽位；<br>② **`!KEY` / `!VALUE` 哨兵语义**：精确记录原有键值是否存在，卸载时精准删除注入键，绝不残留多余键值；<br>③ **双层备份**：除注册表快照外，操作前自动导出磁盘 `.reg` 与 `.json` 快照至 `out/apo-backups/`。 |
| **virtual-surround-sound** | ① **真 COM 聚合（Nested Inner Class）**：直接实现 `class Inner : public IUnknown`，避免 reinterpret_cast 导致的 vtable 错位崩溃；<br>② **`PKEY_FX_Association` 与槽位规则**：设置 `,0` 为全零 GUID，同步填充 SFX (`,5`), MFX (`,6`), EFX (`,7`) 保证流挂接；<br>③ **复合插槽模式 (Composite Multi-SZ)**：支持 Win10 1803+ `,13` / `,14` MULTI_SZ 列表追加，与厂商 OEM APO 和谐共存；<br>④ **LPAC 权限穿透**：为共享内存显式添加 `S-1-15-2-1` 与 `S-1-15-2-2` ACE；<br>⑤ **服务重启同步**：先停 `Audiosrv` 再停 `AudioEndpointBuilder`，随后逆序启动，彻底清空端点属性缓存。 |
| **ViPER4Windows** | ① **原子双向心跳检测**：通过 `Global\AuraAPO_Heartbeat` 共享内存，实时检测 `audiodg.exe` 内 APO 的活跃处理序列号与帧数推进；<br>② **RT-Safe 零锁零分配**：在 `APOProcess` 实时线程中绝不调用 malloc/free/I/O 或获取内核锁。 |
| **tympan-apo** | ① **完整 COM 接口规范实现**：直接实现 `IAudioProcessingObject`, `IAudioProcessingObjectRT`, `IAudioProcessingObjectConfiguration`, `IAudioSystemEffects`；<br>② **严格音频格式协商**：实现 `CheckFormat` 与 `IsInputFormatSupported`，保障 IEEE 32-bit Float 与环绕多声道流的可靠协商。 |

---

## 2. 核心技术架构实现

### 2.1 Clean-Room COM 聚合架构 (`AuraApo.h` / `AuraApo.cpp`)

严格遵照 Windows 驱动开发手册与 COM 规范，使用嵌套内部类实现聚合：

```cpp
class AuraApo final : public IAudioProcessingObject,
                       public IAudioProcessingObjectRT,
                       public IAudioProcessingObjectConfiguration,
                       public IAudioSystemEffects {
private:
    class Inner final : public IUnknown {
    public:
        explicit Inner(AuraApo* outer) : outer_(outer) {}
        STDMETHODIMP QueryInterface(REFIID riid, void** ppv) override;
        STDMETHODIMP_(ULONG) AddRef() override;
        STDMETHODIMP_(ULONG) Release() override;
    private:
        AuraApo* outer_{nullptr};
    };

    Inner inner_;
    IUnknown* outer_unknown_{nullptr};
    std::atomic<ULONG> ref_count_{1};
```

- 当 `IClassFactory::CreateInstance` 收到 `outer_unknown != nullptr` 时，返回 `&inner_`；
- `AuraApo` 自身接口调用委托给 `outer_unknown_`，实现 100% 合规的 COM Aggregation。

### 2.2 LPAC AppContainer 权限穿透与心跳共享内存

在创建 `Global\AuraAPO_Heartbeat` 共享内存时，构造包含 Lowbox / LPAC SIDs 的安全描述符 (SDDL)：

```cpp
// D:(A;;GA;;;WD)(A;;GA;;;AC)(A;;GA;;;S-1-15-2-1)(A;;GA;;;S-1-15-2-2)
// 允许 World (WD), All AppPackages (AC), 以及 LPAC 沙箱进程读写
```

心跳结构体（32 字节紧凑对齐）：
```cpp
struct AuraHeartbeat {
    uint32_t magic;       // 'AUBH' (0x41554248)
    uint32_t version;     // 1
    uint32_t seq;         // 递增帧序号
    uint32_t sampleRate;  // 运行采样率 (例如 48000)
    uint64_t framesTotal; // 累计处理音频帧数
    uint32_t lastNbs;     // 最近一批次样本数
    uint32_t processId;   // 当前运行进程 PID (audiodg.exe)
};
```

### 2.3 双层注册表原子保护与可逆还原 (`apo_config.py`)

1. **第一层：注册表内部 Child APOs 归档**
   - 路径：`HKLM\SOFTWARE\AuraDSP\Child APOs\{guid}`
   - 存储：端点元数据、方向、`HadFxPropertiesKey`，以及被修改前的所有槽位值。
   - 若原槽位不存在，标记为 `!VALUE`；若原端点无 `FxProperties` 键，标记为 `!KEY`。
2. **第二层：物理磁盘快照导出**
   - 路径：`core/desktop/windows-drivers/out/apo-backups/`
   - 文件：`fx_{short}_{timestamp}.reg`（系统原生 reg export）与 `fx_{short}_{timestamp}.json`（JSON 元数据字典）。
3. **复合槽模式 (Composite Multi-SZ)**
   - 在 Windows 10 1803+ 上，使用 `--mode composite` 将 CLSID 追加到 `PKEY_CompositeFX_SFX` (`,13`) 和 `MFX` (`,14`) 的 `MULTI_SZ` 列表中，卸载时仅剔除 AuraAPO CLSID，彻底保留原有 Dolby/Realtek 增强。
4. **服务重启保障**
   - 自动按安全序次执行：`sc stop Audiosrv` -> `sc stop AudioEndpointBuilder` -> `sc start AudioEndpointBuilder` -> `sc start Audiosrv`，确保内核与系统音频引擎刷新端点缓存。

---

## 3. 实机验证记录

### 3.1 对象级自测试 (`apo_selftest.exe`)
- 运行：`python test/smoke/smoke_apo_selftest.py`
- 结果：**20/20 全部 PASS**。
  - `CreateInstance`（单体与聚合两种模式）PASS
  - `QueryInterface`（5 个接口，包含 `IID_IAudioProcessingObjectRT` 等）PASS
  - `Initialize` & `CheckFormat`（格式协商、非空校验、静音与有效缓冲处理）PASS
  - `LockForProcess` / `APOProcess` / `UnlockForProcess` PASS
  - `Heartbeat` 共享内存创建与推进 PASS

### 3.2 动态真实 `audiodg.exe` 注入与心跳推进验证
- 测试环境：Windows 11，测试端点 `Voicemeeter In 5`。
- 注入与测试音频流回放：
  ```text
  >>> APO IS ALIVE AND PROCESSING IN AUDIODG! <<<
  alive: True, seq: 100, sr: 48000, frames: 48000, pid: 14784 (audiodg.exe)
  ```
- 确认：`audiodg.exe` 加载 `AuraApo.dll` 无崩溃，音频实时透传并实时更新心跳数据。

---

## 4. Flutter 前端交互集成

在 `app/auradsp_app` 中全面打通底层驱动与用户界面：

1. **状态驱动 (`lib/core/state.dart`)**：
   - 暴露 `apoAttached`, `apoHeartbeatAlive`, `apoHeartbeatSr`, `apoHeartbeatFrames`, `apoCompositeMode`, `isApoOperating`, `lastApoError`。
   - `checkApoStatus()`：非阻塞轮询 `apo_config.py status --json`，实时提取已挂载端点列表与心跳状态。
   - `attachSystemApo()` / `detachSystemApo()`：通过 PowerShell `Start-Process -Verb RunAs` 唤起 Windows UAC 原生管理员提权弹窗，执行操作并自动刷新状态。
2. **设置页面板 (`lib/features/settings_page.dart` -> `_SystemApoPanel`)**：
   - **端点下拉选择器**：支持系统物理与虚拟端点选择。
   - **实时心跳徽章**：
     - 绿色脉冲：`活跃处理中 (48000Hz · 48000 帧)`
     - 橙色待机：`已挂接 (等待播放流触发)`
     - 灰色未挂载：`未附加`
   - **复合插槽切换按钮**：一键切换是否保留现有 OEM 音效共存。
   - **操作反馈**：内联错误提示卡片与详细 SnackBar 通知，带防重入加载中锁定。
   - **安全背书说明**：底部标注注册表双层保护承诺。
3. **编译与自动化测试**：
   - `flutter analyze`：0 issues。
   - `flutter test`：232 个单元与集成测试全量 PASS。
