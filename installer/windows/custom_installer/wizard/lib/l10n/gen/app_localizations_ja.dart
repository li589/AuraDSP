// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Japanese (`ja`).
class AppLocalizationsJa extends AppLocalizations {
  AppLocalizationsJa([String locale = 'ja']) : super(locale);

  @override
  String get appTitle => 'AuraDSP セットアップ';

  @override
  String get welcomeTitle => 'AuraDSP へようこそ';

  @override
  String get welcomeBody =>
      'クロスプラットフォームのグローバルオーディオエフェクトシステム：リアルタイム DSP チェーン、プラグインホスティング、仮想オーディオデバイスでシステム全体のサウンドを。';

  @override
  String get licenseAgree => 'ライセンス契約（GPL-3.0 / 同梱コンポーネントのライセンス）を読み、同意します';

  @override
  String get quickInstall => '今すぐインストール';

  @override
  String get quickUpdate => '今すぐ更新';

  @override
  String get customInstall => 'カスタムインストール';

  @override
  String get optionsTitle => 'インストールオプション';

  @override
  String get installDirLabel => 'インストール先';

  @override
  String get dirAutoAppendHint =>
      '最後のフォルダーが AuraDSP でない場合は自動追加します（例：D:\\Games → D:\\Games\\AuraDSP）';

  @override
  String get updateDirLocked => '上書き更新では既存のフォルダーを使用し、設定とデータを保持します。';

  @override
  String get driverGroupTitle => 'ドライバー（任意・既定で選択）';

  @override
  String get driverOptionalHint =>
      'チェックを外すと自動インストールのみスキップします。ドライバーと手動用スクリプトはインストール先に残ります。';

  @override
  String get compAsio => 'AuraASIO ドライバー（DAW に AuraDSP を公開）';

  @override
  String get compVaio => 'AuraVAIO 仮想オーディオデバイスドライバー';

  @override
  String get compDdc => '厳選ヘッドホン/スピーカー DDC キャリブレーションをプリインストール';

  @override
  String get allUsers => 'すべてのユーザーにインストール（管理者が必要）';

  @override
  String get scDesktop => 'デスクトップショートカット';

  @override
  String get scStartMenu => 'スタートメニュー項目';

  @override
  String get scAutostart => 'Windows 起動時に開始';

  @override
  String get needsElevation => 'この選択には管理者権限が必要です。ウィザードは Windows に昇格を要求して続行します。';

  @override
  String get signWarnTitle => 'AuraVAIO はテスト署名ドライバーです';

  @override
  String get signWarnShort =>
      '64 ビット Windows は既定でテスト署名カーネルドライバーを拒否します。テスト署名モードを有効にしないとドライバーは読み込まれません（本体は影響なし）。';

  @override
  String get signGuideTitle => 'ドライバー署名の設定';

  @override
  String get signGuideBody =>
      'AuraVAIO は自己生成したテスト証明書を使用しており、Microsoft の Attestation/EV 署名ではありません。\n\n【対象 OS】64 ビット Windows（Win7 / 8.1 / 10 / 11）はすべて既定でテスト署名カーネルドライバーを拒否します。32 ビット版のみ概ね制限されません。Windows 11 は Secure Boot やメモリ整合性などの条件が増えるだけで、「Win10 以前は影響なし」ではありません。\n\n【方法 A・永続（推奨）】\n1. 管理者としてコマンドプロンプトを開き、bcdedit /set testsigning on を実行\n2. 再起動します。右下に「テスト モード」と表示されるのは正常です。\n3. 「Secure Boot ポリシーで保護されています」と出た場合は BIOS で Secure Boot を無効化（BitLocker は一時停止）。\n4. Windows 11 で依然として失敗する場合：Windows セキュリティ → デバイスのセキュリティ → コアの分離 → メモリ整合性をオフにして再起動。\n5. 管理者として <インストール先>\\driver\\install_vaio.ps1 -Action install を実行\n元に戻す：bcdedit /set testsigning off 実行後に再起動。\n\n【方法 B・一時（今回の起動のみ）】\n設定 → システム → 回復 → 詳細なスタートアップ → 今すぐ再起動 → トラブルシューティング → 詳細オプション → スタートアップ設定 → 再起動 → 7 または F7「ドライバー署名の強制を無効にする」。次回再起動で解除されます。\n\nAuraASIO はユーザーモード COM コンポーネントのため、上記は不要です。詳細は <インストール先>\\driver\\README.txt を参照。';

  @override
  String get signViewGuide => '設定手順を見る';

  @override
  String get openDriverReadme => 'ドライバー説明を開く';

  @override
  String get manualDriverHint =>
      'インストール先の driver\\ にドライバーと手動インストール用スクリプトを保持します。後から管理者として導入できます。';

  @override
  String updateDetected(String oldVer, String newVer) {
    return 'AuraDSP v$oldVer がインストール済みです。v$newVer へ更新します（設定とデータは保持）。';
  }

  @override
  String updateRepair(String ver) {
    return '同じバージョン v$ver がインストール済みです。修復／再インストールします（設定とデータは保持）。';
  }

  @override
  String updateDowngrade(String oldVer, String newVer) {
    return 'インストール済み v$oldVer はこのパッケージ v$newVer より新しいため、先に旧版をアンインストールしてください。';
  }

  @override
  String get blockedHint => '設定の非互換を避けるため、自動ダウングレードは行いません。';

  @override
  String updateFrom(String oldVer, String newVer) {
    return 'v$oldVer から v$newVer へ更新しました';
  }

  @override
  String get finishUpdatedTitle => '更新完了';

  @override
  String get awaitingElevation =>
      'Windows の管理者権限の承認を待っています…UAC で「はい」を選択してください。';

  @override
  String get elevDeniedTitle => '管理者権限を取得できませんでした';

  @override
  String get elevDeniedBody =>
      '昇格要求がキャンセルまたは拒否されました。再試行するか、現在の権限で続行できます（仮想オーディオドライバーと全ユーザーインストールはスキップされます）。';

  @override
  String get elevUninstallDeniedBody =>
      '昇格要求がキャンセルまたは拒否されました。続行するとドライバー・デバイス・システム登録の削除がスキップされ、残存物が残る可能性があります。再試行を推奨します。';

  @override
  String get elevRetry => '再試行';

  @override
  String get elevContinue => 'このまま続行';

  @override
  String get elevCancel => '戻る';

  @override
  String get finishDesktopShortcut => 'デスクトップショートカットを作成';

  @override
  String get back => '戻る';

  @override
  String get startInstall => 'インストール開始';

  @override
  String get progressTitle => 'インストール中…';

  @override
  String get stepGuard => '実行中プロセスを確認';

  @override
  String get stepBackup => '旧バージョンをバックアップ';

  @override
  String get stepRestore => '旧バージョンを復元';

  @override
  String get stepExtract => 'ファイルを展開';

  @override
  String get stepAsio => 'ASIO ドライバーを登録';

  @override
  String get stepDriver => '仮想オーディオドライバーをインストール';

  @override
  String get stepShortcuts => 'ショートカットを作成';

  @override
  String get stepRegistry => 'システム登録を書き込み';

  @override
  String get stepUninstaller => 'アンインストーラーを準備';

  @override
  String get stepCleanup => 'ファイルを削除';

  @override
  String get stepDone => '完了';

  @override
  String get finishTitle => 'インストール完了';

  @override
  String get warningsTitle => '完了しました（注意事項あり）：';

  @override
  String get launchApp => 'AuraDSP を今すぐ起動';

  @override
  String get openSound => 'Windows サウンド設定を開く';

  @override
  String get done => '完了';

  @override
  String get errorTitle => '問題が発生しました';

  @override
  String get errorBody => '操作が失敗し、完了したステップは可能な限りロールバックされました。詳細：';

  @override
  String get close => '閉じる';

  @override
  String get uninstallTitle => 'AuraDSP のアンインストール';

  @override
  String get uninstallBody => 'このデバイスから AuraDSP とそのコンポーネントを削除します。';

  @override
  String get uninstallProgressTitle => 'アンインストール中…';

  @override
  String get uninstalledTitle => 'アンインストール完了';

  @override
  String get startUninstall => 'アンインストール';

  @override
  String get keepData => '設定・プリセット・キャリブレーションデータを保持';

  @override
  String get keepDataHint =>
      '%APPDATA%\\AuraDSP（設定 / プリセット / キャリブレーション / セッション）と、インストール先に自分で追加したファイルを保持します。ドライバー・レジストリ・ショートカットは削除されます。';

  @override
  String get uninstallDeleteAllHint => '上記のユーザーデータも削除されます。元に戻せません。';

  @override
  String get uninstallKeptTitle => '保持したユーザーデータ：';

  @override
  String get uninstallCleanNote => 'プログラムファイル・ドライバー・レジストリ・ショートカットを削除しました。';
}
