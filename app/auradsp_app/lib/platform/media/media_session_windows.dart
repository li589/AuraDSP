// media_session_windows.dart — MediaSessionPort 的 Windows 实现（SMTC）。
import '../platform_profile.dart';
import '../port/media_session.dart';
import 'windows_smtc_provider.dart';

final class WindowsMediaSession implements MediaSessionPort {
  const WindowsMediaSession();

  @override
  bool get supported => PlatformProfile.os == 'windows';

  @override
  MediaSessionProvider create() => WindowsSmtcProvider();
}
