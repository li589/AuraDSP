// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Japanese (`ja`).
class AppLocalizationsJa extends AppLocalizations {
  AppLocalizationsJa([String locale = 'ja']) : super(locale);

  @override
  String get appName => 'AuraDSP';

  @override
  String get navHome => 'ホーム';

  @override
  String get navEffects => 'エフェクト';

  @override
  String get navVisualizer => 'ビジュアライザー';

  @override
  String get navSettings => '設定';

  @override
  String get stateProcessing => '処理中';

  @override
  String get stateBypass => 'バイパス';

  @override
  String get stateError => 'エラー';

  @override
  String get latencyLabel => '遅延';

  @override
  String latencyMs(int n) {
    return '遅延 ${n}ms';
  }

  @override
  String get latencyTip => 'アルゴリズム追加レイテンシ：遅延を生む効果のみ加算（例：リバーブ +30ms）。低遅延効果は 0ms';

  @override
  String get latencyMode => '遅延モード';

  @override
  String get latencyRealtime => 'リアルタイム';

  @override
  String get latencyMusic => 'ミュージック';

  @override
  String get latencyQuality => 'クオリティ';

  @override
  String get latencyRealtimeDesc => '≤10ms · ゲーム/配信、低遅延のみ';

  @override
  String get latencyMusicDesc => '≤30ms · 音楽鑑賞（推奨）';

  @override
  String get latencyQualityDesc => '無制限 · 映画/音質重視、リバーブ可';

  @override
  String get bassBoost => 'ベースブースト';

  @override
  String get bassGain => 'ブースト量';

  @override
  String get reverb => 'リバーブ';

  @override
  String get reverbPreset => 'プリセット';

  @override
  String get reverbOff => 'オフ';

  @override
  String get stereoWiden => 'ステレオワイド';

  @override
  String get postGain => '出力ゲイン';

  @override
  String get equalizer => 'イコライザー';

  @override
  String get limiter => 'リミッター';

  @override
  String get engineInfo => 'エンジン';

  @override
  String get engineForm => 'Desktop（プロセス内）';

  @override
  String engineAbi(int a, String v) {
    return 'ABI v$a · $v';
  }

  @override
  String get theme => 'カラースキーム';

  @override
  String get themeAuraDark => 'Aura ダーク';

  @override
  String get themeAuraLight => 'Aura ライト';

  @override
  String get themeAurora => 'Aurora';

  @override
  String get language => '言語';

  @override
  String get about => '情報';

  @override
  String get aboutBody =>
      'AuraDSP Engines + AuraDSP UI。DSP コアは libjamesdsp（ソース統合、GPL 系）。';

  @override
  String get spectrum => 'リアルタイムスペクトル';

  @override
  String get noAudio => 'アイドル — エンジンに音声ストリームなし';

  @override
  String get guardBlocked => 'ブロック：現在の遅延予算を超過。クオリティモードで有効化できます';

  @override
  String get reverbPreset0 => 'コンサートホール';

  @override
  String get reverbPreset1 => '小ホール';

  @override
  String get reverbPreset2 => '中ホール';

  @override
  String get reverbPreset3 => '大ホール';

  @override
  String get reverbPreset4 => '巨大ホール';

  @override
  String get reverbPreset5 => '大聖堂';

  @override
  String get reverbPreset6 => '超巨大ホール';

  @override
  String get reverbPreset7 => '渓谷';

  @override
  String get sourceCard => 'オーディオソース';

  @override
  String get srcTone => 'テストトーン 440Hz';

  @override
  String get srcPink => 'ピンクノイズ';

  @override
  String get srcFile => 'WAV ファイルを開く';

  @override
  String get srcStop => '停止';

  @override
  String get bypassOn => 'バイパス ON（A/B）';

  @override
  String get bypassOff => 'バイパス OFF';

  @override
  String get engineFailed => 'エンジン初期化に失敗';

  @override
  String get engineFailedBody =>
      'auradsp_engine.dll が見つからないか、初期化に失敗しました。DLL が同梱済みの場合は、下のエラー詳細を確認してください（音声デバイス / COM 初期化が主因）。';

  @override
  String get reverbNeedsQuality => '品質モード限定';

  @override
  String get channelMode => 'チャンネルモード';

  @override
  String get channelsStereo => 'ステレオ';

  @override
  String get channels51 => '5.1';

  @override
  String get channels71 => '7.1';

  @override
  String get channelPhaseA =>
      'Phase A：マトリクスダウンミックス（ADR-003）。チャンネル別インスタンスは Phase B で提供。';

  @override
  String get pageHomeEyebrow => 'コンソール';

  @override
  String get pageHomeTitle => 'エンジン概要';

  @override
  String get pageEffectsEyebrow => 'DSPチェーン';

  @override
  String get pageEffectsTitle => 'エフェクト';

  @override
  String get pageVisualizerEyebrow => 'アナライザー';

  @override
  String get pageVisualizerTitle => 'リアルタイムスペクトル';

  @override
  String get pageSettingsEyebrow => '環境設定';

  @override
  String get pageSettingsTitle => '設定';

  @override
  String get statusLabel => 'ステータス';

  @override
  String get levelsTitle => 'レベル';

  @override
  String get deviceLabel => '出力デバイス';

  @override
  String get peakLabel => 'ピーク';

  @override
  String get themeSwitchTip => '配色を切り替え';

  @override
  String get heroHintProcessing => '音声がチェーンを通過中 — 変更は即時反映';

  @override
  String get heroHintIdle => '下のソースを選んで開始';

  @override
  String get reverbAutoQuality => 'リバーブを有効にするため品質モードへ自動切替しました';

  @override
  String get reverbAutoQualityHint => 'プリセット選択で品質モードへ自動切替（リバーブは T2 効果）';

  @override
  String get stereoWidenHint =>
      'ワイドニングは 75% まで：それ以上は中央定位（ボーカル等）が打ち消されほぼ無音になります';

  @override
  String get railCollapseTip => 'サイドバーを折りたたむ';

  @override
  String get railExpandTip => 'サイドバーを展開';

  @override
  String get navLiveprog => 'スクリプト';

  @override
  String get pageLiveprogEyebrow => 'ライブコーディング';

  @override
  String get pageLiveprogTitle => 'プログラマブル DSP';

  @override
  String get lpEditor => 'EEL2 エディタ';

  @override
  String get lpEditorHint =>
      'spl0/spl1（L/R サンプル）、srate、slider1..8。@init セクションには最低 1 文必要';

  @override
  String get lpApply => '適用してコンパイル';

  @override
  String get lpUnload => '解放';

  @override
  String get lpNew => '新規テンプレート';

  @override
  String get lpCompileOk => 'コンパイル成功 — スクリプト実行中';

  @override
  String get lpNoCode => 'スクリプト未読込（有効時はパススルー）';

  @override
  String get lpSliders => 'スクリプトスライダー（slider1..8）';

  @override
  String get lpSliderHint => '範囲 -1..+4。意味はスクリプト次第。変更はリアルタイム反映';

  @override
  String get lpLibrary => 'スクリプトライブラリ（%APPDATA%/AuraDSP/liveprog）';

  @override
  String get lpLibraryEmpty => 'ライブラリは空です — 下の名前欄から保存できます';

  @override
  String get lpSave => 'ライブラリに保存';

  @override
  String get convTitle => 'コンボルバー / IR';

  @override
  String get convOpenIr => 'IR ファイルを開く';

  @override
  String get convClear => 'IR をクリア';

  @override
  String get convNoIr => 'IR 未読込（WAV / FLAC。形式判定・サイズ制限・健全性チェック付き）';

  @override
  String get convResampled => 'ソースのサンプルレートが異なるため自動リサンプルしました（明示）';

  @override
  String get convAutoQuality => 'コンボルバーを有効にするため品質モードへ自動切替しました';

  @override
  String get signalFlow => 'シグナルフロー';

  @override
  String get fvTitle => 'パラメトリックリバーブ';

  @override
  String get fvHint =>
      'Freeverb アルゴリズム（8 コム + 4 オールパス/CH）。プリセットリバーブと併用可。品質モード限定';

  @override
  String get fvDecayLabel => '減衰';

  @override
  String get fvDampLabel => 'ダンピング';

  @override
  String get fvWetLabel => 'ウェット';

  @override
  String get fvDryLabel => 'ドライ';

  @override
  String get presetTitle => 'プリセット';

  @override
  String get presetHint =>
      'エンジン全パラメータのスナップショット保存/読込（%APPDATA%/AuraDSP/presets）。T2 効果は音楽モードでガード拒否（明示）';

  @override
  String get presetLoadHint => 'クリックで読込：';

  @override
  String get presetEmpty => 'ライブラリは空です — 設定後に下の名前欄から保存';

  @override
  String get presetSave => '現在を保存';

  @override
  String get presetDelete => '削除';

  @override
  String get presetSaved => 'プリセットを保存しました';

  @override
  String get presetSaveFail => '保存失敗（名式またはディスク）';

  @override
  String get presetDeleted => 'プリセットを削除しました';

  @override
  String get presetDeleteFail => '削除失敗';

  @override
  String get presetLoaded => 'プリセットを適用しました';

  @override
  String get presetLoadFail => 'プリセット読込失敗';
}
