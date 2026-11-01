// registry.dart — 注册表读写端口（Windows 单点；其它平台 available=false）。
//
// 方案：docs/10-架构/APP-目录重组与平台适配层方案-2026-11-01.md §7。
// 约束：`reg.exe` 只允许出现在 lib/platform/registry/；业务层不得拼命令。
abstract interface class RegistryPort {
  /// 当前平台是否具备注册表能力。
  bool get available;

  /// 键是否存在的轻量判定（不解析值）。
  bool keyExists(String keyPath);

  /// 读取单个 REG_SZ / REG_EXPAND_SZ 值；不存在或失败返回 null。
  String? readString(String keyPath, String valueName);

  /// 读取键下所有字符串值（递归时含子键）。
  /// [valueName] 非空时只取该值名；为空时取该键下全部值。
  List<String> readStringValues(
    String keyPath, {
    String? valueName,
    bool recursive = true,
  });

  /// 写入 REG_SZ（HKCU 无需提权；HKLM 需管理员，失败返回 false）。
  bool writeString(String keyPath, String valueName, String value);

  /// 删除某个值（失败返回 false）。
  bool deleteValue(String keyPath, String valueName);
}
