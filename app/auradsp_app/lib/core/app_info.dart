/// 应用元信息（关于页 / 诊断展示用）。
///
/// 版本号的真相源是 pubspec.yaml 的 `version:` 行；此处常量供
/// 运行时展示，契约测试（about_page_test）断言两者一致，防漂移。
library;

/// 应用版本（与 pubspec.yaml `version:` 的 `+` 前部分一致）。
const String kAppVersion = '0.1.0';

/// 开源仓库地址（关于页链接）。
const String kAppRepoUrl = 'https://github.com/li589/AuraDSP';

/// 开源协议（仓库根 LICENSE 文件，GNU GPL v3.0 全文）。
const String kAppLicenseName = 'GNU General Public License v3.0';
