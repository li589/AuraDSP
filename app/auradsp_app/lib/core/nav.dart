/// 页面枚举（P0-1，2026-10-23）：索引即导航位，顺序必须与
/// `shell.dart` 的 `_destinations` 一致。
///
/// 用途：IndexedStack 保活后页面不再销毁，定时器/轮询需要知道
/// "本页当前是否可见"（`AppModel.visiblePage`）来门控高频工作。
enum AppPage { home, effects, liveprog, plugins, chain, visualizer }
