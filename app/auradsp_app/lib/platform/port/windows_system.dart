// windows_system.dart — Windows 系统工具端口（驱动 / APO / 端点探测）。
//
// 方案：docs/10-架构/APP-目录重组与平台适配层方案-2026-11-01.md §1/§4。
// 实现内部包含 powershell / python / apo_inspect.exe 的进程调用与脚本路径探测；
// 业务层（core/state）只消费语义化方法，不再拼命令、不再找脚本。
import 'dart:io';

abstract interface class WindowsSystemPort {
  /// 当前平台是否具备这套 Windows 系统工具。
  bool get available;

  /// 从当前工作目录向上最多 4 层查找仓库内的文件（相对候选路径）。
  String? findRepoFile(List<String> relativeCandidates);

  /// 以可执行文件所在目录为基准查找随包文件（安装版扁平布局）。
  /// 候选为相对可执行文件目录的路径（如 `driver/install_vaio.ps1`）；
  /// 不依赖当前工作目录——安装版定位必须走这一路，源码树查找只作
  /// 开发期兜底（findRepoFile）。
  String? findInstalledFile(List<String> relativeCandidates);

  /// 运行 apo_inspect.exe 获取端点 JSON。
  Future<ProcessResult> inspectAudioDevices(String exePath);

  /// 安装/卸载 AuraVAIO 驱动脚本。
  /// [bundled] = 随包自包含脚本（install_vaio.ps1，无 -Config 参数）；
  /// false = 源码树开发脚本（install_driver.ps1，带 -Config Release）。
  Future<ProcessResult> vaioDriver(
    String scriptPath, {
    required bool install,
    required bool elevated,
    bool bundled = false,
  });

  /// 注册/反注册 Virtual ASIO 驱动脚本。
  /// [bundled] = 随包脚本（register_asio.ps1：无参注册 / -Unregister
  /// 反注册）；false = 源码树开发脚本（register_driver.ps1，-Action 口径）。
  Future<ProcessResult> asioDriverScript(
    String scriptPath, {
    required bool register,
    required bool elevated,
    bool bundled = false,
  });

  /// apo_config.exe status（非提权；原生工具，2026-11-09 §2.3）。
  Future<ProcessResult> apoStatus(String exePath, double timeout);

  /// apo_config.exe install（可选 UAC 提权 / 复合插槽）。
  Future<ProcessResult> apoInstall(
    String exePath, {
    required String target,
    required bool composite,
    required bool elevated,
  });

  /// apo_config.exe uninstall（可选 UAC 提权）。
  Future<ProcessResult> apoUninstall(
    String exePath, {
    required String target,
    required bool elevated,
  });
}
