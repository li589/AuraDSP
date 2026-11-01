/*
 * online_lyrics_service.dart — 在线同步歌词聚合检索（R6，2026-10-31）
 *
 * 支持多个后端，用户可在可视化高级面板中选择（默认 auto = 依次回退）：
 *   lrclib    LrcLib.net 开放库（国际曲库，exact-get + search 兜底）
 *   netease  网易云音乐公开检索/歌词接口（华语曲库）
 *   qq       QQ 音乐公开检索/歌词接口（华语曲库）
 *   kugou    酷狗音乐公开歌词检索/下载接口
 *
 * 只接受**带时间轴**的歌词（LrcParser 天然丢弃无时间戳行），避免逐行
 * 高亮错位；任何请求失败都留痕（swallow）并回退下一个源，绝不抛给 UI。
 * 测试可通过 preference 注入或子类覆写 fetchLyrics 完全离线。
 */
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../../../core/error_sink.dart';
import '../../../../core/visualizer_types.dart';
import '../models/lyric_models.dart';
import '../parsers/lrc_parser.dart';

/// 聚合在线歌词检索客户端
class OnlineLyricsService {
  OnlineLyricsService({this.preference = LyricsSource.auto});

  /// 当前用户选择的歌词来源（auto = [LyricsSource.autoOrder] 依次尝试）。
  LyricsSource preference;

  static final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 4);

  static const String _ua =
      'AuraDSP-Lyrics-Client/1.0 (https://github.com/li589/AuraDSP)';

  final Map<String, LyricDocument> _cache = {};

  /// 负命中缓存：同一曲目在 TTL 内不再重复请求。
  /// 旧实现只缓存成功结果，某首歌没歌词时每次元数据抖动都会重新打网；
  /// 现在把「确实没有」也记住，避免 UI 反复进入 searching。
  final Map<String, DateTime> _missCache = {};
  static const Duration _missTtl = Duration(minutes: 10);

  /// 切换来源后清空结果/负命中缓存，避免旧源的结论掩盖新源的真实检索。
  void clearCache() {
    _cache.clear();
    _missCache.clear();
  }

  /// 检索同步歌词（按 preference 分派；auto 模式依次回退）。
  /// [force] = 用户手动重试，跳过负命中缓存。
  Future<LyricDocument?> fetchLyrics({
    required String trackName,
    required String artistName,
    Duration? duration,
    bool force = false,
  }) async {
    final cleanTrack = trackName.trim();
    final cleanArtist = artistName.trim();
    if (cleanTrack.isEmpty) return null;

    final queryKey =
        '${preference.id}|${cleanTrack.toLowerCase()}_${cleanArtist.toLowerCase()}';
    final cached = _cache[queryKey];
    if (cached != null) return cached;
    if (!force) {
      final missAt = _missCache[queryKey];
      if (missAt != null &&
          DateTime.now().difference(missAt) < _missTtl) {
        return null;
      }
    }

    final sources = preference == LyricsSource.auto
        ? LyricsSource.autoOrder
        : <LyricsSource>[preference];

    for (final source in sources) {
      final doc = await _fetchFrom(source, cleanTrack, cleanArtist, duration);
      if (doc != null && doc.isNotEmpty) {
        _cache[queryKey] = doc;
        _missCache.remove(queryKey);
        return doc;
      }
    }
    _missCache[queryKey] = DateTime.now();
    return null;
  }

  Future<LyricDocument?> _fetchFrom(
    LyricsSource source,
    String track,
    String artist,
    Duration? duration,
  ) =>
      switch (source) {
        LyricsSource.lrclib => _fetchFromLrcLib(track, artist, duration),
        LyricsSource.netease => _fetchFromNetEase(track, artist),
        LyricsSource.qq => _fetchFromQqMusic(track, artist),
        LyricsSource.kugou => _fetchFromKugou(track, artist),
        LyricsSource.auto => Future<LyricDocument?>.value(null),
      };

  /* ---------------- 通用请求 ---------------- */

  Future<Map<String, dynamic>?> _getJson(
    Uri uri, {
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 4),
  }) async {
    try {
      final req = await _client.getUrl(uri);
      req.headers.set('User-Agent', headers?['user-agent'] ?? _ua);
      headers?.forEach((k, v) {
        if (k != 'user-agent') req.headers.set(k, v);
      });
      final resp = await req.close().timeout(timeout);
      if (resp.statusCode != 200) return null;
      final body = await resp.transform(utf8.decoder).join();
      final decoded = jsonDecode(body);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (e, st) {
      swallow(e, st);
      return null;
    }
  }

  /* ---------------- LrcLib ---------------- */

  Future<LyricDocument?> _fetchFromLrcLib(
    String trackName,
    String artistName,
    Duration? duration,
  ) async {
    final baseHeaders = {
      'user-agent': _ua,
    };

    // 1. 精确匹配（曲名 + 歌手 + 时长）
    final getUri = Uri.https('lrclib.net', '/api/get', {
      'track_name': trackName,
      if (artistName.isNotEmpty) 'artist_name': artistName,
      if (duration != null && duration.inSeconds > 0)
        'duration': duration.inSeconds.toString(),
    });
    final exact = await _getJson(getUri, headers: baseHeaders);
    final exactLrc = exact?['syncedLyrics'] as String?;
    if (exactLrc != null && exactLrc.trim().isNotEmpty) {
      return LrcParser.parse(exactLrc);
    }

    // 2. 模糊搜索兜底（精确匹配失败时取第一条带时间轴的候选）
    //    注意 /api/search 返回 JSON 数组，故走 _getJsonList。
    final searchUri = Uri.https('lrclib.net', '/api/search', {
      'track_name': trackName,
      if (artistName.isNotEmpty) 'artist_name': artistName,
    });
    final list = await _getJsonList(searchUri, headers: baseHeaders);
    if (list != null) {
      for (final item in list) {
        if (item is! Map) continue;
        final lrc = item['syncedLyrics'] as String?;
        if (lrc != null && lrc.trim().isNotEmpty) {
          final doc = LrcParser.parse(lrc);
          if (doc.isNotEmpty) return doc;
        }
      }
    }
    return null;
  }

  Future<List<dynamic>?> _getJsonList(
    Uri uri, {
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 4),
  }) async {
    try {
      final req = await _client.getUrl(uri);
      req.headers.set('User-Agent', headers?['user-agent'] ?? _ua);
      headers?.forEach((k, v) {
        if (k != 'user-agent') req.headers.set(k, v);
      });
      final resp = await req.close().timeout(timeout);
      if (resp.statusCode != 200) return null;
      final body = await resp.transform(utf8.decoder).join();
      final decoded = jsonDecode(body);
      return decoded is List ? decoded : null;
    } catch (e, st) {
      swallow(e, st);
      return null;
    }
  }

  /* ---------------- 网易云音乐 ---------------- */

  Future<LyricDocument?> _fetchFromNetEase(
    String trackName,
    String artistName,
  ) async {
    final keyword = artistName.isNotEmpty ? '$trackName $artistName' : trackName;
    final headers = {
      'user-agent': 'Mozilla/5.0',
      'referer': 'https://music.163.com/',
      'cookie': 'os=pc; appver=2.0.3',
    };

    final search = await _getJson(
      Uri.https('music.163.com', '/api/search/get/web', {
        's': keyword,
        'type': '1',
        'offset': '0',
        'total': 'true',
        'limit': '3',
      }),
      headers: headers,
    );
    final songs = search?['result']?['songs'] as List<dynamic>?;
    if (songs == null || songs.isEmpty) return null;
    final first = songs.first;
    if (first is! Map) return null;
    final id = first['id'];
    if (id == null) return null;

    final lyric = await _getJson(
      Uri.https('music.163.com', '/api/song/lyric', {
        'id': '$id',
        'lv': '1',
        'kv': '1',
        'tv': '-1',
      }),
      headers: headers,
    );
    final rawLrc = lyric?['lrc']?['lyric'] as String?;
    if (rawLrc == null || rawLrc.trim().isEmpty) return null;
    final rawTrans = lyric?['tlyric']?['lyric'] as String?;
    return LrcParser.parse(
      rawLrc,
      translationContent:
          (rawTrans != null && rawTrans.trim().isNotEmpty) ? rawTrans : null,
    );
  }

  /* ---------------- QQ 音乐 ---------------- */

  Future<LyricDocument?> _fetchFromQqMusic(
    String trackName,
    String artistName,
  ) async {
    final keyword = artistName.isNotEmpty ? '$trackName $artistName' : trackName;
    final headers = {
      'user-agent': 'Mozilla/5.0',
      'referer': 'https://y.qq.com',
    };

    final search = await _getJson(
      Uri.https('c.y.qq.com', '/soso/fcgi-bin/client_search_cp', {
        'p': '1',
        'n': '1',
        'w': keyword,
        'format': 'json',
      }),
      headers: headers,
    );
    final songList = search?['data']?['song']?['list'] as List<dynamic>?;
    if (songList == null || songList.isEmpty) return null;
    final first = songList.first;
    if (first is! Map) return null;
    final songMid = first['songmid'] as String?;
    if (songMid == null || songMid.isEmpty) return null;

    final lyric = await _getJson(
      Uri.https('c.y.qq.com', '/lyric/fcgi-bin/fcg_query_lyric_new.fcg', {
        'songmid': songMid,
        'format': 'json',
        'nobase64': '1',
      }),
      headers: headers,
    );
    final rawLrc = lyric?['lyric'] as String?;
    if (rawLrc == null || rawLrc.trim().isEmpty) return null;
    final rawTrans = lyric?['trans'] as String?;
    return LrcParser.parse(
      rawLrc,
      translationContent:
          (rawTrans != null && rawTrans.trim().isNotEmpty) ? rawTrans : null,
    );
  }

  /* ---------------- 酷狗音乐 ---------------- */

  Future<LyricDocument?> _fetchFromKugou(
    String trackName,
    String artistName,
  ) async {
    final keyword = artistName.isNotEmpty ? '$trackName $artistName' : trackName;
    final headers = {
      'user-agent': 'Mozilla/5.0',
      'referer': 'https://www.kugou.com/',
    };

    // 1. 歌曲检索 → hash / 时长
    final search = await _getJson(
      Uri.https('mobilecdn.kugou.com', '/api/v3/search/song', {
        'format': 'json',
        'keyword': keyword,
        'page': '1',
        'pagesize': '3',
        'showtype': '1',
      }),
      headers: headers,
    );
    final info = search?['data']?['info'] as List<dynamic>?;
    if (info == null || info.isEmpty) return null;
    final first = info.first;
    if (first is! Map) return null;
    final hash = first['hash'] as String?;
    if (hash == null || hash.isEmpty) return null;
    final duration = first['duration'];

    // 2. 歌词候选（返回 id + accesskey）
    final candidate = await _getJson(
      Uri.https('krcs.kugou.com', '/search', {
        'ver': '1',
        'man': 'yes',
        'client': 'mobi',
        'keyword': keyword,
        if (duration != null) 'duration': '$duration',
        'hash': hash,
      }),
      headers: headers,
    );
    final candidates = candidate?['candidates'] as List<dynamic>?;
    if (candidates == null || candidates.isEmpty) return null;
    final best = candidates.first;
    if (best is! Map) return null;
    final id = best['id'];
    final accessKey = best['accesskey'] as String?;
    if (id == null || accessKey == null || accessKey.isEmpty) return null;

    // 3. 下载歌词（base64 编码的 LRC 文本）
    final download = await _getJson(
      Uri.https('lyrics.kugou.com', '/download', {
        'ver': '1',
        'client': 'pc',
        'id': '$id',
        'accesskey': accessKey,
        'fmt': 'lrc',
        'charset': 'utf8',
      }),
      headers: headers,
    );
    final content = download?['content'] as String?;
    if (content == null || content.isEmpty) return null;
    try {
      final decoded = utf8.decode(base64.decode(content));
      final doc = LrcParser.parse(decoded);
      if (doc.isNotEmpty) return doc;
    } catch (e, st) {
      swallow(e, st);
    }
    return null;
  }
}
