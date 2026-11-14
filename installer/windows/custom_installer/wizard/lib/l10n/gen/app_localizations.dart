import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_ja.dart';
import 'app_localizations_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'gen/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('ja'),
    Locale('zh'),
  ];

  /// No description provided for @appTitle.
  ///
  /// In en, this message translates to:
  /// **'AuraDSP Setup'**
  String get appTitle;

  /// No description provided for @welcomeTitle.
  ///
  /// In en, this message translates to:
  /// **'Welcome to AuraDSP'**
  String get welcomeTitle;

  /// No description provided for @welcomeBody.
  ///
  /// In en, this message translates to:
  /// **'A cross-platform global audio effects system: real-time DSP chain, plugin hosting and virtual audio devices for your whole system.'**
  String get welcomeBody;

  /// No description provided for @licenseAgree.
  ///
  /// In en, this message translates to:
  /// **'I have read and agree to the license agreement (GPL-3.0 / bundled component licenses)'**
  String get licenseAgree;

  /// No description provided for @quickInstall.
  ///
  /// In en, this message translates to:
  /// **'Install now'**
  String get quickInstall;

  /// No description provided for @quickUpdate.
  ///
  /// In en, this message translates to:
  /// **'Update now'**
  String get quickUpdate;

  /// No description provided for @customInstall.
  ///
  /// In en, this message translates to:
  /// **'Custom install'**
  String get customInstall;

  /// No description provided for @optionsTitle.
  ///
  /// In en, this message translates to:
  /// **'Install options'**
  String get optionsTitle;

  /// No description provided for @installDirLabel.
  ///
  /// In en, this message translates to:
  /// **'Install location'**
  String get installDirLabel;

  /// No description provided for @dirAutoAppendHint.
  ///
  /// In en, this message translates to:
  /// **'If the last folder is not AuraDSP it is appended automatically, e.g. D:\\Games to D:\\Games\\AuraDSP'**
  String get dirAutoAppendHint;

  /// No description provided for @updateDirLocked.
  ///
  /// In en, this message translates to:
  /// **'An update reuses the existing folder and keeps your settings and data.'**
  String get updateDirLocked;

  /// No description provided for @driverGroupTitle.
  ///
  /// In en, this message translates to:
  /// **'Drivers (optional, selected by default)'**
  String get driverGroupTitle;

  /// No description provided for @driverOptionalHint.
  ///
  /// In en, this message translates to:
  /// **'Unchecking only skips automatic installation; driver files and manual scripts stay in the install folder.'**
  String get driverOptionalHint;

  /// No description provided for @compAsio.
  ///
  /// In en, this message translates to:
  /// **'AuraASIO driver (exposes AuraDSP to DAWs)'**
  String get compAsio;

  /// No description provided for @compVaio.
  ///
  /// In en, this message translates to:
  /// **'AuraVAIO virtual audio device driver'**
  String get compVaio;

  /// No description provided for @compDdc.
  ///
  /// In en, this message translates to:
  /// **'Preinstall curated headphone/speaker DDC calibration files'**
  String get compDdc;

  /// No description provided for @allUsers.
  ///
  /// In en, this message translates to:
  /// **'Install for all users (requires administrator)'**
  String get allUsers;

  /// No description provided for @scDesktop.
  ///
  /// In en, this message translates to:
  /// **'Desktop shortcut'**
  String get scDesktop;

  /// No description provided for @scStartMenu.
  ///
  /// In en, this message translates to:
  /// **'Start menu entry'**
  String get scStartMenu;

  /// No description provided for @scAutostart.
  ///
  /// In en, this message translates to:
  /// **'Start with Windows'**
  String get scAutostart;

  /// No description provided for @needsElevation.
  ///
  /// In en, this message translates to:
  /// **'This choice needs administrator rights. The wizard will ask Windows to elevate and then continue.'**
  String get needsElevation;

  /// No description provided for @signWarnTitle.
  ///
  /// In en, this message translates to:
  /// **'AuraVAIO is test-signed'**
  String get signWarnTitle;

  /// No description provided for @signWarnShort.
  ///
  /// In en, this message translates to:
  /// **'64-bit Windows refuses test-signed kernel drivers by default. Without test-signing mode the driver will not load (the app itself is unaffected).'**
  String get signWarnShort;

  /// No description provided for @signGuideTitle.
  ///
  /// In en, this message translates to:
  /// **'Driver signing setup'**
  String get signGuideTitle;

  /// No description provided for @signGuideBody.
  ///
  /// In en, this message translates to:
  /// **'AuraVAIO uses a self-generated test certificate, not a Microsoft Attestation/EV signature.\n\n[Affected systems] Every 64-bit Windows (Win7 / 8.1 / 10 / 11) refuses test-signed kernel drivers by default; only 32-bit editions generally allow them. Windows 11 merely adds Secure Boot and Memory Integrity hurdles - it is NOT true that Windows 10 or older is unaffected.\n\n[Option A - persistent, recommended]\n1. Open an elevated Command Prompt and run: bcdedit /set testsigning on\n2. Reboot. A \'Test Mode\' watermark at the lower right is expected.\n3. If you get \'protected by Secure Boot policy\', disable Secure Boot in BIOS (suspend BitLocker first).\n4. On Windows 11, if it still fails: Windows Security > Device security > Core isolation > turn off Memory Integrity, then reboot.\n5. Run as administrator: <install dir>\\driver\\install_vaio.ps1 -Action install\nTo revert: bcdedit /set testsigning off and reboot.\n\n[Option B - one boot only]\nSettings > System > Recovery > Advanced startup > Restart now > Troubleshoot > Advanced options > Startup Settings > Restart > press 7 or F7 \'Disable driver signature enforcement\'. This resets on the next reboot and is only for a quick check.\n\nAuraASIO is a user-mode COM component and needs none of the above. Full details: <install dir>\\driver\\README.txt.'**
  String get signGuideBody;

  /// No description provided for @signViewGuide.
  ///
  /// In en, this message translates to:
  /// **'View setup guide'**
  String get signViewGuide;

  /// No description provided for @openDriverReadme.
  ///
  /// In en, this message translates to:
  /// **'Open driver readme'**
  String get openDriverReadme;

  /// No description provided for @manualDriverHint.
  ///
  /// In en, this message translates to:
  /// **'The install folder keeps driver\\ with manual install scripts, so you can install them later as administrator.'**
  String get manualDriverHint;

  /// No description provided for @updateDetected.
  ///
  /// In en, this message translates to:
  /// **'AuraDSP v{oldVer} is installed. It will be updated to v{newVer} (settings and data are kept).'**
  String updateDetected(String oldVer, String newVer);

  /// No description provided for @updateRepair.
  ///
  /// In en, this message translates to:
  /// **'Version v{ver} is already installed. A repair / reinstall will run (settings and data are kept).'**
  String updateRepair(String ver);

  /// No description provided for @updateDowngrade.
  ///
  /// In en, this message translates to:
  /// **'Installed version v{oldVer} is newer than this package v{newVer}. Uninstall the existing version first.'**
  String updateDowngrade(String oldVer, String newVer);

  /// No description provided for @blockedHint.
  ///
  /// In en, this message translates to:
  /// **'The wizard does not downgrade automatically, to avoid incompatible settings.'**
  String get blockedHint;

  /// No description provided for @updateFrom.
  ///
  /// In en, this message translates to:
  /// **'Updated from v{oldVer} to v{newVer}'**
  String updateFrom(String oldVer, String newVer);

  /// No description provided for @finishUpdatedTitle.
  ///
  /// In en, this message translates to:
  /// **'Update complete'**
  String get finishUpdatedTitle;

  /// No description provided for @awaitingElevation.
  ///
  /// In en, this message translates to:
  /// **'Waiting for Windows administrator approval... Please click Yes in the UAC prompt.'**
  String get awaitingElevation;

  /// No description provided for @elevDeniedTitle.
  ///
  /// In en, this message translates to:
  /// **'Administrator rights not granted'**
  String get elevDeniedTitle;

  /// No description provided for @elevDeniedBody.
  ///
  /// In en, this message translates to:
  /// **'The elevation request was cancelled or denied. You can retry, or continue with current rights (the virtual audio driver and all-users install will be skipped).'**
  String get elevDeniedBody;

  /// No description provided for @elevUninstallDeniedBody.
  ///
  /// In en, this message translates to:
  /// **'The elevation request was cancelled or denied. Continuing will skip driver, device and system registry cleanup and may leave leftovers; retrying is recommended.'**
  String get elevUninstallDeniedBody;

  /// No description provided for @elevRetry.
  ///
  /// In en, this message translates to:
  /// **'Retry elevation'**
  String get elevRetry;

  /// No description provided for @elevContinue.
  ///
  /// In en, this message translates to:
  /// **'Continue anyway'**
  String get elevContinue;

  /// No description provided for @elevCancel.
  ///
  /// In en, this message translates to:
  /// **'Go back'**
  String get elevCancel;

  /// No description provided for @finishDesktopShortcut.
  ///
  /// In en, this message translates to:
  /// **'Create desktop shortcut'**
  String get finishDesktopShortcut;

  /// No description provided for @back.
  ///
  /// In en, this message translates to:
  /// **'Back'**
  String get back;

  /// No description provided for @startInstall.
  ///
  /// In en, this message translates to:
  /// **'Start install'**
  String get startInstall;

  /// No description provided for @progressTitle.
  ///
  /// In en, this message translates to:
  /// **'Installing…'**
  String get progressTitle;

  /// No description provided for @stepGuard.
  ///
  /// In en, this message translates to:
  /// **'Checking running processes'**
  String get stepGuard;

  /// No description provided for @stepBackup.
  ///
  /// In en, this message translates to:
  /// **'Backing up previous version'**
  String get stepBackup;

  /// No description provided for @stepRestore.
  ///
  /// In en, this message translates to:
  /// **'Restoring previous version'**
  String get stepRestore;

  /// No description provided for @stepExtract.
  ///
  /// In en, this message translates to:
  /// **'Extracting files'**
  String get stepExtract;

  /// No description provided for @stepAsio.
  ///
  /// In en, this message translates to:
  /// **'Registering ASIO driver'**
  String get stepAsio;

  /// No description provided for @stepDriver.
  ///
  /// In en, this message translates to:
  /// **'Installing virtual audio driver'**
  String get stepDriver;

  /// No description provided for @stepShortcuts.
  ///
  /// In en, this message translates to:
  /// **'Creating shortcuts'**
  String get stepShortcuts;

  /// No description provided for @stepRegistry.
  ///
  /// In en, this message translates to:
  /// **'Writing system registration'**
  String get stepRegistry;

  /// No description provided for @stepUninstaller.
  ///
  /// In en, this message translates to:
  /// **'Preparing uninstaller'**
  String get stepUninstaller;

  /// No description provided for @stepCleanup.
  ///
  /// In en, this message translates to:
  /// **'Removing files'**
  String get stepCleanup;

  /// No description provided for @stepDone.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get stepDone;

  /// No description provided for @finishTitle.
  ///
  /// In en, this message translates to:
  /// **'Installation complete'**
  String get finishTitle;

  /// No description provided for @warningsTitle.
  ///
  /// In en, this message translates to:
  /// **'Completed with notes:'**
  String get warningsTitle;

  /// No description provided for @launchApp.
  ///
  /// In en, this message translates to:
  /// **'Launch AuraDSP now'**
  String get launchApp;

  /// No description provided for @openSound.
  ///
  /// In en, this message translates to:
  /// **'Open Windows sound settings'**
  String get openSound;

  /// No description provided for @done.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get done;

  /// No description provided for @errorTitle.
  ///
  /// In en, this message translates to:
  /// **'Something went wrong'**
  String get errorTitle;

  /// No description provided for @errorBody.
  ///
  /// In en, this message translates to:
  /// **'The operation failed and completed steps were rolled back where possible. Details:'**
  String get errorBody;

  /// No description provided for @close.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get close;

  /// No description provided for @uninstallTitle.
  ///
  /// In en, this message translates to:
  /// **'Uninstall AuraDSP'**
  String get uninstallTitle;

  /// No description provided for @uninstallBody.
  ///
  /// In en, this message translates to:
  /// **'AuraDSP and its components will be removed from this device.'**
  String get uninstallBody;

  /// No description provided for @uninstallProgressTitle.
  ///
  /// In en, this message translates to:
  /// **'Uninstalling…'**
  String get uninstallProgressTitle;

  /// No description provided for @uninstalledTitle.
  ///
  /// In en, this message translates to:
  /// **'Uninstall complete'**
  String get uninstalledTitle;

  /// No description provided for @startUninstall.
  ///
  /// In en, this message translates to:
  /// **'Uninstall'**
  String get startUninstall;

  /// No description provided for @keepData.
  ///
  /// In en, this message translates to:
  /// **'Keep my settings, presets and calibration data'**
  String get keepData;

  /// No description provided for @keepDataHint.
  ///
  /// In en, this message translates to:
  /// **'Keeps %APPDATA%\\AuraDSP (settings / presets / calibration / session) and any files you added to the install folder. Drivers, registry entries and shortcuts are still removed.'**
  String get keepDataHint;

  /// No description provided for @uninstallDeleteAllHint.
  ///
  /// In en, this message translates to:
  /// **'The user data above will also be deleted. This cannot be undone.'**
  String get uninstallDeleteAllHint;

  /// No description provided for @uninstallKeptTitle.
  ///
  /// In en, this message translates to:
  /// **'User data kept:'**
  String get uninstallKeptTitle;

  /// No description provided for @uninstallCleanNote.
  ///
  /// In en, this message translates to:
  /// **'Program files, drivers, registry entries and shortcuts were removed.'**
  String get uninstallCleanNote;

  /// No description provided for @fileErrorTitle.
  ///
  /// In en, this message translates to:
  /// **'Failed to write a file'**
  String get fileErrorTitle;

  /// No description provided for @fileErrorBody.
  ///
  /// In en, this message translates to:
  /// **'Setup could not write the following file:\n{path}\n\nError details (verbatim):'**
  String fileErrorBody(String path);

  /// No description provided for @fileErrorCriticalNote.
  ///
  /// In en, this message translates to:
  /// **'This is a critical file and cannot be skipped. Resolve the lock or permission issue and retry, or cancel setup (completed steps will be rolled back).'**
  String get fileErrorCriticalNote;

  /// No description provided for @fileErrorRetry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get fileErrorRetry;

  /// No description provided for @fileErrorSkip.
  ///
  /// In en, this message translates to:
  /// **'Skip'**
  String get fileErrorSkip;

  /// No description provided for @fileErrorCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel setup'**
  String get fileErrorCancel;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'ja', 'zh'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'ja':
      return AppLocalizationsJa();
    case 'zh':
      return AppLocalizationsZh();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
