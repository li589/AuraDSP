/// 本地化入口（转发 gen-l10n 产物）。
///
/// 背景：Flutter 3.47 的 analyzer 对 lib/ 下子目录中的生成代码在
/// 相对导入解析上存在已知的不稳定行为（app.dart 相对导入
/// l10n/gen/app_localizations.dart 时 analyzer 误报 URI 不存在，
/// 而 dart analyze 单独解析该文件无误、编译器可正常解析）。
/// 在 lib/l10n/ 根放一个同名转发库，app.dart 改走 package 导入，
/// 规避该问题；生成代码仍由 `flutter gen-l10n` 维护在 gen/ 下，
/// 不要手改 gen/ 内的文件。
library;

export 'gen/app_localizations.dart';
