// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appName => 'AuraDSP';

  @override
  String get navHome => 'Home';

  @override
  String get navEffects => 'Effects';

  @override
  String get navVisualizer => 'Visualizer';

  @override
  String get navSettings => 'Settings';

  @override
  String get stateProcessing => 'Processing';

  @override
  String get stateBypass => 'Bypass';

  @override
  String get stateError => 'Error';

  @override
  String get latencyLabel => 'Latency';

  @override
  String latencyMs(int n) {
    return 'Latency ${n}ms';
  }

  @override
  String get latencyTip =>
      'Added algorithmic latency: only latency-introducing effects count (e.g. reverb +30ms); low-latency effects add 0ms';

  @override
  String get latencyMode => 'Latency mode';

  @override
  String get latencyRealtime => 'Realtime';

  @override
  String get latencyMusic => 'Music';

  @override
  String get latencyQuality => 'Quality';

  @override
  String get latencyRealtimeDesc =>
      '≤10ms · gaming/live, low-latency effects only';

  @override
  String get latencyMusicDesc => '≤30ms · music listening (recommended)';

  @override
  String get latencyQualityDesc =>
      'uncapped · movies/audiophile, reverb allowed';

  @override
  String get bassBoost => 'Bass Boost';

  @override
  String get bassGain => 'Amount';

  @override
  String get reverb => 'Reverb';

  @override
  String get reverbPreset => 'Preset';

  @override
  String get reverbOff => 'Off';

  @override
  String get stereoWiden => 'Stereo Widen';

  @override
  String get postGain => 'Post Gain';

  @override
  String get equalizer => 'Equalizer';

  @override
  String get limiter => 'Limiter';

  @override
  String get engineInfo => 'Engine';

  @override
  String get engineForm => 'Desktop (in-process)';

  @override
  String engineAbi(int a, String v) {
    return 'ABI v$a · $v';
  }

  @override
  String get theme => 'Color scheme';

  @override
  String get themeAuraDark => 'Aura Dark';

  @override
  String get themeAuraLight => 'Aura Light';

  @override
  String get themeAurora => 'Aurora';

  @override
  String get language => 'Language';

  @override
  String get about => 'About';

  @override
  String get aboutBody =>
      'AuraDSP Engines + AuraDSP UI. DSP core built from libjamesdsp sources (GPL-family licensed).';

  @override
  String get spectrum => 'Live spectrum';

  @override
  String get noAudio => 'Idle — no audio stream through the engine';

  @override
  String get guardBlocked =>
      'Blocked: effect exceeds current latency budget. Switch to Quality mode to enable.';

  @override
  String get reverbPreset0 => 'Concert Hall';

  @override
  String get reverbPreset1 => 'Small Hall';

  @override
  String get reverbPreset2 => 'Medium Hall';

  @override
  String get reverbPreset3 => 'Grand Hall';

  @override
  String get reverbPreset4 => 'Vast Hall';

  @override
  String get reverbPreset5 => 'Cathedral';

  @override
  String get reverbPreset6 => 'Colossal Hall';

  @override
  String get reverbPreset7 => 'Valley';

  @override
  String get sourceCard => 'Audio Source';

  @override
  String get srcTone => 'Test Tone 440Hz';

  @override
  String get srcPink => 'Pink Noise';

  @override
  String get srcFile => 'Open WAV File';

  @override
  String get srcStop => 'Stop';

  @override
  String get bypassOn => 'Bypass ON (A/B)';

  @override
  String get bypassOff => 'Bypass OFF';

  @override
  String get engineFailed => 'Engine Initialization Failed';

  @override
  String get engineFailedBody =>
      'auradsp_engine.dll was not found or failed to initialize. If the DLL is already bundled, check the error details below (common causes: audio device / COM initialization).';

  @override
  String get reverbNeedsQuality => 'Quality tier only';

  @override
  String get channelMode => 'Channel Mode';

  @override
  String get channelsStereo => 'Stereo';

  @override
  String get channels51 => '5.1';

  @override
  String get channels71 => '7.1';

  @override
  String get channelPhaseA =>
      'Phase A: matrix downmix envelope (ADR-003). True per-channel instances ship in Phase B.';

  @override
  String get pageHomeEyebrow => 'CONSOLE';

  @override
  String get pageHomeTitle => 'Engine Overview';

  @override
  String get pageEffectsEyebrow => 'DSP CHAIN';

  @override
  String get pageEffectsTitle => 'Effects';

  @override
  String get pageVisualizerEyebrow => 'ANALYZER';

  @override
  String get pageVisualizerTitle => 'Live Spectrum';

  @override
  String get pageSettingsEyebrow => 'PREFERENCES';

  @override
  String get pageSettingsTitle => 'Settings';

  @override
  String get statusLabel => 'STATUS';

  @override
  String get levelsTitle => 'Levels';

  @override
  String get deviceLabel => 'Output device';

  @override
  String get peakLabel => 'Peak';

  @override
  String get themeSwitchTip => 'Cycle color scheme';

  @override
  String get heroHintProcessing =>
      'Audio is flowing through the chain — changes apply instantly';

  @override
  String get heroHintIdle => 'Pick a source below to start processing';

  @override
  String get reverbAutoQuality =>
      'Switched to Quality latency mode to enable reverb';

  @override
  String get reverbAutoQualityHint =>
      'Selecting a preset auto-switches to Quality mode (reverb is a T2 effect)';

  @override
  String get stereoWidenHint =>
      'Widening capped at 75%: higher ratios strip the center image (karaoke effect) and can silence the mix';

  @override
  String get railCollapseTip => 'Collapse sidebar';

  @override
  String get railExpandTip => 'Expand sidebar';

  @override
  String get navLiveprog => 'Scripts';

  @override
  String get pageLiveprogEyebrow => 'Live Coding';

  @override
  String get pageLiveprogTitle => 'Programmable DSP';

  @override
  String get lpEditor => 'EEL2 Editor';

  @override
  String get lpEditorHint =>
      'Registers spl0/spl1 (L/R samples), srate, slider1..8; @init section needs at least one statement';

  @override
  String get lpApply => 'Apply & compile';

  @override
  String get lpUnload => 'Unload';

  @override
  String get lpNew => 'New template';

  @override
  String get lpCompileOk => 'Compiled — script is running';

  @override
  String get lpNoCode => 'No script loaded (passthrough when enabled)';

  @override
  String get lpSliders => 'Script sliders (slider1..8)';

  @override
  String get lpSliderHint =>
      'Range -1..+4; meaning is defined by the script; changes apply live';

  @override
  String get lpLibrary => 'Script library (%APPDATA%/AuraDSP/liveprog)';

  @override
  String get lpLibraryEmpty =>
      'Library is empty — save current code with the name field below';

  @override
  String get lpSave => 'Save to library';
}
