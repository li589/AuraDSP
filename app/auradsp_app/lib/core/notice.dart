/// 通用通知模型（2026-11-09 通知组件化）。
///
/// 全 app 的瞬时通知统一经 AppModel.postNotice 投递、由 shell 的
/// NoticeHost 渲染为底部提醒框。此前通知散落在各页面自行
/// ScaffoldMessenger.showSnackBar（26 处），样式/时长/图标各行其是；
/// 收口后投递方只给文案与等级，呈现只有 NoticeHost 一处。
library;

/// 通知等级：决定提醒框的图标与色调（与引擎事件通道的
/// guard=warning / error=error / info=accent 口径一致）。
enum NoticeLevel { info, warning, error }

/// 一条待渲染通知。text 为已本地化文案（投递方负责本地化，
/// 与既有 lastInfo 通道的口径一致）；引擎原始错误串不走本类，
/// 仍走 lastEngineError 通道在呈现层本地化（B-2）。
class AppNotice {
  final String text;
  final NoticeLevel level;
  const AppNotice(this.text, this.level);
}
