// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get allUsers => 'Install for all users (requires administrator)';

  @override
  String get appTitle => 'AuraDSP Setup';

  @override
  String get back => 'Back';

  @override
  String get close => 'Close';

  @override
  String get compAsio => 'AuraASIO driver (exposes AuraDSP to DAWs)';

  @override
  String get compDdc =>
      'Preinstall curated headphone/speaker DDC calibration files';

  @override
  String get compVaio => 'AuraVAIO virtual audio device driver';

  @override
  String get customInstall => 'Custom install';

  @override
  String get done => 'Done';

  @override
  String get errorBody =>
      'The operation failed and completed steps were rolled back where possible. Details:';

  @override
  String get errorTitle => 'Something went wrong';

  @override
  String get finishTitle => 'Installation complete';

  @override
  String get installDirLabel => 'Install location';

  @override
  String get keepData => 'Keep my presets and calibration data';

  @override
  String get launchApp => 'Launch AuraDSP now';

  @override
  String get licenseAgree =>
      'I have read and agree to the license agreement (GPL-3.0 / bundled component licenses)';

  @override
  String get needsElevation =>
      'This choice needs administrator rights. The wizard will ask Windows to elevate and then continue.';

  @override
  String get openSound => 'Open Windows sound settings';

  @override
  String get optionsTitle => 'Install options';

  @override
  String get progressTitle => 'Installing…';

  @override
  String get quickInstall => 'Install now';

  @override
  String get scAutostart => 'Start with Windows';

  @override
  String get scDesktop => 'Desktop shortcut';

  @override
  String get scStartMenu => 'Start menu entry';

  @override
  String get startInstall => 'Start install';

  @override
  String get startUninstall => 'Uninstall';

  @override
  String get stepAsio => 'Registering ASIO driver';

  @override
  String get stepCleanup => 'Removing files';

  @override
  String get stepDone => 'Done';

  @override
  String get stepDriver => 'Installing virtual audio driver';

  @override
  String get stepExtract => 'Extracting files';

  @override
  String get stepGuard => 'Checking running processes';

  @override
  String get stepRegistry => 'Writing system registration';

  @override
  String get stepShortcuts => 'Creating shortcuts';

  @override
  String get stepUninstaller => 'Preparing uninstaller';

  @override
  String get uninstallBody =>
      'AuraDSP and its components will be removed from this device.';

  @override
  String get uninstallProgressTitle => 'Uninstalling…';

  @override
  String get uninstallTitle => 'Uninstall AuraDSP';

  @override
  String get uninstalledTitle => 'Uninstall complete';

  @override
  String get warningsTitle => 'Completed with notes:';

  @override
  String get welcomeBody =>
      'A cross-platform global audio effects system: real-time DSP chain, plugin hosting and virtual audio devices for your whole system.';

  @override
  String get welcomeTitle => 'Welcome to AuraDSP';
}
