// plugin_dirs_mobile.dart — Android/iOS 插件扫描目录（暂不支持）。
import '../port/plugin_dirs.dart';

final class MobilePluginDirs implements PluginDirsPort {
  const MobilePluginDirs();

  @override
  List<String> discover({Map<String, String>? env}) => const [];
}
