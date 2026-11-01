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

  /// 运行 apo_inspect.exe 获取端点 JSON。
  Future<ProcessResult> inspectAudioDevices(String exePath);

  /// 安装/卸载 AuraVAIO 驱动脚本。
  Future<ProcessResult> vaioDriver(
    String scriptPath, {
    required bool install,
    required bool elevated,
  });

  /// 注册/反注册 Virtual ASIO 驱动脚本。
  Future<ProcessResult> asioDriverScript(
    String scriptPath, {
    required bool register,
    required bool elevated,
  });

  /// apo_config.py status（非提权）。
  Future<ProcessResult> apoStatus(String scriptPath, double timeout);

  /// apo_config.py install（可选 UAC 提权 / 复合插槽）。
  Future<ProcessResult> apoInstall(
    String scriptPath, {
    required String target,
    required bool composite,
    required bool elevated,
  });

  /// apo_config.py uninstall（可选 UAC 提权）。
  Future<ProcessResult> apoUninstall(
    String scriptPath, {
    required String target,
    required bool elevated,
  });
}
