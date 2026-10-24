/*
 * path_memory.dart — 外部文件选取路径记忆（统一 JSON）
 *
 * 所有「打开外部文件/文件夹」的选取器共享这一个 json
 * （%APPDATA%/AuraDSP/file_paths.json），按 slot 分槽记忆上次目录：
 *
 *   convolverIr     卷积 IR（irs/wav/flac）
 *   ddcVdc          DDC 表（vdc）
 *   arbmagGraphicEq 任意响应导入（txt/csv）
 *   testAudioFile   测试音频文件（WAV/MP3 同一槽：都是测试音选取）
 *   liveprogScript  liveprog 脚本浏览器当前目录
 *
 * 保存频率与触发条件（2026-10-16 定）：
 *   - 选取成功（file_selector 返回路径）→ 立即写盘（选取是低频人工动作，
 *     小文件原子写，无需防抖）；
 *   - 浏览器目录导航（liveprog）→ 立即写盘（用户 paced，频率有界）；
 *   - 失败/取消 → 不写（保持上次记忆）。
 * 单一事实源：各 UI 不再自持 _dir 静态字段，一律经 PathMemory 读写。
 */
import 'dart:convert';
import 'dart:io';

import 'config.dart';

import 'error_sink.dart';
abstract final class PathMemory {
  static const String filePathsJson = 'file_paths.json';
  static const int version = 1;

  // slot 名常量（避免各处散落魔法字符串）
  static const String slotConvolverIr = 'convolverIr';
  static const String slotDdcVdc = 'ddcVdc';
  static const String slotArbmag = 'arbmagGraphicEq';
  static const String slotTestAudio = 'testAudioFile';
  static const String slotLiveprogScript = 'liveprogScript';
  // 文本输入式「添加目录」对话框的上次输入（播种 TextField）
  static const String slotLastScriptDir = 'lastScriptDir';
  static const String slotLastPluginDir = 'lastPluginDir';

  static const Map<String, String> _fallbackDir = {
    slotConvolverIr: '',
    slotDdcVdc: '',
    slotArbmag: '',
    slotTestAudio: '',
    slotLiveprogScript: 'liveprog', // ConfigManager.path 的相对子目录
  };

  static Map<String, String> _dirs = {};
  static bool _loaded = false;

  static String get _path => ConfigManager.path(filePathsJson);

  /// 懒加载：进程内只读一次盘。测试沙箱下 baseDir 在临时目录，天然隔离。
  static void _ensureLoaded() {
    if (_loaded) return;
    _loaded = true;
    try {
      final f = File(_path);
      if (!f.existsSync()) return;
      final raw = f.readAsStringSync();
      final obj = _decode(raw);
      final d = obj['dirs'];
      if (d is Map) {
        _dirs = d.map((k, v) => MapEntry(k.toString(), v.toString()));
      }
    } catch (e, st) {
      swallow(e, st);
      _dirs = {};
    }
  }

  static Map<String, dynamic> _decode(String raw) {
    try {
      final v = jsonDecode(raw);
      if (v is Map<String, dynamic>) return v;
    } catch (e, st) { swallow(e, st); }
    return {};
  }

  /// 取某 slot 记忆目录；无记忆时返回 null（调用方自行决定初始目录）。
  static String? dirFor(String slot) {
    _ensureLoaded();
    final v = _dirs[slot];
    if (v == null || v.isEmpty) return null;
    return Directory(v).existsSync() ? v : null; // 目录已消失（盘符卸载等）→ 视为无记忆
  }

  /// 记录一次成功选取：写 filePath 所在目录。
  static bool recordPick(String slot, String filePath) {
    final dir = File(filePath).parent.path;
    return setDir(slot, dir);
  }

  /// 直接设置 slot 目录（浏览器导航等场景）。
  static bool setDir(String slot, String dir) {
    if (dir.isEmpty) return false;
    _ensureLoaded();
    if (_dirs[slot] == dir) return true; // 无变化不写盘
    _dirs[slot] = dir;
    return _flush();
  }

  /// slot 的兜底初始目录（无记忆时）：
  /// 优先智能探测安装包/运行目录资源库（`resources/{subFolder}`）、
  /// 用户配置中心（`%APPDATA%/AuraDSP/resources/{subFolder}`）以及工程 assets。
  static String? fallbackDir(String slot) {
    final subFolder = switch (slot) {
      slotConvolverIr => 'convolver',
      slotDdcVdc => 'ddc',
      slotLiveprogScript => 'liveprog',
      _ => _fallbackDir[slot] ?? '',
    };

    if (subFolder.isNotEmpty) {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      final candidates = <String>[
        '$exeDir${Platform.pathSeparator}resources${Platform.pathSeparator}$subFolder',
        '$exeDir${Platform.pathSeparator}assets${Platform.pathSeparator}$subFolder',
        ConfigManager.path('resources${Platform.pathSeparator}$subFolder'),
        ConfigManager.path(subFolder),
        'assets${Platform.pathSeparator}$subFolder',
        '..${Platform.pathSeparator}..${Platform.pathSeparator}assets${Platform.pathSeparator}$subFolder',
      ];

      for (final p in candidates) {
        try {
          final d = Directory(p);
          if (d.existsSync()) return d.path;
        } catch (e, st) { swallow(e, st); }
      }
    }

    final rel = _fallbackDir[slot];
    if (rel == null || rel.isEmpty) return null;
    final p = ConfigManager.path(rel);
    return Directory(p).existsSync() ? p : null;
  }

  static bool _flush() {
    try {
      final dir = Directory(ConfigManager.baseDir);
      if (!dir.existsSync()) dir.createSync(recursive: true);
      return ConfigManager.writeJsonFile(_path, {
        'version': version,
        'dirs': _dirs,
      });
    } catch (e, st) {
      swallow(e, st);
      return false;
    }
  }

  /// 测试辅助：重置内存态（不删盘）。
  static void resetForTest() {
    _dirs = {};
    _loaded = false;
  }
}
