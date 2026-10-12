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
  String get stereoWiden => 'Stereo Expansion';

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
  String get stereoWidenHint =>
      'Expansion is safely capped: extreme widening strips the center image (karaoke effect) and hollows the mix';

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
  String get lpStatusOk => 'Running';

  @override
  String get lpStatusIdle => 'Not loaded';

  @override
  String get lpStatusError => 'Compile failed';

  @override
  String get lpErrInitMissing => 'Missing @init section';

  @override
  String get lpErrInitSyntax => 'Syntax error in @init section';

  @override
  String get lpErrSampleMissing => 'Missing @sample section';

  @override
  String get lpErrSampleSyntax => 'Syntax error in @sample section';

  @override
  String get lpBlockedByLint => 'Fix the flagged structural issues first';

  @override
  String get lpCodeMismatch =>
      'Preset was saved with different script code; slider values may not match';

  @override
  String get lpCompiling => 'Compiling…';

  @override
  String lpCompileTook(String t) {
    return 'Last compile took $t';
  }

  @override
  String get lpCompileSlow => 'slow — hammering Apply may stall audio';

  @override
  String lpSkipped(int n) {
    return 'Skipped $n oversized or broken files';
  }

  @override
  String get lpOverwriteTitle => 'Overwrite?';

  @override
  String get lpOverwriteBody => 'A script with this name exists. Overwrite it?';

  @override
  String get lpOverwriteAction => 'Overwrite';

  @override
  String get lpDeleteTitle => 'Delete script';

  @override
  String get lpDeleteBody => 'Delete this script file? This cannot be undone.';

  @override
  String get lpDeleteAction => 'Delete';

  @override
  String get lpRenameTitle => 'Rename script';

  @override
  String get lpOpFailed => 'Operation failed, please retry';

  @override
  String get lpSliders => 'Script sliders (slider1..8)';

  @override
  String get lpSliderHint =>
      'Declared range wins; 0..1 when undeclared; changes apply live';

  @override
  String get lpLibrary => 'Script library (%APPDATA%/AuraDSP/liveprog)';

  @override
  String get lpLibraryEmpty =>
      'Library is empty — save current code with the name field below';

  @override
  String get lpSave => 'Save to library';

  @override
  String get convTitle => 'Impulse Response';

  @override
  String get convOpenIr => 'Open IR file';

  @override
  String get convClear => 'Clear IR';

  @override
  String get convNoIr =>
      'No IR loaded (WAV / FLAC; sniffed, size-capped, sanity-checked)';

  @override
  String get convResampled =>
      'Source rate differs from device — resampled automatically';

  @override
  String get fvTitle => 'Parametric Reverb';

  @override
  String get fvDecayLabel => 'Decay';

  @override
  String get fvDampLabel => 'Damping';

  @override
  String get fvWetLabel => 'Wet';

  @override
  String get fvDryLabel => 'Dry';

  @override
  String get presetTitle => 'Presets';

  @override
  String get presetHint =>
      'Save/load full engine parameter snapshots (%APPDATA%/AuraDSP/presets); T2 effects get guard-rejected in Music tier (honest, not silent)';

  @override
  String get presetLoadHint => 'Click to load:';

  @override
  String get presetEmpty =>
      'Library is empty — dial in settings and save with the name field below';

  @override
  String get presetSave => 'Save current';

  @override
  String get presetDelete => 'Delete';

  @override
  String get presetSaved => 'Preset saved';

  @override
  String get presetSaveFail => 'Save failed (invalid name or disk)';

  @override
  String get presetDeleted => 'Preset deleted';

  @override
  String get presetDeleteFail => 'Delete failed';

  @override
  String get presetLoaded => 'Preset loaded';

  @override
  String get presetLoadFail => 'Preset read failed';

  @override
  String get navPlugins => 'Plugins';

  @override
  String get navChain => 'Chain';

  @override
  String get convMix => 'Mix';

  @override
  String get convMixHint =>
      'Dry/wet: 0% = original signal only, 100% = convolution only (default 100%, same as classic IR loading)';

  @override
  String get ddcTitle => 'VDC Spatial Correction';

  @override
  String get ddcOpen => 'Open VDC file';

  @override
  String get ddcNoFile =>
      'No correction file loaded (.vdc: earphone/speaker spatial correction, ViPER DDC compatible)';

  @override
  String get ddcLoaded => 'Loaded';

  @override
  String get ddcClear => 'Clear';

  @override
  String get lpFormat => 'Format';

  @override
  String get convSpectrumTitle => 'IR Frequency Response';

  @override
  String get fv3DTitle => '3D Soundfield Stage';

  @override
  String get advanced => 'Advanced';

  @override
  String get stageTube => 'Tube';

  @override
  String get tubeTitle => 'Tube Simulator';

  @override
  String get spatialReverbTitle => 'Spatial Reverb';

  @override
  String get reverbCustom => 'Custom';

  @override
  String get reverbRoomSize => 'Room Size';

  @override
  String get reverbStereoWidth => 'Stereo Width';

  @override
  String get reverbMix => 'Wet/Dry Mix';

  @override
  String get eqMultiBand => 'Multi-Band Equalizer';

  @override
  String eqBands(int n) {
    return '$n bands';
  }

  @override
  String get eqPresets => 'Presets';

  @override
  String get eqFlat => 'Flat Reset';

  @override
  String get eqBypass => 'Bypass';

  @override
  String get eqQFactor => 'Q-Factor';

  @override
  String get eqFilterType => 'Filter Architecture';

  @override
  String get eqInterpolation => 'Interpolation';

  @override
  String get bassIntensity => 'Bass Intensity';

  @override
  String get bassMode => 'Bass Mode';

  @override
  String get bassModeDynamic => 'Dynamic (DBB)';

  @override
  String get bassModeShelf => 'Hi-Fi Shelf';

  @override
  String get bassModeHarmonic => 'Harmonic Exciter';

  @override
  String get bassCutoff => 'Cutoff Scope';

  @override
  String get bassHarmonics => 'Harmonics';

  @override
  String get bassBlend => 'Harmonic Blend';

  @override
  String get bassSubFloor => 'Sub Floor';

  @override
  String get tubeDrive => 'Drive / Saturation';

  @override
  String get tubeStyle => 'Tube Style';

  @override
  String get tubeStyleTriode => 'Triode 12AX7';

  @override
  String get tubeStylePentode => 'Pentode EL34';

  @override
  String get tubeStyleTape => 'Tape Warmth';

  @override
  String get tubeOversampling => 'Oversampling';

  @override
  String get tubeCompensation => 'Output Compensation';

  @override
  String get tubeMix => 'Dry/Wet Mix';

  @override
  String get dlgCancel => 'Cancel';

  @override
  String get dlgAdd => 'Add';

  @override
  String get dlgSave => 'Save';

  @override
  String get dlgLoad => 'Load';

  @override
  String get dlgClose => 'Close';

  @override
  String get dlgUnload => 'Unload';

  @override
  String get dlgPreset => 'Preset';

  @override
  String get memTitle => 'Persistent Memory & External Config';

  @override
  String get memHint =>
      'Automatically records all effect settings and restores them seamlessly on next launch.';

  @override
  String get memAutoRestore => 'Auto-save and restore session on exit';

  @override
  String memDir(String path) {
    return 'Config directory: $path';
  }

  @override
  String get memClear => 'Clear Session Memory';

  @override
  String get memCleared =>
      'Persistent session memory cleared; next launch starts from clean defaults';

  @override
  String get memReset => 'Reset External Config to Defaults';

  @override
  String get memResetDone =>
      'config.json has been reset to the standard template';

  @override
  String get latUnmeasured => 'Unmeasured';

  @override
  String latTipMeasured(String text) {
    return 'Component latency (impulse-response measured): $text\nTap ↻ to re-measure (tens of ms, playback unaffected)';
  }

  @override
  String get latTipProbing => 'Measuring component latency…';

  @override
  String get latTipUnmeasured =>
      'Component latency not measured yet\nTap ↻ for one impulse-response measurement (tens of ms)';

  @override
  String get eqCanvasHint =>
      'Drag vertically for gain · double-tap a node to zero 0dB · double-tap background to flatten';

  @override
  String get eqBypassOn => 'Bypass active';

  @override
  String get eqFilterMinphase => 'Minimum-phase FIR';

  @override
  String get eqFilterIir6 => '6th-order IIR';

  @override
  String get eqFilterIir12 => '12th-order IIR';

  @override
  String get eqInterpMakima => 'Makima (smooth, overshoot-free)';

  @override
  String get eqInterpPchip => 'PCHIP (monotone shape-preserving)';

  @override
  String get eqPresetFlat => 'Flat';

  @override
  String get eqPresetPop => 'Pop';

  @override
  String get eqPresetRock => 'Rock';

  @override
  String get eqPresetJazz => 'Jazz';

  @override
  String get eqPresetClassical => 'Classical';

  @override
  String get eqPresetVocal => 'Vocal Boost';

  @override
  String get eqPresetSmile => 'Smile (V-Shape)';

  @override
  String get eqPresetBass => 'Bass Boost';

  @override
  String get eqPresetTreble => 'Treble Clarity';

  @override
  String get eqPresetCustom => 'Custom';

  @override
  String get eqPresetPick => 'Pick an EQ style preset';

  @override
  String get eqQTip =>
      'Q-Factor filter sharpness (0.3 - 10.0)\nDrag vertically · double-tap to reset 1.41';

  @override
  String get stTube => 'Tube';

  @override
  String get stComp => 'Limiter';

  @override
  String get stBass => 'Bass Boost';

  @override
  String get stEq => 'Equalizer';

  @override
  String get stArbmag => 'Arbitrary-response EQ';

  @override
  String get stConv => 'Impulse Response';

  @override
  String get stScript => 'Script';

  @override
  String get stXfeed => 'Crossfeed';

  @override
  String get stStereo => 'Stereo Widening';

  @override
  String get stReverb => 'Reverb';

  @override
  String get stOutput => 'Output Stage';

  @override
  String get chainTitle => 'Processing Chain';

  @override
  String get chainOrderTitle => 'Order & Status';

  @override
  String get chainOrderHint =>
      'Drag to reorder processing (top-down); tap \"Apply\" when changed. Each node can be bypassed/enabled independently; per-node live stereo meters on the right.';

  @override
  String get chainApply => 'Apply Order';

  @override
  String get chainReset => 'Reset to Defaults';

  @override
  String get chainReserved => 'Reserved';

  @override
  String get chainFlowTitle => 'Signal Flow (Current Order)';

  @override
  String get chainFlowCaption => 'Global signal-flow overview (left to right):';

  @override
  String get chainNodeInput => 'Input Gate';

  @override
  String get chainNodeShelf => 'Low-shelf EQ';

  @override
  String get chainNodeVendor => '12-stage internal DSP chain';

  @override
  String get chainNodeReverb => 'Reverb & Soundstage';

  @override
  String get chainNodeLimiter => 'Main Limiter';

  @override
  String get chainNodeOutputGate => 'Output Gate';

  @override
  String get chainNodeOutput => 'Audio Output';

  @override
  String get inputGate => 'Input Gate';

  @override
  String get inputGain => 'Master Input Gain';

  @override
  String get channelBalance => 'Channel Balance';

  @override
  String get channelBalanceHint =>
      'Per-channel independent level scaling. Final channel volume = master input gain × individual balance.';

  @override
  String get channelLeft => 'Left Channel (L)';

  @override
  String get channelRight => 'Right Channel (R)';

  @override
  String get inputStageIn => 'Stage In';

  @override
  String get inputStageOut => 'Stage Out';

  @override
  String get chainStagePreDsp => 'Pre-DSP';

  @override
  String get chainStagePreVendor => 'Pre-Vendor';

  @override
  String get chainStagePostVendor => 'Post-Vendor';

  @override
  String get chainStagePostReverb => 'Post-Reverb';

  @override
  String get chainStagePostLimiter => 'Post-Limiter';

  @override
  String chainSlotActive(int n, String name, String fmt) {
    return 'Slot $n: $name ($fmt)';
  }

  @override
  String chainSlotEmpty(int n) {
    return 'Slot $n: no plugin loaded';
  }

  @override
  String get chainSlotBypassed => 'Bypassed (thru)';

  @override
  String get chainSlotProcessing => 'Processing';

  @override
  String chainSlotStatusLine(String a, int b) {
    return 'Status: $a • latency: $b samples';
  }

  @override
  String get chainSlotHint =>
      'Pick an effect on the Plugins page to load into this slot';

  @override
  String get chainOpenGui => 'Open Native UI (GUI)';

  @override
  String get chainBypassed => 'Bypassed';

  @override
  String get chainEnable => 'Enable';

  @override
  String lpSaved(String name) {
    return 'Saved: $name.eel';
  }

  @override
  String get lpAddDirTitle => 'Add External Script Preset Folder';

  @override
  String get lpAddDirPrompt =>
      'Enter the full folder path containing .eel / .txt script presets:';

  @override
  String get lpAddDirExample => 'E.g.: D:\\AudioScripts\\EelPresets';

  @override
  String lpChars(int n) {
    return '$n chars';
  }

  @override
  String get lpReady => 'Syntax OK';

  @override
  String lpIssues(int n) {
    return '$n potential problems';
  }

  @override
  String lpIssueAt(int line, String msg) {
    return 'Line $line: $msg';
  }

  @override
  String get lpShowAll => 'All 8 slots';

  @override
  String lpAdaptive(int n) {
    return 'Adaptive ($n)';
  }

  @override
  String get lpNoSliders =>
      'Current code declares no slider1..8 params (pure algorithmic processing)';

  @override
  String get lpExpandSliders => 'Expand all 8 sliders';

  @override
  String get lpAddDir => 'Add External Folder';

  @override
  String get lpSlidersHint =>
      'Sliders adapt to the slider params declared/referenced by the current script; tap top-right to switch mode.';

  @override
  String get lpLibraryHint =>
      'Supports the local %APPDATA% library plus auto-indexed external preset folders.';

  @override
  String get convIrTitle => 'Impulse Response (IR)';

  @override
  String convFramesLine(int frames, String dur, int ch, String peak, int rate) {
    return '$frames frames · $dur · ${ch}ch · peak $peak dBFS · src ${rate}Hz';
  }

  @override
  String get ddcFilterTitle => 'VDC Filter';

  @override
  String get stereoBandActive => 'Per-band active';

  @override
  String get stBand0 => 'Low';

  @override
  String get stBand1 => 'Low-Mid';

  @override
  String get stBand2 => 'Mid';

  @override
  String get stBand3 => 'High-Mid';

  @override
  String get stBand4 => 'High';

  @override
  String get stBandHint =>
      'Per-band fine tuning: individual band amounts scale dynamically with the master expansion slider above';

  @override
  String get presetFactoryTitle => 'Factory tuning presets';

  @override
  String get presetUserTitle => 'My custom presets';

  @override
  String get presetUserEmpty =>
      'No custom presets yet — save below after tuning';

  @override
  String presetLoadedFactory(String name) {
    return 'Loaded factory preset: $name';
  }

  @override
  String presetLoadedUser(String name) {
    return 'Loaded custom preset: $name';
  }

  @override
  String get presetSaveHint =>
      'Enter a name to save current state as a user preset';

  @override
  String get convSpectrumCaption => '32 bands · 0..1 normalized energy';

  @override
  String get sliderResetTip => 'Click to reset to default';

  @override
  String get plugAddDirTitle => 'Add Plugin Search Folder';

  @override
  String get plugAddDirPrompt =>
      'Enter or paste the full folder path containing 64-bit VST3 / CLAP effects:';

  @override
  String get plugAddDirExample => 'E.g.: D:\\AudioPlugins\\VST3';

  @override
  String get plugAddScan => 'Add & Scan';

  @override
  String plugPresetTitle(String name) {
    return 'Plugin presets — $name';
  }

  @override
  String get plugPresetSaveLabel => 'Save current parameter state';

  @override
  String get plugPresetNameHint => 'Enter a new preset name...';

  @override
  String plugPresetList(int n) {
    return 'Saved presets ($n)';
  }

  @override
  String get plugPresetEmpty =>
      'No saved presets yet; save via the input above.';

  @override
  String get plugTitle => 'Plugin Center';

  @override
  String get plugLibTitle => 'Third-party Effect Library';

  @override
  String get plugLibHint =>
      'Scans and manages system-standard 64-bit VST3 / CLAP folders plus custom folders. Zero-latency and lookahead compensation, stereo-plane RT-Safe.';

  @override
  String get plugDeepScan => 'Deep scan';

  @override
  String get plugScan => 'Scan';

  @override
  String get plugScanning => 'Scanning...';

  @override
  String get plugScanPreparing => 'Enumerating plugin folders…';

  @override
  String plugScanProgressCount(int done, int total, int found) {
    return 'Scanned $done/$total · $found plugins found';
  }

  @override
  String get plugScanNoVerify =>
      'Quick scan never loads plugins: metadata only, verified on mount';

  @override
  String get plugOpenFolder => 'Open Standard VST3 Folder';

  @override
  String get plugSearchHint => 'Search plugin name, vendor or path...';

  @override
  String get plugM1Title => 'M1 Plugin Host Engine Spec';

  @override
  String get plugM1Hint =>
      'Multi-format in-process host with 64-bit VST3 and CLAP support.';

  @override
  String get plugFeatSlots =>
      'Quad slots (Slot 1 ~ Slot 4) managed independently & concurrently';

  @override
  String get plugFeatStages =>
      'Full-chain stage insertion (Pre-DSP ~ Post-Limiter)';

  @override
  String get plugFeatGui =>
      'Native Win32 GUI popups on a dedicated message loop';

  @override
  String get plugFeatPreset => 'Binary-stream preset save & instant restore';

  @override
  String get plugFeatDirs =>
      'Custom plugin folder search & local state snapshots';

  @override
  String get plugFeatRt => 'Flat stereo RT-Safe preallocation, zero locks';

  @override
  String plugSlot(int n) {
    return 'Slot $n (Slot $n)';
  }

  @override
  String get plugBypassed => 'Bypassed';

  @override
  String get plugCustomTitle => 'Custom Plugin Search Folders';

  @override
  String get plugCustomHint =>
      'Add VST3/CLAP paths from other drives or your DAW; they merge into scans automatically.';

  @override
  String get plugCustomAdd => 'Add Folder';

  @override
  String get plugCustomEmpty =>
      'No custom folders yet. Besides system defaults (C:\\Program Files\\Common Files\\VST3 etc.), add via top-right.';

  @override
  String plugMountTitle(int n) {
    return 'Mount Status (Slot $n)';
  }

  @override
  String plugMountEmpty(int n) {
    return 'Slot $n has no third-party plugin loaded';
  }

  @override
  String get plugMountEmptyHint =>
      'Pick an installed VST3 / CLAP plugin from the library list below to load';

  @override
  String get plugScanNow => 'Scan Installed Plugins Now';

  @override
  String plugMountedTitle(int n) {
    return 'Currently Loaded Plugin (Slot $n)';
  }

  @override
  String plugMountedTitleNamed(int n, String name) {
    return 'Currently Loaded Plugin (Slot $n): $name';
  }

  @override
  String plugEditorTitleNamed(int n, String name) {
    return '$name (Slot $n)';
  }

  @override
  String get plugOpenGuiBtn => 'Open UI (GUI)';

  @override
  String get plugUnloadFromSlot => 'Unload from This Slot';

  @override
  String plugLoadToSlot(int n) {
    return 'Load into Slot $n';
  }

  @override
  String get plugLatencyLabel => 'Measured Audio Latency';

  @override
  String get plugStageLabel => 'Signal-chain insert stage:';

  @override
  String get plugRtNote => 'Live serial chaining • RT-Safe contract kept';

  @override
  String get plugFilterAll => 'All';

  @override
  String get plugNoPlugins => 'No third-party plugins detected';

  @override
  String get plugNoPluginsHint =>
      'Make sure plugins live in system VST3 / CLAP paths, or add a custom folder above and rescan';

  @override
  String get plugNoMatch => 'No plugins match the current search/filter';

  @override
  String get plugIncompatibleBadge => '32-bit incompatible';

  @override
  String get plugIncompatibleHint =>
      'This is a 32-bit plugin. AuraDSP is a 64-bit host and cannot load it; please install the 64-bit version.';

  @override
  String plugSlotActive(int n) {
    return 'Slot $n active';
  }

  @override
  String plugSlotLoaded(int n) {
    return 'Slot $n loaded';
  }

  @override
  String get plugUnknownVendor => 'Unknown vendor';

  @override
  String get plugThirdParty => 'Third-party plugin';

  @override
  String plugSlotPluginLine(String name, String stage) {
    return '$name • [$stage]';
  }

  @override
  String get plugSlotNoFx => 'No effect loaded';

  @override
  String get chainActive => 'Active';

  @override
  String get chainBypass => 'Bypass';

  @override
  String get plugActive => 'Active';

  @override
  String get lpSaveFailed => 'Save failed (bad name or unwritable disk)';

  @override
  String get chainVstTitle =>
      'Third-party VST / CLAP Plugin Slots & Stage Order';

  @override
  String get chainVstHint =>
      'Mount multiple slots in parallel; set each plugin\'s insert stage and order on the global chain below.';
}
