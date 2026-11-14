// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'AuraDSP Setup';

  @override
  String get welcomeTitle => 'Welcome to AuraDSP';

  @override
  String get welcomeBody =>
      'A cross-platform global audio effects system: real-time DSP chain, plugin hosting and virtual audio devices for your whole system.';

  @override
  String get licenseAgree =>
      'I have read and agree to the license agreement (GPL-3.0 / bundled component licenses)';

  @override
  String get quickInstall => 'Install now';

  @override
  String get quickUpdate => 'Update now';

  @override
  String get customInstall => 'Custom install';

  @override
  String get optionsTitle => 'Install options';

  @override
  String get installDirLabel => 'Install location';

  @override
  String get dirAutoAppendHint =>
      'If the last folder is not AuraDSP it is appended automatically, e.g. D:\\Games to D:\\Games\\AuraDSP';

  @override
  String get updateDirLocked =>
      'An update reuses the existing folder and keeps your settings and data.';

  @override
  String get driverGroupTitle => 'Drivers (optional, selected by default)';

  @override
  String get driverOptionalHint =>
      'Unchecking only skips automatic installation; driver files and manual scripts stay in the install folder.';

  @override
  String get compAsio => 'AuraASIO driver (exposes AuraDSP to DAWs)';

  @override
  String get compVaio => 'AuraVAIO virtual audio device driver';

  @override
  String get compDdc =>
      'Preinstall curated headphone/speaker DDC calibration files';

  @override
  String get allUsers => 'Install for all users (requires administrator)';

  @override
  String get scDesktop => 'Desktop shortcut';

  @override
  String get scStartMenu => 'Start menu entry';

  @override
  String get scAutostart => 'Start with Windows';

  @override
  String get needsElevation =>
      'This choice needs administrator rights. The wizard will ask Windows to elevate and then continue.';

  @override
  String get signWarnTitle => 'AuraVAIO is test-signed';

  @override
  String get signWarnShort =>
      '64-bit Windows refuses test-signed kernel drivers by default. Without test-signing mode the driver will not load (the app itself is unaffected).';

  @override
  String get signGuideTitle => 'Driver signing setup';

  @override
  String get signGuideBody =>
      'AuraVAIO uses a self-generated test certificate, not a Microsoft Attestation/EV signature.\n\n[Affected systems] Every 64-bit Windows (Win7 / 8.1 / 10 / 11) refuses test-signed kernel drivers by default; only 32-bit editions generally allow them. Windows 11 merely adds Secure Boot and Memory Integrity hurdles - it is NOT true that Windows 10 or older is unaffected.\n\n[Option A - persistent, recommended]\n1. Open an elevated Command Prompt and run: bcdedit /set testsigning on\n2. Reboot. A \'Test Mode\' watermark at the lower right is expected.\n3. If you get \'protected by Secure Boot policy\', disable Secure Boot in BIOS (suspend BitLocker first).\n4. On Windows 11, if it still fails: Windows Security > Device security > Core isolation > turn off Memory Integrity, then reboot.\n5. Run as administrator: <install dir>\\driver\\install_vaio.ps1 -Action install\nTo revert: bcdedit /set testsigning off and reboot.\n\n[Option B - one boot only]\nSettings > System > Recovery > Advanced startup > Restart now > Troubleshoot > Advanced options > Startup Settings > Restart > press 7 or F7 \'Disable driver signature enforcement\'. This resets on the next reboot and is only for a quick check.\n\nAuraASIO is a user-mode COM component and needs none of the above. Full details: <install dir>\\driver\\README.txt.';

  @override
  String get signViewGuide => 'View setup guide';

  @override
  String get openDriverReadme => 'Open driver readme';

  @override
  String get manualDriverHint =>
      'The install folder keeps driver\\ with manual install scripts, so you can install them later as administrator.';

  @override
  String updateDetected(String oldVer, String newVer) {
    return 'AuraDSP v$oldVer is installed. It will be updated to v$newVer (settings and data are kept).';
  }

  @override
  String updateRepair(String ver) {
    return 'Version v$ver is already installed. A repair / reinstall will run (settings and data are kept).';
  }

  @override
  String updateDowngrade(String oldVer, String newVer) {
    return 'Installed version v$oldVer is newer than this package v$newVer. Uninstall the existing version first.';
  }

  @override
  String get blockedHint =>
      'The wizard does not downgrade automatically, to avoid incompatible settings.';

  @override
  String updateFrom(String oldVer, String newVer) {
    return 'Updated from v$oldVer to v$newVer';
  }

  @override
  String get finishUpdatedTitle => 'Update complete';

  @override
  String get awaitingElevation =>
      'Waiting for Windows administrator approval... Please click Yes in the UAC prompt.';

  @override
  String get elevDeniedTitle => 'Administrator rights not granted';

  @override
  String get elevDeniedBody =>
      'The elevation request was cancelled or denied. You can retry, or continue with current rights (the virtual audio driver and all-users install will be skipped).';

  @override
  String get elevUninstallDeniedBody =>
      'The elevation request was cancelled or denied. Continuing will skip driver, device and system registry cleanup and may leave leftovers; retrying is recommended.';

  @override
  String get elevRetry => 'Retry elevation';

  @override
  String get elevContinue => 'Continue anyway';

  @override
  String get elevCancel => 'Go back';

  @override
  String get finishDesktopShortcut => 'Create desktop shortcut';

  @override
  String get back => 'Back';

  @override
  String get startInstall => 'Start install';

  @override
  String get progressTitle => 'Installing…';

  @override
  String get stepGuard => 'Checking running processes';

  @override
  String get stepBackup => 'Backing up previous version';

  @override
  String get stepRestore => 'Restoring previous version';

  @override
  String get stepExtract => 'Extracting files';

  @override
  String get stepAsio => 'Registering ASIO driver';

  @override
  String get stepDriver => 'Installing virtual audio driver';

  @override
  String get stepShortcuts => 'Creating shortcuts';

  @override
  String get stepRegistry => 'Writing system registration';

  @override
  String get stepUninstaller => 'Preparing uninstaller';

  @override
  String get stepCleanup => 'Removing files';

  @override
  String get stepDone => 'Done';

  @override
  String get finishTitle => 'Installation complete';

  @override
  String get warningsTitle => 'Completed with notes:';

  @override
  String get launchApp => 'Launch AuraDSP now';

  @override
  String get openSound => 'Open Windows sound settings';

  @override
  String get done => 'Done';

  @override
  String get errorTitle => 'Something went wrong';

  @override
  String get errorBody =>
      'The operation failed and completed steps were rolled back where possible. Details:';

  @override
  String get close => 'Close';

  @override
  String get uninstallTitle => 'Uninstall AuraDSP';

  @override
  String get uninstallBody =>
      'AuraDSP and its components will be removed from this device.';

  @override
  String get uninstallProgressTitle => 'Uninstalling…';

  @override
  String get uninstalledTitle => 'Uninstall complete';

  @override
  String get startUninstall => 'Uninstall';

  @override
  String get keepData => 'Keep my settings, presets and calibration data';

  @override
  String get keepDataHint =>
      'Keeps %APPDATA%\\AuraDSP (settings / presets / calibration / session) and any files you added to the install folder. Drivers, registry entries and shortcuts are still removed.';

  @override
  String get uninstallDeleteAllHint =>
      'The user data above will also be deleted. This cannot be undone.';

  @override
  String get uninstallKeptTitle => 'User data kept:';

  @override
  String get uninstallCleanNote =>
      'Program files, drivers, registry entries and shortcuts were removed.';

  @override
  String get fileErrorTitle => 'Failed to write a file';

  @override
  String fileErrorBody(String path) {
    return 'Setup could not write the following file:\n$path\n\nError details (verbatim):';
  }

  @override
  String get fileErrorCriticalNote =>
      'This is a critical file and cannot be skipped. Resolve the lock or permission issue and retry, or cancel setup (completed steps will be rolled back).';

  @override
  String get fileErrorRetry => 'Retry';

  @override
  String get fileErrorSkip => 'Skip';

  @override
  String get fileErrorCancel => 'Cancel setup';
}
