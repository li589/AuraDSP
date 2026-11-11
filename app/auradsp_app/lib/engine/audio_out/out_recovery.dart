// out_recovery.dart —— 本地输出端点失效的恢复口径（第五轮 S2）。
//
// 背景（真机第五轮项 6）：APO 附加/分离等操作会重启端点栈，本地
// WasapiOut 的客户端随即被打死（AUDCLNT_E_DEVICE_INVALIDATED，
// 0x88890004）。失效客户端按 WASAPI 语义永不自愈，旧口径只能等泵
// 的 400 轮死亡计数触发 wasapiLost、整条 audio isolate 重启——恢
// 复窗口内改为原地重建输出（见 audio_isolate 泵与
// WindowsCaptureController.reinitOutput），约 30s 仍不恢复才回落
// 既有死亡语义。本文件只放纯函数口径（分类/退避），便于单测钉住。

/// 泵错误是否为「端点失效」（WASAPI 0x88890004）。
///
/// WasapiOut._hr 的 StateError 文案恒含 `hr=0x88890004`；Linux 后端
/// 的错误文案不含 HRESULT 形态，天然不命中——本分类仅对 WASAPI
/// 输出有意义，调用方另以 `audioOut is WasapiOut` 双保险。
bool isDeviceInvalidatedError(Object e) =>
    e.toString().contains('0x88890004');

/// 失效恢复窗口（毫秒）：窗口内泵错误被恢复路径吸收（不落 PUMP
/// ERROR、不发 error 事件、不计死亡计数）；超窗回落通用计数。
const int kOutReinitWindowMs = 30000;

/// 重初始化退避表（毫秒）：尝试序号（从 1 起）→ 下次尝试间隔，
/// 末项封顶。端点栈重启通常在 1s 内 settle，首试立即、随后拉开。
int outReinitBackoffMs(int attempt) {
  const table = [500, 1000, 2000, 4000];
  if (attempt < 1) return table.first;
  return table[(attempt - 1).clamp(0, table.length - 1)];
}
