// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Japanese (`ja`).
class AppLocalizationsJa extends AppLocalizations {
  AppLocalizationsJa([String locale = 'ja']) : super(locale);

  @override
  String get allUsers => 'すべてのユーザーにインストール（管理者が必要）';

  @override
  String get appTitle => 'AuraDSP セットアップ';

  @override
  String get back => '戻る';

  @override
  String get close => '閉じる';

  @override
  String get compAsio => 'AuraASIO ドライバー（DAW に AuraDSP を公開）';

  @override
  String get compDdc => '厳選ヘッドホン/スピーカー DDC キャリブレーションをプリインストール';

  @override
  String get compVaio => 'AuraVAIO 仮想オーディオデバイスドライバー';

  @override
  String get customInstall => 'カスタムインストール';

  @override
  String get done => '完了';

  @override
  String get errorBody => '操作が失敗し、完了したステップは可能な限りロールバックされました。詳細：';

  @override
  String get errorTitle => '問題が発生しました';

  @override
  String get finishTitle => 'インストール完了';

  @override
  String get installDirLabel => 'インストール先';

  @override
  String get keepData => 'プリセットとキャリブレーションデータを保持';

  @override
  String get launchApp => 'AuraDSP を今すぐ起動';

  @override
  String get licenseAgree => 'ライセンス契約（GPL-3.0 / 同梱コンポーネントのライセンス）を読み、同意します';

  @override
  String get needsElevation => 'この選択には管理者権限が必要です。ウィザードは Windows に昇格を要求して続行します。';

  @override
  String get openSound => 'Windows サウンド設定を開く';

  @override
  String get optionsTitle => 'インストールオプション';

  @override
  String get progressTitle => 'インストール中…';

  @override
  String get quickInstall => '今すぐインストール';

  @override
  String get scAutostart => 'Windows 起動時に開始';

  @override
  String get scDesktop => 'デスクトップショートカット';

  @override
  String get scStartMenu => 'スタートメニュー項目';

  @override
  String get startInstall => 'インストール開始';

  @override
  String get startUninstall => 'アンインストール';

  @override
  String get stepAsio => 'ASIO ドライバーを登録';

  @override
  String get stepCleanup => 'ファイルを削除';

  @override
  String get stepDone => '完了';

  @override
  String get stepDriver => '仮想オーディオドライバーをインストール';

  @override
  String get stepExtract => 'ファイルを展開';

  @override
  String get stepGuard => '実行中プロセスを確認';

  @override
  String get stepRegistry => 'システム登録を書き込み';

  @override
  String get stepShortcuts => 'ショートカットを作成';

  @override
  String get stepUninstaller => 'アンインストーラーを準備';

  @override
  String get uninstallBody => 'このデバイスから AuraDSP とそのコンポーネントを削除します。';

  @override
  String get uninstallProgressTitle => 'アンインストール中…';

  @override
  String get uninstallTitle => 'AuraDSP のアンインストール';

  @override
  String get uninstalledTitle => 'アンインストール完了';

  @override
  String get warningsTitle => '完了しました（注意事項あり）：';

  @override
  String get welcomeBody =>
      'クロスプラットフォームのグローバルオーディオエフェクトシステム：リアルタイム DSP チェーン、プラグインホスティング、仮想オーディオデバイスでシステム全体のサウンドを。';

  @override
  String get welcomeTitle => 'AuraDSP へようこそ';
}
