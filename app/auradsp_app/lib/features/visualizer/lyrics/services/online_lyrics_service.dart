import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../../../core/error_sink.dart';
import '../models/lyric_models.dart';
import '../parsers/lrc_parser.dart';

/// 聚合在线歌词检索客户端（支持 LrcLib 开放源 + QQ 音乐多语言备选源）
class OnlineLyricsService {
  static final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 4);

  final Map<String, LyricDocument> _cache = {};

  /// 检索同步歌词（优先 LrcLib，失败回退 QQ 音乐公有歌词库）
  Future<LyricDocument?> fetchLyrics({
    required String trackName,
    required String artistName,
    Duration? duration,
  }) async {
    final cleanTrack = trackName.trim();
    final cleanArtist = artistName.trim();
    if (cleanTrack.isEmpty) return null;

    final queryKey = '${cleanTrack.toLowerCase()}_${cleanArtist.toLowerCase()}';
    if (_cache.containsKey(queryKey)) {
      return _cache[queryKey];
    }

    // 1. 优先尝试 LrcLib 开放源
    var doc = await _fetchFromLrcLib(cleanTrack, cleanArtist, duration);

    // 2. LrcLib 无结果（如国内流行歌曲）时，回退 QQ 音乐开放检索源
    doc ??= await _fetchFromQqMusic(cleanTrack, cleanArtist);

    if (doc != null && doc.isNotEmpty) {
      _cache[queryKey] = doc;
    }
    return doc;
  }

  /// LrcLib.net 检索
  Future<LyricDocument?> _fetchFromLrcLib(
    String trackName,
    String artistName,
    Duration? duration,
  ) async {
    try {
      final uri = Uri.https('lrclib.net', '/api/get', {
        'track_name': trackName,
        if (artistName.isNotEmpty) 'artist_name': artistName,
        if (duration != null && duration.inSeconds > 0)
          'duration': duration.inSeconds.toString(),
      });

      final request = await _client.getUrl(uri);
      request.headers.set(
        'User-Agent',
        'AuraDSP-Lyrics-Client/1.0 (https://github.com/li589/AuraDSP)',
      );
      final response = await request.close().timeout(const Duration(seconds: 4));

      if (response.statusCode != 200) return null;

      final body = await response.transform(utf8.decoder).join();
      final data = jsonDecode(body) as Map<String, dynamic>?;
      if (data == null) return null;

      final syncedLrc = data['syncedLyrics'] as String?;
      if (syncedLrc != null && syncedLrc.trim().isNotEmpty) {
        return LrcParser.parse(syncedLrc);
      }
    } catch (e, st) {
      swallow(e, st);
    }
    return null;
  }

  /// QQ 音乐公开接口备用检索（覆盖广大华语歌曲）
  Future<LyricDocument?> _fetchFromQqMusic(
    String trackName,
    String artistName,
  ) async {
    try {
      final keyword = artistName.isNotEmpty ? '$trackName $artistName' : trackName;
      final searchUri = Uri.https('c.y.qq.com', '/soso/fcgi-bin/client_search_cp', {
        'p': '1',
        'n': '1',
        'w': keyword,
        'format': 'json',
      });

      final searchReq = await _client.getUrl(searchUri);
      searchReq.headers.set('User-Agent', 'Mozilla/5.0');
      searchReq.headers.set('Referer', 'https://y.qq.com');
      final searchResp = await searchReq.close().timeout(const Duration(seconds: 4));

      if (searchResp.statusCode != 200) return null;

      final searchBody = await searchResp.transform(utf8.decoder).join();
      final searchData = jsonDecode(searchBody) as Map<String, dynamic>?;
      final songList = searchData?['data']?['song']?['list'] as List<dynamic>?;

      if (songList == null || songList.isEmpty) return null;

      final firstSong = songList[0] as Map<String, dynamic>;
      final songMid = firstSong['songmid'] as String?;
      if (songMid == null || songMid.isEmpty) return null;

      final lyricUri = Uri.https('c.y.qq.com', '/lyric/fcgi-bin/fcg_query_lyric_new.fcg', {
        'songmid': songMid,
        'format': 'json',
        'nobase64': '1',
      });

      final lyricReq = await _client.getUrl(lyricUri);
      lyricReq.headers.set('User-Agent', 'Mozilla/5.0');
      lyricReq.headers.set('Referer', 'https://y.qq.com');
      final lyricResp = await lyricReq.close().timeout(const Duration(seconds: 4));

      if (lyricResp.statusCode != 200) return null;

      final lyricBody = await lyricResp.transform(utf8.decoder).join();
      final lyricData = jsonDecode(lyricBody) as Map<String, dynamic>?;
      final rawLyric = lyricData?['lyric'] as String?;
      final rawTrans = lyricData?['trans'] as String?;

      if (rawLyric != null && rawLyric.trim().isNotEmpty) {
        return LrcParser.parse(
          rawLyric,
          translationContent: (rawTrans != null && rawTrans.trim().isNotEmpty)
              ? rawTrans
              : null,
        );
      }
    } catch (e, st) {
      swallow(e, st);
    }
    return null;
  }
}

