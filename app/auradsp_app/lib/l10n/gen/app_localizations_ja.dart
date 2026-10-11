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
  String get convTitle => 'インパルス応答';

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
  String get bassModeDynamic => 'ダイナミック (DBB)';

  @override
  String get bassModeShelf => 'Hi-Fiローシェルフ';

  @override
  String get bassModeHarmonic => '心理音響ハーモニック';

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
  String get chainFlowCaption => '全体シグナルフロー概略（左から右へ）：';

  @override
  String get chainNodeShelf => 'ローシェルフEQ';

  @override
  String get chainNodeVendor => '12段内部DSPチェーン';

  @override
  String get chainNodeReverb => 'リバーブと音場';

  @override
  String get chainNodeLimiter => 'メインリミッター';

  @override
  String get chainNodeOutput => 'オーディオ出力';

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
}
