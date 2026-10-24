import 'package:auradsp_app/l10n/gen/app_localizations.dart';

/// B-2 引擎错误 reason-token 本地化与脱敏（计划 D2 §4.1-4.3）。
///
/// 引擎侧契约：`<subject>: <reason-token>[ (detail)]`，token 白名单 14 个
/// （与 engine/ 各 set_error 字面量、l10n arb `errXxx` 词条、
/// test/param_contract_test.dart Part H 三方同源）。
///
/// 展示层规则：
/// 1. token 命中 → `subject: ` + 三语词条；括号 detail **整体丢弃**
///    （`gate.maxFileMb` 等内部配置名与绝对路径只进 dbgLog，永不进 UI）；
/// 2. token 未命中 → [scrubEngineError] 防御性兜底（内部点名/盘符路径抹除），
///    保证永不空白；EEL 编译错误等面向脚本作者的原文原样透传。

const Set<String> kEngineReasonTokens = {
  'engine closed',
  'engine busy',
  'invalid length',
  'invalid encoding',
  'invalid path',
  'buffer too small',
  'file too small',
  'file too large',
  'out of range',
  'out of memory',
  'parse failed',
  'io failed',
  'rejected',
  'unsupported',
  'internal',
};

/// token → arb key（`engine closed` → `errEngineClosed`），Part H 契约共用。
String engineReasonArbKey(String token) {
  final parts = token.split(' ');
  final b = StringBuffer('err');
  for (final p in parts) {
    b.write(p[0].toUpperCase());
    b.write(p.substring(1));
  }
  return b.toString();
}

String _reasonTokenOf(String raw) {
  final i = raw.indexOf(': ');
  if (i < 0) return '';
  final rest = raw.substring(i + 2);
  final p = rest.indexOf(' (');
  final token = p < 0 ? rest : rest.substring(0, p);
  return kEngineReasonTokens.contains(token) ? token : '';
}

String _localized(String token, AppLocalizations l) {
  switch (token) {
    case 'engine closed':
      return l.errEngineClosed;
    case 'engine busy':
      return l.errEngineBusy;
    case 'invalid length':
      return l.errInvalidLength;
    case 'invalid encoding':
      return l.errInvalidEncoding;
    case 'invalid path':
      return l.errInvalidPath;
    case 'buffer too small':
      return l.errBufferTooSmall;
    case 'file too small':
      return l.errFileTooSmall;
    case 'file too large':
      return l.errFileTooLarge;
    case 'out of range':
      return l.errOutOfRange;
    case 'out of memory':
      return l.errOutOfMemory;
    case 'parse failed':
      return l.errParseFailed;
    case 'io failed':
      return l.errIoFailed;
    case 'rejected':
      return l.errRejected;
    case 'unsupported':
      return l.errUnsupported;
    case 'internal':
      return l.errInternal;
  }
  return '';
}

/// 防御性脱敏（仅 token 未命中的兜底路径）：抹除内部配置名与绝对路径。
String scrubEngineError(String raw) {
  var s = raw;
  // 括注内含内部配置名（gate.xxx / maxXxx）或盘符路径 → 整体剔除
  s = s.replaceAll(
      RegExp(r'\s\([^)]*(?:[A-Za-z]:\\|(?:gate|max)[A-Za-z]*\.\w+)[^)]*\)'),
      '');
  // 裸盘符绝对路径 → 占位
  s = s.replaceAll(RegExp(r'[A-Za-z]:\\[^\s,;)]+'), '…');
  return s.trim();
}

/// 展示层入口：token 命中 → 本地化；未命中 → [scrubEngineError] 兜底。
String localizeEngineError(String raw, AppLocalizations l) {
  if (raw.isEmpty) return raw;
  final token = _reasonTokenOf(raw);
  if (token.isEmpty) return scrubEngineError(raw);
  final subject = raw.substring(0, raw.indexOf(': '));
  return '$subject: ${_localized(token, l)}';
}
