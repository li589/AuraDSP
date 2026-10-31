import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../../../core/error_sink.dart';
import '../../../../platform/platform_profile.dart';
import '../models/lyric_models.dart';
import 'media_sync_service.dart';

/// Windows 宿主 SMTC (System Media Transport Controls) 媒体会话提供者
///
/// 通过 Windows.Media.Control 实时监听系统所有正在播放音频的应用（网易云音乐、QQ音乐、Spotify、Chrome等），
/// 提取实时曲目名称、艺术家、专辑及播放时序状态。
class WindowsSmtcProvider implements MediaSessionProvider {
  final StreamController<MediaTrackMetadata> _controller =
      StreamController<MediaTrackMetadata>.broadcast();

  Process? _process;
  StreamSubscription<String>? _stdoutSub;
  MediaTrackMetadata _lastTrack = MediaTrackMetadata.empty;
  bool _disposed = false;

  /// 主动停止标记：stop() 后不得再由 exitCode 回调自动重启（旧实现只在
  /// dispose 时检查 _disposed，关闭歌词后子进程仍每秒轮询且被自动拉起）。
  bool _stopped = true;

  /// 启动中标记：Process.start 是异步的，防止并发 start() 拉起两个进程。
  bool _starting = false;

  @override
  Stream<MediaTrackMetadata> get trackStream => _controller.stream;

  /// 启动系统媒体监听进程
  void start() {
    if (_disposed || _starting || _process != null) return;
    if (PlatformProfile.os != 'windows') return;
    _stopped = false;
    _starting = true;

    try {
      const psScript = r'''
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
Add-Type -AssemblyName System.Runtime.WindowsRuntime
$asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]

function AwaitOp($op, $t) {
    $task = $asTaskGeneric.MakeGenericMethod($t).Invoke($null, @($op))
    $task.Wait(-1) | Out-Null
    return $task.Result
}

[Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager, Windows.Media, ContentType=WindowsRuntime] | Out-Null
[Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties, Windows.Media, ContentType=WindowsRuntime] | Out-Null

try {
    $mgrOp = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager]::RequestAsync()
    $mgr = AwaitOp $mgrOp ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager])

    while ($true) {
        try {
            $session = $mgr.GetCurrentSession()
            if ($session) {
                $propsOp = $session.TryGetMediaPropertiesAsync()
                $props = AwaitOp $propsOp ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties])
                $tl = $session.GetTimelineProperties()
                $pb = $session.GetPlaybackInfo()
                $isPlaying = ($pb.PlaybackStatus -eq [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionPlaybackStatus]::Playing)
                [PSCustomObject]@{
                    title = $props.Title
                    artist = $props.Artist
                    album = $props.AlbumTitle
                    isPlaying = $isPlaying
                    positionSec = $tl.Position.TotalSeconds
                    durationSec = $tl.EndTime.TotalSeconds
                } | ConvertTo-Json -Compress
            } else {
                '{"empty":true}'
            }
        } catch {
            '{"empty":true}'
        }
        [System.Threading.Thread]::Sleep(1000)
    }
} catch {
    '{"empty":true}'
}
''';

      Process.start(
        'powershell',
        [
          '-WindowStyle',
          'Hidden',
          '-NoProfile',
          '-NonInteractive',
          '-ExecutionPolicy',
          'Bypass',
          '-Command',
          psScript,
        ],
        mode: ProcessStartMode.normal,
      ).then((proc) {
        _starting = false;
        if (_disposed || _stopped) {
          proc.kill();
          return;
        }
        _process = proc;

        _stdoutSub = proc.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen(
          _handleOutputLine,
          onError: (e, st) => swallow(e, st),
          cancelOnError: false,
        );
        // 持续清空 stderr：否则管道缓冲区写满会让监听子进程阻塞
        proc.stderr.listen(
          (_) {},
          onError: (e, st) => swallow(e, st),
          cancelOnError: false,
        );

        proc.exitCode.then((_) {
          _process = null;
          // 仅在“未销毁且未被主动停止”时才自动重试；stop() 后彻底静默。
          if (!_disposed && !_stopped) {
            Future.delayed(const Duration(seconds: 10), () {
              if (!_disposed && !_stopped) start();
            });
          }
        });
      }).catchError((e, st) {
        _starting = false;
        swallow(e, st);
      });
    } catch (e, st) {
      swallow(e, st);
    }
  }

  void _handleOutputLine(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return;

    try {
      final json = jsonDecode(trimmed) as Map<String, dynamic>;
      if (json['empty'] == true) {
        if (_lastTrack.hasContent) {
          _lastTrack = MediaTrackMetadata.empty;
          if (!_controller.isClosed) _controller.add(_lastTrack);
        }
        return;
      }

      final title = (json['title'] as String?)?.trim() ?? '';
      final artist = (json['artist'] as String?)?.trim() ?? '';
      final album = (json['album'] as String?)?.trim() ?? '';
      final isPlaying = json['isPlaying'] as bool? ?? false;
      final posSec = (json['positionSec'] as num?)?.toDouble() ?? 0.0;
      final durSec = (json['durationSec'] as num?)?.toDouble() ?? 0.0;

      final track = MediaTrackMetadata(
        title: title,
        artist: artist,
        album: album,
        isPlaying: isPlaying,
        position: Duration(milliseconds: (posSec * 1000).round()),
        duration: Duration(milliseconds: (durSec * 1000).round()),
      );

      _lastTrack = track;
      if (!_controller.isClosed) {
        _controller.add(track);
      }
    } catch (e, st) {
      swallow(e, st);
    }
  }

  /// 主动停止监听子进程（关闭歌词 / 离开可视化页）。可再次 start() 恢复。
  void stop() {
    _stopped = true;
    _starting = false;
    _stdoutSub?.cancel();
    _stdoutSub = null;
    _process?.kill();
    _process = null;
  }

  @override
  void dispose() {
    _disposed = true;
    stop();
    _controller.close();
  }
}

