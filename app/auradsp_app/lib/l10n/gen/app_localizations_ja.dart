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
  String get stereoWiden => 'ステレオ拡張';

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
  String get testSrcTitle => 'テスト音源';

  @override
  String get testSrcHint => '測定用信号；停止すると正式ソースに戻ります';

  @override
  String get srcMp3 => 'MP3 を開く';

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
  String get audioMode => 'オーディオモード';

  @override
  String get audioModeHint => 'エンジン再起動後に有効（今後のバージョンで接続）';

  @override
  String get audioDevice => 'デバイス';

  @override
  String get modeAuto => '自動';

  @override
  String get sampleRate => 'サンプルレート';

  @override
  String get buffer => 'バッファ';

  @override
  String get modeVaio => 'AuraVAIO';

  @override
  String get modeVb => 'Voicemeeter';

  @override
  String get modeSysApo => 'System APO';

  @override
  String get modeAsio => 'ASIO';

  @override
  String get modeRoot => 'Root';

  @override
  String get modeRootless => 'Rootless';

  @override
  String get modeSystem => 'システム';

  @override
  String get modeVirtual => '仮想';

  @override
  String get modeDriver => 'ドライバー';

  @override
  String get catAppearance => '外観';

  @override
  String get catAudio => 'オーディオ';

  @override
  String get catSystem => 'システム';

  @override
  String get catTest => 'テスト';

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
  String get stereoWidenHint => '過度な拡張は中央ボーカル等を打ち消すため上限保護されています';

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
  String get lpStatusOk => '実行中';

  @override
  String get lpStatusIdle => '未読込';

  @override
  String get lpStatusError => 'コンパイル失敗';

  @override
  String get lpErrInitMissing => '@init セクションがありません';

  @override
  String get lpErrInitSyntax => '@init セクションの構文エラー';

  @override
  String get lpErrSampleMissing => '@sample セクションがありません';

  @override
  String get lpErrSampleSyntax => '@sample セクションの構文エラー';

  @override
  String get lpBlockedByLint => '構造上の問題を修正してから適用してください';

  @override
  String get lpCodeMismatch => 'プリセット保存時とスクリプトが異なります。スライダー値が対応しない可能性があります';

  @override
  String get lpCompiling => 'コンパイル中…';

  @override
  String lpCompileTook(String t) {
    return '前回コンパイル $t';
  }

  @override
  String get lpCompileSlow => '遅いです。連続適用は音切れの恐れ';

  @override
  String lpSkipped(int n) {
    return '$n 件の巨大/破損ファイルをスキップ';
  }

  @override
  String get lpOverwriteTitle => '上書き確認';

  @override
  String get lpOverwriteBody => '同名のスクリプトが存在します。上書きしますか？';

  @override
  String get lpOverwriteAction => '上書き';

  @override
  String get lpDeleteTitle => 'スクリプト削除';

  @override
  String get lpDeleteBody => 'このファイルを削除しますか？元に戻せません。';

  @override
  String get lpDeleteAction => '削除';

  @override
  String get lpRenameTitle => 'スクリプト名変更';

  @override
  String get lpOpFailed => '操作に失敗しました';

  @override
  String get lpCompiledIdle => 'コンパイル済み — 右上のスイッチで適用';

  @override
  String get lpSliders => 'スクリプトスライダー（slider1..8）';

  @override
  String get lpSliderHint => '宣言があれば宣言範囲、なければ 0..1。変更はリアルタイム反映';

  @override
  String get lpLibrary => 'スクリプトライブラリ（%APPDATA%/AuraDSP/liveprog）';

  @override
  String get lpLibraryEmpty => 'ライブラリは空です — 下の名前欄から保存できます';

  @override
  String get lpSave => 'ライブラリに保存';

  @override
  String get convTitle => 'インパルス応答';

  @override
  String get convOpenIr => 'IR ファイルを開く';

  @override
  String get convClear => 'IR をクリア';

  @override
  String get convNoIr => 'IR 未読込（WAV / FLAC。形式判定・サイズ制限・健全性チェック付き）';

  @override
  String get convResampled => 'ソースのサンプルレートが異なるため自動リサンプルしました';

  @override
  String get fvTitle => 'パラメトリックリバーブ';

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

  @override
  String get navPlugins => 'プラグイン';

  @override
  String get navChain => 'チェーン';

  @override
  String get convMix => 'ミックス';

  @override
  String get convMixHint => 'ドライ/ウェット：0% = 原音のみ、100% = 畳み込みのみ（既定 100%）';

  @override
  String get ddcTitle => 'VDC 空間補正';

  @override
  String get ddcOpen => 'VDC ファイルを開く';

  @override
  String get ddcNoFile => '補正ファイル未読込（.vdc：イヤホン/スピーカー空間補正、ViPER DDC 互換）';

  @override
  String get ddcLoaded => '読込済';

  @override
  String get ddcClear => 'クリア';

  @override
  String get lpFormat => '整形';

  @override
  String get convSpectrumTitle => 'IR 周波数応答';

  @override
  String get fv3DTitle => '3D 音場レンダリング';

  @override
  String get advanced => '詳細設定';

  @override
  String get stageTube => '真空管';

  @override
  String get tubeTitle => '真空管シミュレーター';

  @override
  String get spatialReverbTitle => '空間リバーブ';

  @override
  String get reverbCustom => 'カスタム';

  @override
  String get reverbRoomSize => '部屋サイズ';

  @override
  String get reverbStereoWidth => 'ステレオ幅';

  @override
  String get reverbMix => 'リバーブミックス';

  @override
  String get eqMultiBand => 'グラフィックイコライザー';

  @override
  String eqBands(int n) {
    return '$n段';
  }

  @override
  String get eqPresets => 'プリセット';

  @override
  String get eqFlat => 'フラットリセット';

  @override
  String get eqBypass => 'バイパス';

  @override
  String get eqQFactor => 'Q値';

  @override
  String get eqFilterType => 'フィルター形式';

  @override
  String get eqInterpolation => '補間アルゴリズム';

  @override
  String get bassIntensity => '低音強度';

  @override
  String get bassMode => '低音モード';

  @override
  String get bassModeDynamic => 'ナチュラルベース';

  @override
  String get bassModeShelf => 'ピュアベース+';

  @override
  String get bassModeHarmonic => 'サブウーファー';

  @override
  String get bassModeTooltip =>
      '低音モード：\n• ナチュラル：ベンダー直ブースト、倍音なし\n• ピュアベース+：軽量倍音（0.35）\n• サブウーファー：重量倍音（0.7）、小型機でも重低音';

  @override
  String get bassCutoff => 'カットオフ周波数';

  @override
  String get bassHarmonics => '高調波注入量';

  @override
  String get bassBlend => 'ブレンドバランス';

  @override
  String get bassSubFloor => 'サブロー保護';

  @override
  String get tubeDrive => 'ドライブ飽和度';

  @override
  String get tubeStyle => '真空管スタイル';

  @override
  String get tubeStyleTriode => '三極管 12AX7';

  @override
  String get tubeStylePentode => '五極管 EL34';

  @override
  String get tubeStyleTape => 'テープウォームス';

  @override
  String get tubeOversampling => 'オーバーサンプリング';

  @override
  String get tubeCompensation => '出力レベル補正';

  @override
  String get tubeMix => 'ドライ/ウェット';

  @override
  String get dlgCancel => 'キャンセル';

  @override
  String get dlgAdd => '追加';

  @override
  String get dlgSave => '保存';

  @override
  String get dlgLoad => '読み込み';

  @override
  String get dlgClose => '閉じる';

  @override
  String get dlgUnload => 'アンロード';

  @override
  String get dlgPreset => 'プリセット';

  @override
  String get memTitle => '永続メモリと外部設定';

  @override
  String get memHint => '全エフェクト設定を自動記録し、次回起動時にシームレスに復元します。';

  @override
  String get memAutoRestore => '終了時にセッションを自動保存・復元';

  @override
  String memDir(String path) {
    return '設定ディレクトリ：$path';
  }

  @override
  String get memClear => 'セッションメモリをクリア';

  @override
  String get memCleared => '永続セッションメモリをクリアしました。次回はクリーンデフォルトで起動します';

  @override
  String get memReset => '外部設定をデフォルトにリセット';

  @override
  String get memResetDone => 'config.json を標準テンプレートにリセットしました';

  @override
  String get latUnmeasured => '未測定';

  @override
  String latTipMeasured(String text) {
    return 'コンポーネント遅延（インパルス応答実測）: $text\n↻タップで再測定（数十ms、再生に影響しません）';
  }

  @override
  String get latTipProbing => 'コンポーネント遅延を測定中…';

  @override
  String get latTipUnmeasured => '未測定です\n↻タップでインパルス応答を1回測定（数十ms）';

  @override
  String get eqCanvasHint => '上下ドラッグでゲイン · ノードをダブルタップで0dB · 背景をダブルタップでフラット化';

  @override
  String get eqBypassOn => 'バイパス中';

  @override
  String get eqFilterMinphase => '最小位相 FIR';

  @override
  String get eqFilterIir6 => '6次IIR';

  @override
  String get eqFilterIir12 => '12次IIR';

  @override
  String get eqInterpMakima => 'Makima（スムーズ・オーバーシュート防止）';

  @override
  String get eqInterpPchip => 'PCHIP（単調形状保持）';

  @override
  String get eqPresetFlat => 'フラット';

  @override
  String get eqPresetPop => 'ポップ';

  @override
  String get eqPresetRock => 'ロック';

  @override
  String get eqPresetJazz => 'ジャズ';

  @override
  String get eqPresetClassical => 'クラシック';

  @override
  String get eqPresetVocal => 'ボーカルブースト';

  @override
  String get eqPresetSmile => 'スマイル (V-Shape)';

  @override
  String get eqPresetBass => 'バスブースト';

  @override
  String get eqPresetTreble => 'トレブルクリア';

  @override
  String get eqPresetCustom => 'カスタム';

  @override
  String get eqPresetPick => 'EQスタイルプリセットを選択';

  @override
  String get eqQTip => 'Qファクター鮮鋭度 (0.3～10.0)\n垂直ドラッグで調整 · ダブルタップで1.41にリセット';

  @override
  String get stTube => '真空管';

  @override
  String get stComp => 'リミッター';

  @override
  String get stBass => '低音ブースト';

  @override
  String get stBassmono => '低域モノラル';

  @override
  String get stGate => 'ノイズゲート';

  @override
  String get stFilter => 'フィルター';

  @override
  String get filterHint => 'ゲート直後の整形：HP でローカット、LP/BP は用途別';

  @override
  String get filterType => '種類';

  @override
  String get filterHP => 'ハイパス';

  @override
  String get filterLP => 'ローパス';

  @override
  String get filterBP => 'バンドパス';

  @override
  String get filterFreq => '周波数';

  @override
  String get filterQ => 'Q 値';

  @override
  String get gateHint => 'チェーン先頭：閾値以下の背景ノイズをゲート、attack/release でエッジ整形';

  @override
  String get gateThreshold => '閾値';

  @override
  String get gateAttack => 'アタック';

  @override
  String get gateRelease => 'リリース';

  @override
  String get gateAutoGain => '自動ゲイン補償';

  @override
  String get deesserTitle => 'デエッサー';

  @override
  String get deesserFreq => '歯擦音帯域';

  @override
  String get deesserAmount => '減衰量';

  @override
  String get stHaas => '差分サラウンド';

  @override
  String get stExciter => 'エキサイター';

  @override
  String get stLoudness => 'ラウドネス';

  @override
  String get stDyneq => 'ダイナミックEQ';

  @override
  String get dyneqTitle => 'ダイナミックイコライザー';

  @override
  String get dyneqHint => '3バンドフルパラメトリックダイナミックEQ：スレッショルド超過で減衰、以下ではスタティック整形';

  @override
  String get dyneqBandLow => '低域バンド';

  @override
  String get dyneqBandMid => '中域バンド';

  @override
  String get dyneqBandHigh => '高域バンド';

  @override
  String get dyneqFreq => '周波数';

  @override
  String get dyneqQ => 'Q';

  @override
  String get dyneqGain => 'スタティックゲイン';

  @override
  String get dyneqRange => 'ダイナミックレンジ';

  @override
  String get dyneqThreshold => 'スレッショルド';

  @override
  String get dyneqAttack => 'アタック';

  @override
  String get dyneqRelease => 'リリース';

  @override
  String get loudnessHint => '小音量で低域と高域を自動補正、大音量ではスルー';

  @override
  String get loudnessAmount => '補正量';

  @override
  String get exciterHint => '高域に倍音を足し空気感を復元';

  @override
  String get exciterAmount => '倍音量';

  @override
  String get exciterHifreq => '抽出周波数';

  @override
  String get haasHint => '片側を遅延させて広がりを作り、もう片方はドライのまま';

  @override
  String get haasDelay => '遅延量';

  @override
  String get haasMix => '差分ミックス';

  @override
  String get haasSide => '遅延側';

  @override
  String get haasSideRight => '右チャンネル';

  @override
  String get haasSideLeft => '左チャンネル';

  @override
  String get bassmonoHint => 'チェーン先頭：クロスオーバー以下をモノラル化';

  @override
  String get bassmonoFreq => 'クロスオーバー';

  @override
  String get stEq => 'イコライザー';

  @override
  String get stArbmag => '任意応答EQ';

  @override
  String get stConv => 'インパルス応答';

  @override
  String get stScript => 'スクリプト';

  @override
  String get stXfeed => 'クロスフィード';

  @override
  String get stStereo => 'ステレオワイド';

  @override
  String get stReverb => 'リバーブ';

  @override
  String get stOutput => '出力段';

  @override
  String get chainTitle => '処理チェーン';

  @override
  String get chainOrderTitle => '順序と状態';

  @override
  String get chainOrderHint =>
      'ドラッグで処理順を調整（上から下へ）。変更後は「適用」をタップ。各ノードは独立してバイパス/有効化可能。右側にノード別ライブステレオメーター。';

  @override
  String get chainApply => '順序を適用';

  @override
  String get chainReset => 'デフォルトに戻す';

  @override
  String get chainReserved => '予約済み';

  @override
  String get chainFlowTitle => 'シグナルフロー（現在の順序）';

  @override
  String get chainFlowCaption => '全体シグナルフロー概略：';

  @override
  String get chainNodeInput => '入力ゲート';

  @override
  String get chainNodeShelf => 'ローシェルフEQ';

  @override
  String get chainNodeVendor => '12段内部DSPチェーン';

  @override
  String get chainNodeReverb => 'リバーブと音場';

  @override
  String get chainNodeLimiter => 'メインリミッター';

  @override
  String get chainNodeOutputGate => '出力ゲート';

  @override
  String get chainNodeOutput => 'オーディオ出力';

  @override
  String get lpManual => 'マニュアル';

  @override
  String get lpManualTitle => 'EEL2 スクリプトリファレンス';

  @override
  String get lpManualContent =>
      '【コアオーディオレジスタ】\n• spl0: 左チャンネルサンプル（浮動小数点、公称 ±1.0）\n• spl1: 右チャンネルサンプル（浮動小数点、公称 ±1.0）\n• srate: 現在のデバイス実サンプリング周波数 (Hz)\n\n【スライダー変数】\n• slider1 ~ slider8: 動的スライダーパラメータ（デフォルト 0.0 ~ 1.0）\n\n【セクション構文】\n• @init: ロードまたはリセット時に1回実行（1文以上必須）\n• @slider: スライダー操作時に実行\n• @sample: サンプルごとにリアルタイム実行';

  @override
  String get lpEditorTooltip =>
      'Cockos EEL2 スクリプトエンジンに基づくリアルタイムオーディオDSPプログラミング環境。';

  @override
  String get exciterMode => 'モード';

  @override
  String get exciterModeTooltip => '非線形伝達関数により高域倍音を生成し、高域減衰を補償して空気感と透明感を復元します。';

  @override
  String get exciterAmountInfo => '生成された高域倍音と原音の混合比率を制御します。適度な設定で音の艶やかさが向上します。';

  @override
  String get eqModeLabel => 'モード';

  @override
  String get eqModeTooltip =>
      'バンド数モード切替。キャンバス上でドラッグしてゲイン調整、ダブルクリックで0dBにリセット、右側でQ値を調節します。';

  @override
  String get haasSideTooltip =>
      'ハース効果サラウンド：片側チャンネルを0〜25ms遅延させ、両耳時間差により自然な立体サラウンド音場を生成します。';

  @override
  String get bassmonoCombinedTooltip =>
      '指定周波数以下の超低域をモノラル化し、低域の位相打ち消しを防ぎ力強い重低音を実現します。';

  @override
  String get inputGate => '入力ゲート';

  @override
  String get inputGain => '全体入力ゲイン';

  @override
  String get channelBalance => 'チャンネルバランス';

  @override
  String get channelBalanceHint => '各チャンネルの独立音量制御。最終音量 = 全体入力ゲイン × 各チャンネルバランス。';

  @override
  String get channelLeft => '左チャンネル (L)';

  @override
  String get channelRight => '右チャンネル (R)';

  @override
  String get inputStageIn => '本段入力';

  @override
  String get inputStageOut => '本段出力';

  @override
  String get chainStagePreDsp => 'DSP 前';

  @override
  String get chainStagePreVendor => 'ベンダーチェーン前';

  @override
  String get chainStagePostVendor => 'ベンダーチェーン後';

  @override
  String get chainStagePostReverb => 'リバーブ後';

  @override
  String get chainStagePostLimiter => 'リミッター後';

  @override
  String chainSlotActive(int n, String name, String fmt) {
    return 'スロット$n：$name（$fmt）';
  }

  @override
  String chainSlotEmpty(int n) {
    return 'スロット$n：未マウント';
  }

  @override
  String get chainSlotBypassed => 'バイパス中（スルー）';

  @override
  String get chainSlotProcessing => '処理中';

  @override
  String chainSlotStatusLine(String a, int b) {
    return '状態：$a • 遅延：$bサンプル';
  }

  @override
  String get chainSlotHint => '「プラグイン」ページでエフェクトを選んで本スロットにロード';

  @override
  String get chainOpenGui => 'ネイティブUIを開く (GUI)';

  @override
  String get chainBypassed => 'バイパス中';

  @override
  String get chainEnable => '有効';

  @override
  String lpSaved(String name) {
    return '保存しました：$name.eel';
  }

  @override
  String get lpAddDirTitle => '外部スクリプトプリセットフォルダを追加';

  @override
  String get lpAddDirPrompt => '.eel / .txt スクリプトプリセットを含むフォルダのフルパスを入力：';

  @override
  String get lpAddDirExample => '例：D:\\AudioScripts\\EelPresets';

  @override
  String lpChars(int n) {
    return '$n文字';
  }

  @override
  String get lpReady => '構文OK';

  @override
  String lpIssues(int n) {
    return '$n 件の潜在的問題';
  }

  @override
  String lpIssueAt(int line, String msg) {
    return '$line行目：$msg';
  }

  @override
  String get lpShowAll => '全8スロット';

  @override
  String lpAdaptive(int n) {
    return 'アダプティブ ($n)';
  }

  @override
  String get lpNoSliders => '現在のコードはslider1..8を宣言/参照していません（純粋なアルゴリズム処理）';

  @override
  String get lpExpandSliders => '全8スロットを展開';

  @override
  String get lpAddDir => '外部フォルダを追加';

  @override
  String get lpSlidersHint => 'スライダーは現在のスクリプトのslider宣言/参照に適応。右上でモード切替可。';

  @override
  String get lpLibraryHint => 'ローカル%APPDATA%ライブラリと外部プリセットフォルダの自動索引に対応。';

  @override
  String get convIrTitle => 'インパルス応答 (IR)';

  @override
  String convFramesLine(int frames, String dur, int ch, String peak, int rate) {
    return '$framesフレーム · $dur · ${ch}ch · ピーク$peak dBFS · ソース${rate}Hz';
  }

  @override
  String get ddcFilterTitle => 'VDCフィルター';

  @override
  String get stereoBandActive => '帯域別有効';

  @override
  String get stBand0 => '低域';

  @override
  String get stBand1 => '低中域';

  @override
  String get stBand2 => '中域';

  @override
  String get stBand3 => '高中域';

  @override
  String get stBand4 => '高域';

  @override
  String get stBandHint => '帯域別微調整：各帯域の拡がり量は上のマスター拡張スライダーと連動して拡大縮小されます';

  @override
  String get presetFactoryTitle => '工場出荷時チューニングプリセット';

  @override
  String get presetUserTitle => 'マイカスタムプリセット';

  @override
  String get presetUserEmpty => 'カスタムプリセットはまだありません — 調整後に下で保存';

  @override
  String presetLoadedFactory(String name) {
    return '工場プリセットを読み込みました: $name';
  }

  @override
  String presetLoadedUser(String name) {
    return 'カスタムプリセットを読み込みました: $name';
  }

  @override
  String get presetSaveHint => 'プリセット名を入力して現在の状態を保存';

  @override
  String get convSpectrumCaption => '32バンド · 0..1正規化エネルギー';

  @override
  String get sliderResetTip => 'クリックでデフォルトにリセット';

  @override
  String get plugAddDirTitle => 'プラグイン検索フォルダを追加';

  @override
  String get plugAddDirPrompt => '64ビットVST3 / CLAPエフェクトを含むフォルダのフルパスを入力または貼り付け：';

  @override
  String get plugAddDirExample => '例：D:\\AudioPlugins\\VST3';

  @override
  String get plugAddScan => '追加してスキャン';

  @override
  String plugPresetTitle(String name) {
    return 'プラグインプリセット — $name';
  }

  @override
  String get plugPresetSaveLabel => '現在のパラメータ状態を保存';

  @override
  String get plugPresetNameHint => '新しいプリセット名を入力…';

  @override
  String plugPresetList(int n) {
    return '保存済みプリセット ($n)';
  }

  @override
  String get plugPresetEmpty => '保存済みプリセットはありません。上の入力欄から保存できます。';

  @override
  String get plugTitle => 'プラグインセンター';

  @override
  String get plugLibTitle => 'サードパーティエフェクトライブラリ';

  @override
  String get plugLibHint =>
      'システム標準64ビットVST3 / CLAPフォルダとカスタムフォルダをスキャン・管理。ゼロ遅延/先読み補償、ステレオプレーンRT-Safe。';

  @override
  String get plugDeepScan => 'ディープスキャン';

  @override
  String get plugScan => 'スキャン';

  @override
  String get plugScanning => 'スキャン中…';

  @override
  String get plugScanPreparing => 'プラグインフォルダを列挙中…';

  @override
  String plugScanProgressCount(int done, int total, int found) {
    return 'スキャン済み $done/$total · $found 件見つかりました';
  }

  @override
  String get plugScanNoVerify => 'クイックスキャンはプラグインを読み込みません：メタデータのみ、マウント時に検証';

  @override
  String get plugOpenFolder => '標準VST3フォルダを開く';

  @override
  String get plugSearchHint => 'プラグイン名・ベンダー・パスを検索…';

  @override
  String get plugM1Title => 'M1プラグインホストエンジン仕様';

  @override
  String get plugM1Hint => 'マルチフォーマットインプロセスホスト、64ビットVST3・CLAP対応。';

  @override
  String get plugFeatSlots => '4スロット対称プラグインラック (Slot 1 〜 Slot 4) 独立管理・並行';

  @override
  String get plugFeatStages => '全チェーンステージ挿入 (Pre-DSP～Post-Limiter)';

  @override
  String get plugFeatGui => 'ネイティブWin32 GUIは独立メッセージループ';

  @override
  String get plugFeatPreset => 'バイナリストリーム保存と即時復元';

  @override
  String get plugFeatDirs => 'カスタム検索フォルダとローカル状態スナップショット';

  @override
  String get plugFeatRt => 'フラットステレオRT-Safe事前確保・ゼロロック';

  @override
  String plugSlot(int n) {
    return 'スロット$n (Slot $n)';
  }

  @override
  String get plugBypassed => 'バイパス中';

  @override
  String get plugCustomTitle => 'カスタムプラグイン検索フォルダ';

  @override
  String get plugCustomHint => '他ドライブやDAWのVST3/CLAPパスを追加。スキャン時に自動統合。';

  @override
  String get plugCustomAdd => 'フォルダを追加';

  @override
  String get plugCustomEmpty =>
      'カスタムフォルダはまだありません。システム既定（C:\\Program Files\\Common Files\\VST3等）のほか、右上から追加できます。';

  @override
  String plugMountTitle(int n) {
    return 'マウント状態（スロット$n）';
  }

  @override
  String plugMountEmpty(int n) {
    return 'スロット$nにサードパーティプラグインがありません';
  }

  @override
  String get plugMountEmptyHint => '下のライブラリからインストール済みVST3 / CLAPを選んでロード';

  @override
  String get plugScanNow => 'インストール済みプラグインを今すぐスキャン';

  @override
  String plugMountedTitle(int n) {
    return '現在マウント中のプラグイン（スロット$n）';
  }

  @override
  String plugMountedTitleNamed(int n, String name) {
    return '現在マウント中のプラグイン（スロット$n）：$name';
  }

  @override
  String plugEditorTitleNamed(int n, String name) {
    return '$name（スロット$n）';
  }

  @override
  String get plugOpenGuiBtn => 'UIを開く (GUI)';

  @override
  String get plugUnloadFromSlot => 'このスロットからアンロード';

  @override
  String plugLoadToSlot(int n) {
    return 'スロット$nへロード';
  }

  @override
  String get plugLatencyLabel => '実測オーディオ遅延';

  @override
  String get plugStageLabel => 'シグナルチェーン挿入ステージ：';

  @override
  String get plugRtNote => 'ライブ直列接続 • RT-Safe契約を維持';

  @override
  String get plugFilterAll => 'すべて';

  @override
  String get plugNoPlugins => 'サードパーティプラグインが検出されません';

  @override
  String get plugNoPluginsHint =>
      'システムVST3 / CLAPパスに配置済みか確認し、上のカスタムフォルダ追加後に再スキャン';

  @override
  String get plugNoMatch => '検索・フィルター条件に合うプラグインがありません';

  @override
  String get plugIncompatibleBadge => '32ビット非対応';

  @override
  String get plugIncompatibleHint =>
      'このプラグインは32ビット版です。AuraDSPは64ビットホストのため読み込めません。64ビット版をインストールしてください。';

  @override
  String plugSlotActive(int n) {
    return 'スロット$n動作中';
  }

  @override
  String plugSlotLoaded(int n) {
    return 'スロット$nロード済み';
  }

  @override
  String get plugUnknownVendor => '不明なベンダー';

  @override
  String get plugThirdParty => 'サードパーティプラグイン';

  @override
  String plugSlotPluginLine(String name, String stage) {
    return '$name • [$stage]';
  }

  @override
  String get plugSlotNoFx => 'エフェクト未マウント';

  @override
  String get chainActive => '有効中';

  @override
  String get chainBypass => 'バイパス';

  @override
  String get plugActive => '有効';

  @override
  String get lpSaveFailed => '保存に失敗しました（不正な名前または書き込み不可）';

  @override
  String get chainVstTitle => 'サードパーティVST / CLAPプラグインスロットとステージ順序';

  @override
  String get chainVstHint => '複数スロットを並行マウント。下で各プラグインの挿入ステージと順序を個別設定。';

  @override
  String get stDdc => 'VDC 空間補正';

  @override
  String get compTitle => 'ダイナミックコンプレッサー';

  @override
  String get compTimeconstant => '時定数';

  @override
  String get compGranularity => '粒度';

  @override
  String get compGranularityCoarse => '低負荷';

  @override
  String get compGranularityNormal => '標準 (バランス)';

  @override
  String get compGranularityFine => '高精細 (マルチバンド)';

  @override
  String get compTfresolution => '時間周波数分解能';

  @override
  String get compTfresTransient => '過渡応答';

  @override
  String get compTfresBalanced => 'バランス';

  @override
  String get compTfresFine => '高周波';

  @override
  String get autoGainCompensation => '自動ゲイン補正';

  @override
  String get autoGainCompensationTooltip =>
      '音量増加に応じて出力レベルを動的に調整し、クリッピングを防止します。';

  @override
  String get outputGainGate => '出力ゲインゲート';

  @override
  String get outputGainGateTooltip => 'このエフェクトの出力レベルを微調整 (-12.0 ~ +6.0 dB)。';

  @override
  String get arbmagSubtitle => '8192点因果的最小位相FIR畳み込み · 任意応答とAutoEq曲線';

  @override
  String get arbmagPresetFlat => 'フラット (Flat)';

  @override
  String get arbmagPresetHarman => 'Harman ターゲット';

  @override
  String get arbmagPresetDiffuse => '拡散音場 (Diffuse-Field)';

  @override
  String get arbmagImport => 'ファイルをインポート';

  @override
  String get arbmagPaste => '貼り付け';

  @override
  String get arbmagClear => '曲線をクリア';

  @override
  String get arbmagEmptyHint =>
      '曲線が読み込まれていません。上のプリセットを選択するか、AutoEqファイルをインポートまたはコードを貼り付けてください。';

  @override
  String get arbmagEditor => 'GraphicEQ コードエディタ';

  @override
  String arbmagNodes(int count) {
    return '$count 個の周波数ポイントを読み込みました';
  }

  @override
  String get arbmagApply => 'コードを適用';

  @override
  String get arbmagInvalidFormat => 'GraphicEQフォーマットが無効であるか、有効な周波数ノードがありません';

  @override
  String get crossfeedTitle => 'クロスフィード';

  @override
  String get crossfeedMode => 'モード';

  @override
  String get crossfeedDesc => 'ヘッドホン特有の頭内定位感を緩和し、長時間のリスニング疲労を軽減';

  @override
  String get crossfeedModeDefault => 'デフォルト標準';

  @override
  String get crossfeedModeChuMoy => 'Chu Moy クラシック';

  @override
  String get crossfeedModeJanMeier => 'Jan Meier 拡張';

  @override
  String get crossfeedModeCustom => 'カスタム';

  @override
  String get crossfeedCutoff => 'カットオフ周波数';

  @override
  String get crossfeedFeed => 'クロスフィード量';

  @override
  String crossfeedActiveDesc(String mode, String fcut, String feed) {
    return '適用中: $mode ($fcut Hz, $feed dB)';
  }
}
