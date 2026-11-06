/// 驱动签名风险口径与随包手动安装入口（引擎层与 UI 层共用常量）。
///
/// 事实依据（微软 Learn，2026-11-06 核对）：
/// - 64 位 Windows 自 Vista 起执行内核模式代码签名策略，默认不加载
///   测试签名驱动；Win7/8.1/10/11 **均受影响**，只有 32 位系统基本不强制。
/// - 持久方案 `bcdedit /set testsigning on` + 重启；Secure Boot 开启时
///   需在 BIOS 关闭；启用后桌面右下角有「测试模式」水印。
/// - 一次性方案：高级启动 → 启动设置 → 按 7/F7「禁用驱动程序签名强制」，
///   **下次重启即失效**。
/// - Windows 11 额外门槛：内存完整性（HVCI/VBS）与较新版本对 bcdedit
///   的写入限制；Win10 1507 起 HVCI 要求二进制带测试证书签名（本包满足）。
/// - AuraASIO 是用户态 COM DLL，走 DllRegisterServer，**不受内核签名限制**。
library;

/// 随包脚本在「需要测试签名模式」时返回的专用退出码。
const int kDriverSigningRequired = 3;

const String kDriverReadmeRel = r'driver\README.txt';
const String kDriverManualDirRel = 'driver';

/// 引擎层警告文案（Finish 页 warnings；UI 详细文案见 arb 三语）。
const String kDriverSigningNotice = 'AuraVAIO 是测试签名驱动：64 位 Windows'
    '（含 Win7/8.1/10/11）默认拒绝加载，不是只有 Win11 需要处理。'
    '请按 安装目录\\driver\\README.txt 开启测试签名模式（或临时禁用驱动签名强制）后，'
    '再以管理员身份运行 driver\\install_vaio.ps1 -Action install。'
    'AuraASIO 为用户态组件，不受此限制。';

const String kDriverSigningShort = 'VAIO 驱动为测试签名，需先开启测试签名模式'
    '（详见 安装目录\\driver\\README.txt）；否则驱动无法加载，应用本体不受影响。';
