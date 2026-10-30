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
  String get stateIdle => 'Idle';

  @override
  String get routingChFl => 'Front Left';

  @override
  String get routingChFr => 'Front Right';

  @override
  String get routingChC => 'Center';

  @override
  String get routingChLfe => 'Subwoofer';

  @override
  String get routingChSl => 'Surround L';

  @override
  String get routingChSr => 'Surround R';

  @override
  String get routingChBl => 'Back L';

  @override
  String get routingChBr => 'Back R';

  @override
  String get routingAllChannels => 'All Channels (8/8)';

  @override
  String get routingStereo => 'Stereo (FL/FR)';

  @override
  String get routingNoSub => 'No Sub (7/8)';

  @override
  String get routingAllBypassed => 'All Bypassed (0/8)';

  @override
  String get routingSurroundOnly => 'Surround Only (4/8)';

  @override
  String get routingPairHint =>
      'Applied per stereo pair: FL/FR, C/LFE, SL/SR and BL/BR toggle together; a single channel has no effect';

  @override
  String routingSelectedCount(int count, int total) {
    return '$count/$total Selected';
  }

  @override
  String get routingStereoPathSummary => 'Direct (Stereo/Matrix Path)';

  @override
  String get routingStereoPathHint =>
      'Current path is stereo or matrix downmix; all channels are processed together and channel masks are inactive.';

  @override
  String get flfrOnlyHint =>
      'Applies to the front FL/FR pair only (surrounds and LFE pass through in discrete multichannel)';

  @override
  String get channelRouting => 'Channel Routing';

  @override
  String get routingPresets => 'Presets:';

  @override
  String get routingPresetAll => 'All';

  @override
  String get routingPresetFront => 'Front Only';

  @override
  String get routingPresetBack => 'Back Only';

  @override
  String get routingPresetStereo => 'Stereo';

  @override
  String get routingPresetNoLfe => 'No LFE';

  @override
  String get routingPresetSurround => 'Surround';

  @override
  String get channelCount => 'Channel Count';

  @override
  String get channelCountHint =>
      'Working channel topology. Auto negotiates with source and device; or manually lock to 2.0 / 4.0 / 5.1 / 7.1.';

  @override
  String get channelCountAuto => 'Auto';

  @override
  String channelCountAutoDesc(int count) {
    return 'Auto negotiation active · Current topology: $count ch';
  }

  @override
  String get setConnStatus => 'Connection';

  @override
  String get setConnActive => 'Connected (active callback)';

  @override
  String get setConnIdle => 'Not connected (waiting for Voicemeeter)';

  @override
  String get setDeviceDisconnected => 'Device not connected';

  @override
  String get setEndpointShort => 'Endpoint';

  @override
  String setEndpointWithId(String shortId) {
    return 'Audio endpoint ($shortId)';
  }

  @override
  String setOfflineSuffix(String name) {
    return '$name [offline/not connected]';
  }

  @override
  String get setDefaultEndpoint => 'Default audio endpoint (Default Render)';

  @override
  String get setNoEndpoint => 'No audio endpoint available';

  @override
  String setApoActive(int sr, int frames) {
    return 'Active ($sr Hz · $frames frames)';
  }

  @override
  String get setApoAttached => 'Attached (waiting for playback stream)';

  @override
  String get setProcessing => 'Processing...';

  @override
  String get setApoRegistered =>
      'System APO hook registered on the target device; service synced';

  @override
  String get setApoAttachFailed => 'APO attach incomplete';

  @override
  String get setApoUnregistered =>
      'APO hook safely removed; original audio drivers restored';

  @override
  String get setApoUnregisterFailed => 'APO uninstall incomplete';

  @override
  String get setCompositeSlot => 'Composite slot';

  @override
  String get setRefreshStatus => 'Refresh status';

  @override
  String get setApoSafetyNote =>
      'Registry safety: all changes are atomically protected via HKLM\\SOFTWARE\\AuraDSP\\Child APOs plus a dual-layer disk snapshot; the original driver config is 100% restored on uninstall.';

  @override
  String setDriverOffline(String name) {
    return '$name [not detected/offline]';
  }

  @override
  String get setVaioReady =>
      'AuraVAIO KMDF driver ready (Sysvad virtual sound card)';

  @override
  String get setVaioMissing =>
      'AuraVAIO virtual sound card driver not detected';

  @override
  String get setVaioDesc =>
      'KMDF kernel-mode virtual audio driver providing a full-duplex virtual audio cable';

  @override
  String get setInstallDriverUac => 'Install driver (UAC)';

  @override
  String get setInstallDriverUacPrompt =>
      'Requesting administrator permission; please approve the system prompt to install audio driver components...';

  @override
  String get setVaioInstallOk =>
      'AuraVAIO driver installed and verified successfully!';

  @override
  String get setDriverInstallFailed => 'Driver installation incomplete';

  @override
  String get setUninstallDriver => 'Uninstall driver';

  @override
  String get setVaioUninstallOk => 'AuraVAIO driver uninstalled successfully';

  @override
  String get setDriverUninstallFailed => 'Uninstall incomplete';

  @override
  String get setRedetect => 'Re-detect';

  @override
  String get setWasapiDesc =>
      'System-level WASAPI shared/exclusive audio engine; no extra driver required';

  @override
  String get setRefreshDevice => 'Refresh devices';

  @override
  String get setAsioRegisterUac => 'Register driver (UAC)';

  @override
  String get setAsioRegisterPrompt =>
      'Requesting administrator permission to register virtual audio driver components...';

  @override
  String get setAsioRegisterOk =>
      'Virtual ASIO driver registered — now selectable in your DAW!';

  @override
  String get setAsioRegisterFailed =>
      'Registration failed; retry with administrator privileges';

  @override
  String get setAsioUnregisterOk => 'Virtual ASIO driver unregistered';

  @override
  String get setAsioUnregisterFailed =>
      'Unregister failed; retry with administrator privileges';

  @override
  String get gateHintThreshold =>
      'Background noise below this level is attenuated. Too high eats quiet tails; too low and the gate barely acts.';

  @override
  String get gateHysteresis => 'Hysteresis';

  @override
  String get gateHintHysteresis =>
      'Level gap between opening and closing; prevents chatter at the threshold so the gate stays stable through vocal dynamics.';

  @override
  String get gateRange => 'Range';

  @override
  String get gateHintRange =>
      'Maximum attenuation when fully closed. -60 dB is silence; -12…-24 dB keeps natural ambience and avoids a digital-dead feel.';

  @override
  String get gateHold => 'Hold';

  @override
  String get gateHintHold =>
      'Milliseconds to stay fully open after the signal drops below the close threshold; avoids cutting pauses or drum tails.';

  @override
  String get gateHintAttack =>
      'How fast the gate opens after crossing the open threshold. Too slow eats attacks; too fast can click.';

  @override
  String get gateHintRelease =>
      'Time to close smoothly to the range floor after hold; longer values give a more natural fade.';

  @override
  String get gateHintSidechain =>
      'Sidechain de-esser plus automatic loudness compensation for the gate output.';

  @override
  String get gateHintDeess =>
      'Dynamically tames sibilance (s/sh/ch) while keeping low-end body.';

  @override
  String get gateHintDeessFreq =>
      'Sidechain band used to detect sibilance. Heavy sibilance → lower; dull → higher.';

  @override
  String get gateHintDeessAmount =>
      'Sibilance reduction strength; only the high band is attenuated.';

  @override
  String get gateHintAutoGain =>
      'Compensates the level drop caused by gating in real time.';

  @override
  String get compThreshold => 'Threshold';

  @override
  String get compHintThreshold =>
      'Level where compression starts. Audio below stays untouched; above is reduced proportionally, taming harsh transients.';

  @override
  String get compRatio => 'Ratio';

  @override
  String get compHintRatio =>
      'Steepness of gain reduction above threshold. Higher = stronger (10:1 approaches limiting); lower = gentler, more open dynamics.';

  @override
  String get compHintRelease =>
      'Release time for compression and envelope tracking. Short = punchier transients; long = smoother, more transparent.';

  @override
  String get compHintBandwidth =>
      'Frequency-analysis resolution. Coarse responds fastest (electronic/pop); precise separates bands better (vocals, instruments).';

  @override
  String get compHintTiming =>
      'Filter time-constant strategy. Transient keeps micro-dynamics; Balanced is general purpose; Zero-latency adds no buffering delay.';

  @override
  String get compBandsTitle => 'Per-band dynamics trim (7 bands)';

  @override
  String get compHintBands =>
      'Customize center frequency and compression/expansion per band (negative = compress, positive = expand).';

  @override
  String get bandSub => 'Sub';

  @override
  String get bandLow => 'Low';

  @override
  String get bandLowMid => 'Low-mid';

  @override
  String get bandMid => 'Mid';

  @override
  String get bandHighMid => 'High-mid';

  @override
  String get bandHigh => 'High';

  @override
  String get bandUltra => 'Ultra-high';

  @override
  String get compBandFreq => 'Center frequency';

  @override
  String get compBandAmount => 'Compress / expand';

  @override
  String get compHintBandAmount =>
      'Negative compresses, positive expands. Default -0.35.';

  @override
  String get eelUnclosedString => 'Unclosed string (spans lines)';

  @override
  String eelUnmatchedClose(String ch) {
    return 'Unexpected \"$ch\" (no matching opener)';
  }

  @override
  String get eelBlockCommentUnclosed => 'Block comment not closed (missing */)';

  @override
  String eelUnclosedQuote(String ch, int line, int col) {
    return '\"$ch\" not closed (started at line $line, col $col)';
  }

  @override
  String get eelMissingInit =>
      'Missing @init section (engine will refuse to compile)';

  @override
  String get eelMissingSample =>
      'Missing @sample section (engine will refuse to compile)';

  @override
  String get eelEmptyInit =>
      'Empty @init section (@init requires at least one statement or variable initialization)';

  @override
  String get eelEmptySample =>
      'Empty @sample section (output will be silent) — sure this is intended?';

  @override
  String eelSliderRange(int n) {
    return 'slider$n out of range (only slider1..8 map to UI sliders)';
  }

  @override
  String eelReadonlyAssign(String name) {
    return '$name is read-only; assignment has no effect';
  }

  @override
  String get lpDocIntro =>
      'EEL2 is a high-performance expression language for real-time audio. In AuraDSP every script runs instantly on the audio pump thread.';

  @override
  String get lpDocSectionsTitle => 'Core sections';

  @override
  String get lpDocSampleCode =>
      '@init\n// Runs on sample-rate change or first load; init variables & coefficients\n\n@sample\n// Runs per sample. IO vars are spl0 (L) and spl1 (R)\nspl0 = spl0 * 0.5;\nspl1 = spl1 * 0.5;';

  @override
  String get lpDocSlidersTitle => 'Slider syntax';

  @override
  String get lpDocSampleSlider =>
      'slider1: 0< -12, 12, 0.5 > Gain (dB)\n// sliderN: default< min, max, step > label\n// The host auto-generates live sliders for these!';

  @override
  String get lpDocBuiltinsTitle => 'Common built-in constants & functions';

  @override
  String get lpDocBuiltinConsts =>
      '• Constants: srate (sample rate), \$pi (pi)\n';

  @override
  String get lpDocBuiltinFns =>
      '• Functions: sin, cos, tan, sqrt, exp, log, abs, min, max, rand, floor, ceil\n';

  @override
  String get lpDocBuiltinChannels =>
      '• Channels: spl0 (L in/out), spl1 (R in/out)';

  @override
  String get ioNoInputDevices => 'No input devices available';

  @override
  String get ioRefreshDevice => 'Refresh devices';

  @override
  String get ioLoopbackDesc =>
      'Default loopback mode: captures the system main playback endpoint in real time';

  @override
  String get ioExclusiveDesc =>
      'Low-latency WASAPI exclusive/shared capture from the selected hardware/virtual port';

  @override
  String get ioInputLabel => 'Input endpoint';

  @override
  String get ioVaioEndpointDesc =>
      'AuraVAIO virtual input endpoint (Stereo / 7.1 ch)';

  @override
  String get ioChannelStatus => 'Channel status';

  @override
  String get ioVaioActive => 'Active (full-duplex DMA ring buffer)';

  @override
  String get ioVaioReady => 'Ready (waiting for system/app stream)';

  @override
  String get ioVaioGuide =>
      'In system sound settings or your media player, select \"AuraVAIO\" as the default output device to route audio through AuraDSP.';

  @override
  String get ioAsioChannelLabel => 'Input channels';

  @override
  String get ioAsioActive => 'DAW live injection (active)';

  @override
  String get ioAsioWait => 'Waiting for DAW connection (host off)';

  @override
  String get ioAsioGuide =>
      'In your DAW (FL Studio / Cubase / Reaper / Ableton) select \"AuraDSP Virtual ASIO\" as Audio Device to route project audio here.';

  @override
  String get ioWasapiRenderDesc =>
      'WASAPI physical render (speakers/headphones)';

  @override
  String get ioNoOutputDevices => 'No output devices available';

  @override
  String get ioPhysicalOutput => 'Physical output';

  @override
  String get ioAutoSelect => 'Auto select (non-VAIO speaker)';

  @override
  String get ioNoPhysicalOutputs => 'No physical output devices available';

  @override
  String get ioProcessedFrames => 'Frames processed';

  @override
  String get ioOutputLabel => 'Output endpoint';

  @override
  String get ioAsioHwOutput => 'AuraDSP ASIO Client hardware output';

  @override
  String get ioChannelMap => 'Channel mapping';

  @override
  String ioChannelPair(int p1, int p2) {
    return 'Channel $p1 / $p2';
  }

  @override
  String get ioOutputStatus => 'Output status';

  @override
  String get ioAsioPassthrough =>
      'Hardware passthrough monitoring (ultra-low latency)';

  @override
  String get ioAsioReadyStatus => 'Ready (waiting for driver session)';

  @override
  String get catInput => 'Input';

  @override
  String get catTone => 'Tone';

  @override
  String get catEq => 'EQ';

  @override
  String get catStage => 'Field';

  @override
  String get catSpace => 'Spatial Effects';

  @override
  String get catStereo => 'Stereo';

  @override
  String get catOutput => 'Output';

  @override
  String get catEffect => 'FX';

  @override
  String get arbmagMinPoints =>
      'Need at least 2 valid points (freq gain dB; …)';

  @override
  String arbmagGraphicEqInvalid(String err) {
    return 'Invalid GraphicEQ: $err';
  }

  @override
  String arbmagReadFailed(String err) {
    return 'Failed to read file: $err';
  }

  @override
  String arbmagPoints(int n) {
    return '$n points';
  }

  @override
  String arbmagNodes(int count) {
    return '$count nodes loaded';
  }

  @override
  String get bassHintIntensity =>
      'Adds low-end weight and punch. Higher = deeper bass; raise moderately to avoid boomy highs.';

  @override
  String get bassHintFrequency =>
      'Upper limit of the bass boost. Audio below it is thickened; 60–120 Hz is a good range.';

  @override
  String get bassShelfRouting => 'Low-shelf channel routing';

  @override
  String get irEnvelope => 'Impulse envelope';

  @override
  String get irMirrorR => 'R (mirrored)';

  @override
  String get convHintMix =>
      'Convolution reverb mix. 0% is dry; 100% fully immerses in the sampled space.';

  @override
  String get xfHintPreset =>
      'Switch between classic headphone crossfeed presets or custom tuning; removes the in-head effect for natural speaker staging.';

  @override
  String get xfHintCustom =>
      'Fine-tune the crossfeed low-pass cutoff and feed level.';

  @override
  String get xfHintCutoff =>
      'Crossfeed low-pass cutoff (300–2000 Hz). Higher = wider band fed to the opposite channel.';

  @override
  String get xfHintFeed =>
      'Low-band crossfeed attenuation (1.0–15.0 dB). Lower = more feed, wider stage; higher = subtler crossfeed.';

  @override
  String get dqHintAttack =>
      'How fast a band compresses after crossing threshold. Too slow eats transients; too fast can click.';

  @override
  String get dqHintRelease =>
      'How fast the band releases after dropping below threshold. Too short pumps; too long holds.';

  @override
  String get dqShapeNote => 'Mid is a bell shape; Low/High use shelf slopes.';

  @override
  String get dqHintStaticGain =>
      'Static base gain, always active; the dynamic part only attenuates.';

  @override
  String get dqHintRange =>
      'Maximum extra attenuation once over threshold. 0 = pure static shaping.';

  @override
  String get dqHintThreshold =>
      'Band envelope level where dynamic attenuation starts. Too low over-triggers; too high never acts.';

  @override
  String get dqIndepTiming => 'Independent dynamic timing';

  @override
  String get dqHintBandAttack => 'Attack time dedicated to this band.';

  @override
  String get dqHintBandRelease => 'Release time dedicated to this band.';

  @override
  String get filterHintModes =>
      'HP cuts below, LP cuts above, BP passes centered on this frequency.';

  @override
  String get filterHintResonance =>
      'Resonance strength. It sets BP bandwidth; HP/LP only peak at the corner.';

  @override
  String get haasHintDelay =>
      'Delayed side 0–25 ms (Haas offset). ~12 ms widens the stage; beyond that it becomes echo.';

  @override
  String get haasHintWet =>
      'Wet (delayed difference) ratio. Lower keeps vocals centered; mono devices stay compatible.';

  @override
  String inputGainTip(String label, String gain) {
    return '$label: $gain dB\ndrag to fine-tune · double-click to reset';
  }

  @override
  String get inputReset100 => 'Reset 100%';

  @override
  String inputFinal(String desc) {
    return 'Final: $desc';
  }

  @override
  String get inputResetHint => 'Double-click or tap to restore 100%';

  @override
  String get loudnessHint =>
      'Auto boosts lows and highs at quiet levels, transparent when loud';

  @override
  String get postHintGain =>
      'Global output level trim. Nudge up if the DSP chain leaves things too quiet.';

  @override
  String get postCeiling => 'Ceiling';

  @override
  String get postHintCeiling =>
      'Mastering-grade lookahead ceiling. Transients above it are transparently reduced, preventing clipping and true-peak (ISP) overs.';

  @override
  String get postRelease => 'Release';

  @override
  String get postHintRelease =>
      'Limiter envelope release. Short = tight and punchy; long = smooth without pumping.';

  @override
  String get postLookahead => '1.5 ms lookahead';

  @override
  String get postHintLookahead =>
      '1.5 ms adaptive smoothing lookahead. On = broadcast-grade distortion-free peak control; off = zero-latency esports/monitoring mode.';

  @override
  String get postStereoLink => 'Stereo link';

  @override
  String get postHintStereoLink =>
      'Links both channels, limiting on the louder side to keep the image from wandering on big transients.';

  @override
  String get reverbHintMix =>
      'Reverb level ratio. Higher = more spacious, hall-like ambience.';

  @override
  String get reverbHintSize =>
      'Simulated room size. Larger = wider stage and longer reflection gaps.';

  @override
  String get reverbHintDecay => 'Reverb decay time. Higher = longer tails.';

  @override
  String get reverbHintWidth =>
      'Binaural width of the reverb; wraps echoes around the head.';

  @override
  String get reverbHintDamp =>
      'High-frequency damping. Higher = warmer; lower = brighter.';

  @override
  String get reverbHintDry =>
      'Dry signal retention; keeps vocals articulate and solid.';

  @override
  String get reverbHintWidthMc =>
      'Multichannel FDN width: only FL/FR, SL/SR and BL/BR are widened; C and LFE stay untouched.';

  @override
  String get reverbEngineLabel => 'Engine';

  @override
  String get reverbEngineStereo => 'Stereo';

  @override
  String get reverbEngineMc => 'Multichannel FDN';

  @override
  String get reverbEngineOff => 'Off';

  @override
  String get reverbEngineInfo =>
      'Reverb automatically adapts to the channel topology: stereo and binaural paths use classic dual-channel diffusion reverb, while discrete multichannel configurations engage an 8-delay-line Feedback Delay Network (FDN).';

  @override
  String get reverbLfe => 'LFE into reverb';

  @override
  String get reverbLfeInfo =>
      'Sends LFE through a 120 Hz low-pass at -6 dB into the multichannel reverb; the wet return is low-passed again. Ignored on the stereo path.';

  @override
  String get reverbPredelay => 'Pre-delay';

  @override
  String get reverbPredelayInfo =>
      'Delay before the reverb (0–100 ms), added to the preset\'s base pre-delay; custom mode starts from 0.';

  @override
  String reverbLegacyPreset(int id) {
    return 'Legacy preset $id';
  }

  @override
  String get spatialHintRoom =>
      'Simulated room reflection volume. Higher = deeper, grander space with fuller tails.';

  @override
  String get spatialHintWidth =>
      'Widens the binaural spread and virtual speaker spacing; moderate settings keep the sound full.';

  @override
  String get spatialHintFocus =>
      'Controls center-vocal focus. Moderate boost keeps vocals centered and clear above the surrounds.';

  @override
  String get spatialHintGain =>
      'Output gain trim on top of full auto equal-energy normalization (-12…+6 dB).';

  @override
  String get spatialHintLoudness =>
      'Equal-loudness auto balancing. Cancels the energy gain from multi-speaker upmix so sliders never act as volume knobs.';

  @override
  String get stereoHintWidth =>
      'Stretches the stereo image. Moderate stretch = out-of-head speaker feel; too much thins the center.';

  @override
  String get tubeHintColor =>
      'Classic tube even-harmonic saturation; warm, filmic tone that removes digital harshness.';

  @override
  String get tubeHintTrim =>
      'Manual level trim after tube coloration, wet path only. Use it to match loudness when switching modes.';

  @override
  String get tubeTriode => 'TRIODE (even harmonics)';

  @override
  String get tubePentode => 'PENTODE (odd harmonics)';

  @override
  String get tubeTape => 'TAPE (warm tape)';

  @override
  String get noAvailableDevice => 'No device available';

  @override
  String get vbBuses => 'VB buses (off=passthrough)';

  @override
  String get vbPluginTooltip =>
      'Checked: mounted plugins process this bus (built-in DSP effects unaffected)';

  @override
  String get vbPluginLockedHint =>
      'Plugins do not run while bus processing is off (state kept; resumes instantly)';

  @override
  String get vbAutoProtect => 'Auto over-budget protection';

  @override
  String get vbProtectHint =>
      'Audio callback deadline is determined by the driver buffer size (e.g. 128 frames @ 48kHz = 2.7ms budget). When DSP callback duration (EMA) continuously exceeds 85% of this budget, heavy plugins are automatically narrowed to the monitored bus to prevent audio dropouts and glitches, restoring automatically when load normalizes.';

  @override
  String get vbProtectActive =>
      'Active: plugins only on the monitored bus, others passthrough (callback over budget)';

  @override
  String get vbProtectActiveTag => 'Protection Active';

  @override
  String get shelfTitle => 'Low Shelf';

  @override
  String get shelfHint =>
      'Lift or cut everything below the corner; fixes thin recordings or boomy lows';

  @override
  String get shelfFreq => 'Gain Frequency';

  @override
  String get shelfGain => 'Gain';

  @override
  String get shelfFreqInfo =>
      'Everything below moves together, 40–400Hz; try 80–120Hz.';

  @override
  String get shelfGainInfo =>
      'Positive lifts, negative cuts; stacks with bass boost, mind doubling.';

  @override
  String get bassShapingTitle => 'Bass Shaping';

  @override
  String get bassShapingHint =>
      'Combines low-shelf filtering with bass mono-making for a clean and focused low-end';

  @override
  String get shelfFreqTooltip =>
      'Cutoff frequency for the low-shelf filter (40–400Hz); boosts or cuts everything below';

  @override
  String get shelfGainTooltip =>
      'Gain boost or cut below the cutoff frequency (-15 to +15dB). Boosts body or tightens rumble';

  @override
  String get bassmonoFreqTooltip =>
      'Frequencies below this cutoff (20–300Hz) are summed to mono to prevent phase cancellation and muddy bass';

  @override
  String get bassShapingMasterHint => 'Master: active when either module is on';

  @override
  String get bassShelfModule => 'Low Shelf';

  @override
  String get bassMonoModule => 'Bass Mono';

  @override
  String get bassMonoDesc =>
      'Sums bass below the crossover to mono to remove phase cancellation and muddiness.';

  @override
  String get channelSelection => 'Channel Selection';

  @override
  String get bassShelfRoutingHint =>
      'Select channels to apply low-shelf filtering. Unselected channels pass through unchanged.';

  @override
  String get bassMonoPairsTooltip =>
      'Select channel pairs for bass mono. Unselected pairs pass through unchanged; stereo/binaural paths only affect L/R.';

  @override
  String get bassMonoPairs => 'Channel Selection';

  @override
  String bassMonoPairCount(int count) {
    return '$count pair(s)';
  }

  @override
  String get bassMonoPairFront => 'Front';

  @override
  String get bassMonoPairCenterLfe => 'Center+LFE';

  @override
  String get bassMonoPairSide => 'Side';

  @override
  String get bassMonoPairBack => 'Back';

  @override
  String get bassMonoPairAll => 'All';

  @override
  String get bassMonoPairFrontOnly => 'Front only';

  @override
  String get bassMonoPairUnavailable =>
      'This pair is not present in the current output';

  @override
  String get bassMonoMerge => 'Merge Mode';

  @override
  String get bassMonoMergePerPair => 'Per pair';

  @override
  String get bassMonoMergeGlobal => 'Merge all';

  @override
  String get bassMonoMergeSinglePairHint =>
      'With a single pair selected, both modes are identical';

  @override
  String get bassMonoNoneSelected =>
      'No channel pair selected · not processing';

  @override
  String bassMonoIgnoredPairs(int count) {
    return '$count pair(s) ignored (not present in current output)';
  }

  @override
  String get bassMonoLfeWarning =>
      'Averaging C/LFE weakens center/LFE separation; not recommended';

  @override
  String get bassMonoStereoPathHint =>
      'Stereo/matrix/binaural path: applies to L/R only';

  @override
  String get retryNow => 'Retry';

  @override
  String sampleRateDeviceActual(int rate) {
    return 'Device actual: $rate Hz';
  }

  @override
  String get sampleRateFollowBridge =>
      'Bridge modes follow the VB/ASIO device; this choice is only saved as a preference (it applies after switching back to in-process mode or on the next launch)';

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
  String get postPerChannelTrim => 'Per-Channel Output Trim';

  @override
  String get postPerChannelTrimHint =>
      'Fine-tune individual output channel levels (-15 to +15 dB)';

  @override
  String get postResetAllTrim => 'Reset All';

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
  String get reverbPreset0 => 'Large Hall';

  @override
  String get reverbPreset1 => 'Concert Hall';

  @override
  String get reverbPreset2 => 'Medium Hall';

  @override
  String get reverbPreset3 => 'Small Hall';

  @override
  String get reverbPreset4 => 'Studio';

  @override
  String get reverbPreset5 => 'Room';

  @override
  String get reverbPreset6 => 'Auditorium';

  @override
  String get reverbPreset7 => 'Plate Reverb';

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
  String get testSrcTitle => 'Test Audio Source';

  @override
  String get testSrcHint =>
      'Signals for measurement; stopping returns to the formal source';

  @override
  String get srcMp3 => 'Open MP3 File';

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
  String get channelsMatrix => 'Matrix downmix';

  @override
  String get channelsDiscrete => 'Discrete per-channel';

  @override
  String get channelPhaseA =>
      'DSP strategy when input or output device is multi-channel (4.0 / 5.1 / 7.1): Discrete = all channels independently pass through DSP with per-effect masks and upmixing plugin support; Matrix = folded to stereo for DSP and upmixed back to surround (LFE passthrough). Binaural Virtual Surround takes highest priority when enabled.';

  @override
  String get audioMode => 'Audio Mode';

  @override
  String get audioModeHint =>
      'Mode switches apply instantly; WASAPI will converge on AuraVAIO only';

  @override
  String get audioParadigm => 'Processing Paradigm';

  @override
  String get audioParadigmHint =>
      'Select audio topology: Attachment Mode intercepts in-place; Pipeline Mode flows end-to-end (ADR-009)';

  @override
  String get paradigmAttachment => 'Attachment Mode';

  @override
  String get paradigmPipeline => 'Pipeline Mode';

  @override
  String get modeVoicemeeterApi => 'Voicemeeter API';

  @override
  String get pipelineIn => 'Input Endpoint';

  @override
  String get pipelineInHint =>
      'Select the entry point for audio into the AuraDSP core processing pipeline';

  @override
  String get pipelineOut => 'Output Endpoint';

  @override
  String get pipelineOutHint =>
      'Select the destination for audio processed by AuraDSP';

  @override
  String get inputWasapi => 'WASAPI Standard Mode';

  @override
  String get inputVaio => 'AuraVAIO Virtual Input';

  @override
  String get inputAsioDriver => 'AuraDSP Virtual ASIO';

  @override
  String get outputWasapi => 'WASAPI Standard Output';

  @override
  String get outputVaio => 'AuraVAIO Virtual Output';

  @override
  String get outputAsioClient => 'AuraDSP ASIO Client';

  @override
  String get tooltipInputWasapi =>
      'WASAPI Standard Mode: Capture from physical microphones or loopback recording from playback devices';

  @override
  String get tooltipInputVaio =>
      'AuraVAIO Virtual Input: Receive streams routed to the AuraVAIO virtual audio device';

  @override
  String get tooltipInputAsioDriver =>
      'AuraDSP Virtual ASIO: Expose a virtual ASIO driver for DAWs like FL Studio, Cubase, Ableton, etc.';

  @override
  String get tooltipOutputWasapi =>
      'WASAPI Standard Output: Render audio to physical speakers, headphones, or virtual outputs';

  @override
  String get tooltipOutputVaio =>
      'AuraVAIO Virtual Output: Render audio to the virtual cable endpoint, with optional headphone mirror';

  @override
  String get tooltipOutputAsioClient =>
      'AuraDSP ASIO Client: Output to external professional physical ASIO audio interfaces with ultra-low latency';

  @override
  String get driverLayerTitle => 'Driver Information & Controls';

  @override
  String get inputLayerTitle => 'Audio Input';

  @override
  String get outputLayerTitle => 'Audio Output';

  @override
  String get inputDisabledNotice =>
      'Input endpoint is disabled (audio capture paused)';

  @override
  String get outputDisabledNotice =>
      'Output endpoint is disabled (audio playback muted)';

  @override
  String get inputDeviceLabel => 'Input Device';

  @override
  String get outputDeviceLabel => 'Output Device';

  @override
  String get defaultInputDevice => 'System Default Device [Loopback]';

  @override
  String get defaultOutputDevice => 'System Default Output (Default Render)';

  @override
  String get tagLoopback => '[Loopback]';

  @override
  String get tagRecording => '[Recording]';

  @override
  String get apoTargetEndpoint => 'Target Endpoint';

  @override
  String get apoTargetEndpointHint =>
      'Select the Windows audio endpoint to attach AuraDSP System APO effects';

  @override
  String get apoStatus => 'APO Status';

  @override
  String get apoAttached => 'Attached';

  @override
  String get apoNotAttached => 'Not Attached';

  @override
  String get apoActionAttach => 'Attach APO';

  @override
  String get apoActionDetach => 'Detach APO';

  @override
  String get asioDriverCardTitle => 'AuraDSP Virtual ASIO Driver';

  @override
  String get asioDriverStatus => 'Driver Status';

  @override
  String get asioDriverRegistered => 'Registered in System';

  @override
  String get asioDriverNotRegistered => 'Not Registered';

  @override
  String get asioDriverActionRegister => 'Register Driver';

  @override
  String get asioDriverActionUnregister => 'Unregister Driver';

  @override
  String get asioDawStatus => 'DAW Status';

  @override
  String get asioDawConnected => 'Active Connection';

  @override
  String get asioDawIdle => 'Idle (Waiting for DAW)';

  @override
  String get asioStatusCheck => 'Check Status';

  @override
  String get virtualSinkNotice =>
      'Note: AuraVAIO is a virtual sink. Open OBS or a recording app to listen to output.';

  @override
  String get monitorMirroring => 'Headphone Monitor Mirroring';

  @override
  String get monitorMirroringHint =>
      'Mirror audio to physical headphones while pushing to the virtual sink for local listening';

  @override
  String get audioDevice => 'Device';

  @override
  String get modeAuto => 'Auto';

  @override
  String get sampleRate => 'Sample Rate';

  @override
  String get buffer => 'Buffer';

  @override
  String get modeVaio => 'AuraVAIO';

  @override
  String get modeVb => 'Voicemeeter';

  @override
  String get modeSysApo => 'System APO';

  @override
  String get modeAsio => 'ASIO';

  @override
  String get asioDriver => 'ASIO Driver';

  @override
  String get asioBufSize => 'Buffer Size';

  @override
  String get asioBufAuto => 'Auto (driver preferred)';

  @override
  String get asioOutPair => 'Output Block Start';

  @override
  String get asioDeviceChannels => 'Device Channels';

  @override
  String get asioTransportChannels => 'Transport Channels';

  @override
  String get asioRefresh => 'Refresh';

  @override
  String get asioSwitches => 'Switches';

  @override
  String asioSrMismatch(String sr, String cfg) {
    return 'Driver runs at $sr Hz, mismatching the global $cfg Hz (ASIO follows the driver)';
  }

  @override
  String wasapiSrFallback(String sr, String cfg) {
    return 'Device runs at $sr Hz (requested $cfg Hz was rejected, fell back)';
  }

  @override
  String get asioLatChanged =>
      'Driver reported a latency change (reopens on next session)';

  @override
  String get asioDropouts => 'Dropouts';

  @override
  String get modeRoot => 'Root';

  @override
  String get modeRootless => 'Rootless';

  @override
  String get modeSystem => 'System';

  @override
  String get modeVirtual => 'Virtual';

  @override
  String get modeDriver => 'Driver';

  @override
  String get catAppearance => 'Appearance';

  @override
  String get catAudio => 'Audio';

  @override
  String get catSystem => 'System';

  @override
  String get catTest => 'Test';

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
  String get visualizerSettingsTip => 'Visualizer settings';

  @override
  String get visualizerShowLyricsTip => 'Show lyrics';

  @override
  String get visualizerHideLyricsTip => 'Hide lyrics';

  @override
  String get visualizerLyricsNoMedia => 'No active media session';

  @override
  String get visualizerLyricsNoMediaHint =>
      'Play music in any app and lyrics will be matched automatically';

  @override
  String get visualizerLyricsSearching => 'Searching for lyrics…';

  @override
  String get visualizerLyricsSearchingHint =>
      'Matching online lyrics for the current track';

  @override
  String get visualizerLyricsNotFound => 'No matching lyrics found';

  @override
  String get visualizerLyricsNotFoundHint =>
      'Retry, or load a local LRC file manually';

  @override
  String get visualizerLyricsReady => 'Lyrics loaded';

  @override
  String get visualizerLyricsRetry => 'Retry';

  @override
  String get visualizerLyricsPickLocal => 'Local LRC';

  @override
  String get visualizerResetPeakTip => 'Reset peak hold';

  @override
  String get visualizerDisplayRestoreTip => 'Restore: standard page layout';

  @override
  String get visualizerDisplayStageTip =>
      'App fullscreen: stage fills the window';

  @override
  String get visualizerDisplayImmersiveTip =>
      'Visualizer only: hide navigation and meters (Esc steps back)';

  @override
  String get visualizerDrawerTitle => 'Visualizer Settings';

  @override
  String get visualizerDrawerCloseTip => 'Close settings';

  @override
  String get visualizerSectionPalette => 'COLOR PALETTE';

  @override
  String get visualizerSectionPaletteInfo =>
      'Select spectrum and waveform color theme';

  @override
  String get visualizerSectionDynamics => 'DYNAMICS & DAMPING';

  @override
  String get visualizerSectionDynamicsInfo =>
      'Configure audio energy response sensitivity and decay physics';

  @override
  String get visualizerSectionVisuals => 'VISUALS & GUIDES';

  @override
  String get visualizerSectionVisualsInfo =>
      'Fine-tune phosphor bloom, grid lines, and scales';

  @override
  String get visualizerSectionLyrics => 'LYRICS & SUBTITLES';

  @override
  String get visualizerSectionLyricsInfo =>
      'Configure synchronized scrolling lyrics display';

  @override
  String get visualizerSensitivity => 'Sensitivity';

  @override
  String get visualizerSensitivityInfo =>
      'Audio energy scaling multiplier for visual bounce';

  @override
  String get visualizerDecay => 'Falloff Decay';

  @override
  String get visualizerDecayInfo =>
      'Air damping resistance for peak and spectrum decay';

  @override
  String get visualizerGravity => 'Gravity';

  @override
  String get visualizerGravityInfo =>
      'Gravitational acceleration pulling peak meters downward';

  @override
  String get visualizerBloom => 'Phosphor Bloom';

  @override
  String get visualizerBloomInfo =>
      'Cathode-ray persistence and LED glow intensity';

  @override
  String get visualizerLineWidth => 'Line Thickness';

  @override
  String get visualizerLineWidthInfo =>
      'Stroke width of oscilloscope beam, phase curves, and vector lines';

  @override
  String get visualizerBandsDensity => 'Bands Density';

  @override
  String get visualizerBandsDensityInfo =>
      'Select 32 or 64 frequency resolution bands';

  @override
  String get visualizerToggleGrid => 'Reference Grid';

  @override
  String get visualizerToggleGridInfo =>
      'Display 100Hz, 1kHz, 10kHz octave and horizontal dB lines';

  @override
  String get visualizerTogglePeaks => 'Peak Hold Lines';

  @override
  String get visualizerTogglePeaksInfo =>
      'Retain physical gravity bounce lines on top of spectrum bars';

  @override
  String get visualizerToggleDbScale => 'dBFS Vertical Scale';

  @override
  String get visualizerToggleDbScaleInfo =>
      'Show 0 to -60 dBFS acoustic scale along right border';

  @override
  String get visualizerToggleLyrics => 'Lyrics Overlay';

  @override
  String get visualizerToggleLyricsInfo =>
      'Overlay synchronized lyrics above the visualizer stage';

  @override
  String get visualizerToggleTranslation => 'Bilingual Translation';

  @override
  String get visualizerToggleTranslationInfo =>
      'Show translated lyrics beneath the primary line (lyrics overlay must be on)';

  @override
  String get visualizerResetDefaults => 'Reset Defaults';

  @override
  String get visualizerResetDefaultsTip =>
      'Restore all visualizer parameters to factory defaults';

  @override
  String get visualizerStyleBars => 'Spectrum Bars';

  @override
  String get visualizerStyleOscilloscope => 'Oscilloscope';

  @override
  String get visualizerStyleGoniometer => 'Phase Scope';

  @override
  String get visualizerStyleCyberGrid => 'Cyber Grid';

  @override
  String get visualizerStylePulseOrb => 'Pulse Nebula';

  @override
  String get visualizerStyleAurora => 'Aurora Ribbon';

  @override
  String get visualizerStyleTunnel => 'Neon Tunnel';

  @override
  String get visualizerStyleMilkdrop => 'MilkDrop';

  @override
  String get visualizerStyleFluid => 'Fluid Silk';

  @override
  String get visualizerStyleTornado => 'Particle Tornado';

  @override
  String get visualizerThemeSystem => 'System Theme';

  @override
  String get visualizerThemeNeonCyber => 'Cyber Neon';

  @override
  String get visualizerThemeAmberTube => 'Amber Tube';

  @override
  String get visualizerThemeMatrixGreen => 'Matrix Phosphor';

  @override
  String get visualizerThemeAuroraGlow => 'Aurora Glow';

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
  String get lpCompiledIdle => 'Compiled · Click Apply in toolbar to run';

  @override
  String get lpSliders => 'Script sliders (slider1..8)';

  @override
  String get lpSliderHint =>
      'Declared range wins; 0..1 when undeclared; changes apply live';

  @override
  String get lpLibrary => 'Script Library';

  @override
  String get lpLibraryEmpty =>
      'Library is empty — save current code with the name field below';

  @override
  String get lpSave => 'Save to library';

  @override
  String get lpApoDialogTitle => 'Import EqualizerAPO Preset (.txt)';

  @override
  String get lpApoDialogDesc =>
      'Convert EqualizerAPO / Peace parametric EQ text into a high-performance EEL2 script';

  @override
  String get lpApoOpenFile => 'Open .txt file';

  @override
  String get lpApoPasteHint =>
      'Paste EqualizerAPO configuration text here (e.g. Filter: ON PK Fc 1000 Hz Gain -3.0 dB Q 1.41)...';

  @override
  String get lpApoSwapChannels => 'Swap Channels (L ↔ R)';

  @override
  String get lpApoInvertPolarity => 'Invert Polarity (Phase 180°)';

  @override
  String lpApoFiltersDetected(int n) {
    return 'Detected $n filters';
  }

  @override
  String lpApoPreampDetected(String gain) {
    return 'Preamp: $gain dB';
  }

  @override
  String get lpApoApply => 'Load into Editor';

  @override
  String get lpApoPreview => 'Generated EEL2 Code Preview';

  @override
  String get lpFind => 'Find';

  @override
  String get lpReplace => 'Replace';

  @override
  String get lpReplaceAll => 'Replace All';

  @override
  String get lpFindNext => 'Next match';

  @override
  String get lpFindPrev => 'Previous match';

  @override
  String get lpMatchCase => 'Match case';

  @override
  String lpMatchCount(int current, int total) {
    return '$current of $total';
  }

  @override
  String get lpNoMatches => 'No matches';

  @override
  String get lpOutline => 'Code Outline';

  @override
  String get lpOutlineEmpty => 'No sections or functions found';

  @override
  String get lpTemplates => 'Script Templates';

  @override
  String get lpTemplatesDesc =>
      'Select a starter DSP template to accelerate your audio script development';

  @override
  String get lpTemplateUse => 'Use Template';

  @override
  String get lpManualSearchHint =>
      'Search 80+ EEL2 functions, keywords, registers...';

  @override
  String get lpManualInsert => 'Insert into Editor';

  @override
  String get lpManualParamTitle => 'Parameters';

  @override
  String get lpManualReturnTitle => 'Return Value';

  @override
  String get lpManualExampleTitle => 'Example';

  @override
  String get lpAllCategories => 'All';

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
  String get presetDirtyBadge => 'Custom (unsaved)';

  @override
  String get presetDeleted => 'Preset deleted';

  @override
  String get presetDeleteFail =>
      'Delete failed (file may be locked or already gone)';

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
  String get tubeHint =>
      'Simulates the harmonic saturation characteristics of classic vacuum tube preamps and analog tape machines. Introduces musical even/odd harmonics to eliminate digital harshness, imparting warmth, analog body, and pleasant saturation.';

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
  String get bassModeDynamic => 'Natural Bass';

  @override
  String get bassModeShelf => 'Pure Bass+';

  @override
  String get bassModeHarmonic => 'Sub-woofer';

  @override
  String get bassModeTooltip =>
      'Bass acoustic modes:\n• Natural: Pure linear dynamic bass boost with zero harmonic coloration, preserving original transients\n• Pure Bass+: Generates subtle even harmonics to enhance warmth and body contouring\n• Sub-woofer: Deep subharmonic synthesis for profound bass extension on compact drivers';

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
  String get dlgClose => 'Close';

  @override
  String get dlgUnload => 'Unload';

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
  String get sysTitle => 'System';

  @override
  String get sysHint => 'System tray residency and launch at startup';

  @override
  String get sysTray => 'Minimize to tray';

  @override
  String get sysTrayHint =>
      'Closing the window hides to the system tray while audio keeps playing; quit via the tray menu';

  @override
  String get sysAutostart => 'Launch at login';

  @override
  String get trayShow => 'Show Main Window';

  @override
  String get trayQuit => 'Quit';

  @override
  String get sysAutostartHint =>
      'Start AuraDSP automatically when signing in to the system';

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
  String latTipEstimated(String text) {
    return 'Estimated (not measured): $text\nFrom the nominal table or an analytic estimate; no impulse-response measurement was run';
  }

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
  String get stBassmono => 'Bass Mono';

  @override
  String get stGate => 'Noise Gate';

  @override
  String get stFilter => 'Filter';

  @override
  String get filterHint =>
      'First shaper after gate: HP kills rumble, LP/BP as needed';

  @override
  String get filterType => 'Type';

  @override
  String get filterHP => 'High-pass';

  @override
  String get filterLP => 'Low-pass';

  @override
  String get filterBP => 'Band-pass';

  @override
  String get filterFreq => 'Frequency';

  @override
  String get filterQ => 'Q';

  @override
  String get gateHint =>
      'Chain head: background below threshold is gated, attack/release shape the edges';

  @override
  String get gateThreshold => 'Threshold';

  @override
  String get gateAttack => 'Attack';

  @override
  String get gateRelease => 'Release';

  @override
  String get gateAutoGain => 'Auto gain compensation';

  @override
  String get deesserTitle => 'De-esser';

  @override
  String get deesserFreq => 'Sibilance band';

  @override
  String get deesserAmount => 'Reduction';

  @override
  String get stHaas => 'Differential Surround';

  @override
  String get stExciter => 'Exciter';

  @override
  String get stLoudness => 'Loudness';

  @override
  String get stDyneq => 'Dynamic EQ';

  @override
  String get dyneqTitle => 'Dynamic Equalizer';

  @override
  String get dyneqHint =>
      '3-band fully parametric dynamic EQ: cuts band energy above threshold, static shaping below';

  @override
  String get dyneqBandLow => 'Low Band';

  @override
  String get dyneqBandMid => 'Mid Band';

  @override
  String get dyneqBandHigh => 'High Band';

  @override
  String get dyneqFreq => 'Frequency';

  @override
  String get dyneqQ => 'Q';

  @override
  String get dyneqGain => 'Static Gain';

  @override
  String get dyneqRange => 'Dynamic Range';

  @override
  String get dyneqThreshold => 'Threshold';

  @override
  String get dyneqAttack => 'Attack';

  @override
  String get dyneqRelease => 'Release';

  @override
  String get loudnessAmount => 'Amount';

  @override
  String get exciterHint => 'Harmonic air for compressed highs';

  @override
  String get exciterAmount => 'Amount';

  @override
  String get exciterHifreq => 'Pickup freq';

  @override
  String get exciterHifreqInfo =>
      'Harmonics from content above this freq only. Go lower for MP3s lacking highs, higher for harsh sibilance.';

  @override
  String get chainPinnedFirst => 'pinned first';

  @override
  String get chainPinnedLast => 'pinned last';

  @override
  String get haasHint =>
      'One side delayed widens the stage, the other stays dry';

  @override
  String get haasDelay => 'Delay';

  @override
  String get haasMix => 'Differential mix';

  @override
  String get haasSide => 'Delay side';

  @override
  String get haasSideRight => 'Right channel';

  @override
  String get haasSideLeft => 'Left channel';

  @override
  String get fxCatSpatial => 'Spatial Effects';

  @override
  String get fxCatStereoOnly => 'Stereo Only';

  @override
  String get fxCatLate => 'Exciter & Output';

  @override
  String get spatialTitle => 'Spatial';

  @override
  String get spatialHint =>
      'Recreates a virtual multi-speaker acoustic room with physical early reflections over headphones, delivering a spacious out-of-head listening experience.';

  @override
  String get spatialStyle => 'Style';

  @override
  String get spatialStyleInfo =>
      'Curated spatial presets: instantly applies calibrated room reflections, speaker width, and vocal focus.';

  @override
  String get spatialStyleCinema => 'Cinema';

  @override
  String get spatialStyleImaging => 'Imaging';

  @override
  String get spatialStyleNeutral => 'Neutral';

  @override
  String get spatialStyleCustom => 'Custom';

  @override
  String get spatialRoom => 'Room';

  @override
  String get spatialRoomInfo =>
      'Room acoustic volume and early reflection strength: 0 for free-field, higher values expand room boundary reflections.';

  @override
  String get spatialWidth => 'Width';

  @override
  String get spatialWidthInfo =>
      'Soundstage width and speaker aperture: expands stereo boundary for immersive out-of-head projection.';

  @override
  String get spatialCenter => 'Center';

  @override
  String get spatialCenterInfo =>
      'Center vocal imaging and dialogue focus: enhances solidity and clarity of phantom center vocals.';

  @override
  String get spatialOutGain => 'Output';

  @override
  String get spatialOutGainInfo =>
      'Spatial output gain trim compensation (-12 to +6 dB).';

  @override
  String get spatialAutoGain => 'Auto gain';

  @override
  String get spatialAutoGainInfo =>
      'Equal-loudness calibration: continuously matches input energy to prevent unexpected volume shifts.';

  @override
  String get spatialMix => 'Spatial mix';

  @override
  String get spatialMixInfo =>
      'Dry/spatial blend. 0% equals bypass, 100% is full virtualization';

  @override
  String get spatialElevation => 'Elevation';

  @override
  String get spatialElevationInfo =>
      'Virtual stage elevation. Positive lifts the image, negative lowers it';

  @override
  String get spatialBinaural => 'Multichannel binaural';

  @override
  String get spatialBinauralInfo =>
      'Renders 4/5.1/7.1 channels to binaural stereo for headphones. Output is FL/FR only; other channels are muted. While it is on, it takes over \'Channel Mode\' from the settings page (that setting has no effect)';

  @override
  String get spatialHeadTrack => 'Head tracking';

  @override
  String get spatialHeadTrackInfo =>
      'Receives head yaw from OpenTrack UDP (port 4242); off uses the manual angle';

  @override
  String get spatialHeadAzim => 'Head azimuth';

  @override
  String get spatialHeadAzimInfo =>
      'Manual yaw; overridden by external data while head tracking is on';

  @override
  String get src51Fold => 'Fold-down';

  @override
  String get src51Pass => 'Passthrough';

  @override
  String get src51Hint =>
      'Multichannel file: fold-down runs through the engine, passthrough bypasses it; falls back to fold-down when the device has fewer channels';

  @override
  String get bassmonoHint =>
      'Chain head: mono below crossover, saves small speakers';

  @override
  String get bassmonoFreq => 'Bass Mono Frequency';

  @override
  String get stEq => 'Equalizer';

  @override
  String get stArbmag => 'Arbitrary-response EQ';

  @override
  String get stScript => 'Script';

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
  String get chainGrpInput => 'Input Shaping';

  @override
  String get chainGrpTone => 'Tone & Dynamics';

  @override
  String get chainGrpEqScript => 'EQ & Script';

  @override
  String get chainGrpSound => 'Soundstage';

  @override
  String get chainGrpSpatial => 'Spatial';

  @override
  String get chainGrpOut => 'Output Stage';

  @override
  String get chainFlowTitle => 'Signal Flow (Current Order)';

  @override
  String get chainFlowCaption => 'Global signal-flow overview:';

  @override
  String get chainNodeInput => 'Input Gate';

  @override
  String get chainNodeLimiter => 'Main Limiter';

  @override
  String get chainNodeOutputGate => 'Output Gate';

  @override
  String get chainNodeOutput => 'Audio Output';

  @override
  String get lpManual => 'Manual';

  @override
  String get lpManualTitle => 'EEL2 Script Quick Reference';

  @override
  String get lpManualContent =>
      '【Audio Stream Registers】\n• spl0: Left channel sample (float, nominal ±1.0)\n• spl1: Right channel sample (float, nominal ±1.0)\n• srate: Active audio device sample rate (Hz)\n\n【Sliders】\n• slider1 ~ slider8: Interactive dynamic slider variables (default 0.0 ~ 1.0)\n\n【Sections】\n• @init: Runs once on load/reset (requires at least one statement or variable initialization)\n• @slider: Triggered on user slider change\n• @sample: Real-time per-sample DSP loop';

  @override
  String get lpEditorTooltip =>
      'Real-time programmable audio DSP engine based on Cockos EEL2.';

  @override
  String get exciterMode => 'Mode';

  @override
  String get exciterModeTooltip =>
      'Generates high-frequency harmonics via nonlinear transfer functions to restore presence.';

  @override
  String get exciterAmountInfo =>
      'Controls the blend level of generated high-frequency harmonics. Enhances airiness and clarity.';

  @override
  String get eqModeLabel => 'Mode';

  @override
  String get eqModeTooltip =>
      'EQ band mode. Drag nodes vertically on the canvas to adjust gain, double click to reset to 0dB, and tune Q sharpness on the right.';

  @override
  String get haasSideTooltip =>
      'Haas Effect surround: Delays one channel by 0~25ms to create an expansive, out-of-head 3D soundstage using binaural time arrival differences.';

  @override
  String get bassmonoCombinedTooltip =>
      'Sums low frequencies below cutoff into mono to eliminate phase cancellations and improve punch.';

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
  String get chainStagePreVendor => 'Pre-DSP Chain';

  @override
  String get chainStagePostVendor => 'Post-DSP Chain';

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
  String get chainSlotRemoteFailed => 'Plugin host lost - bypassed';

  @override
  String get chainPdcLabel => 'Delay compensation (PDC)';

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
  String get plugFeatDirs =>
      'Custom plugin folder search & local state snapshots';

  @override
  String get plugFeatRt => 'Flat stereo RT-Safe preallocation, zero locks';

  @override
  String get plugFeatRoute => 'Per-route plugin setup (VB)';

  @override
  String plugSlot(int n) {
    return 'Slot $n (Slot $n)';
  }

  @override
  String get plugBypassed => 'Bypassed';

  @override
  String get plugCustomTitle => 'Plugin Scan Folders';

  @override
  String get plugCustomHint =>
      'Check the folders to scan (standard platform folders are pre-added; the built-in folder cannot be removed). Only checked folders and their subfolders are scanned.';

  @override
  String get plugCustomAdd => 'Add Folder';

  @override
  String get plugCustomEmpty =>
      'The scan folder list is empty. Use \"Add folder\" to pick a plugin directory.';

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
  String get plugRouteBypassed => 'Bypass';

  @override
  String get abSlotA => 'Preset A';

  @override
  String get abSlotB => 'Preset B';

  @override
  String get abAutoSave => 'Auto save';

  @override
  String abInheritFrom(String src) {
    return 'Inherit from $src';
  }

  @override
  String get abReset => 'Reset (clear this preset, source untouched)';

  @override
  String get abResetDone => 'Preset reset';

  @override
  String get plugRouteLocked => 'Locked';

  @override
  String get plugChStereoOnly =>
      'VB mode feeds only stereo (L/R) per bus into the plugin chain';

  @override
  String get plugLoading => 'Loading…';

  @override
  String get plugUnloading => 'Unloading…';

  @override
  String get plugStateActive => 'Active';

  @override
  String get plugStateBypassed => 'Bypassed';

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
  String plugSlotBypassed(int n) {
    return 'Slot $n bypassed';
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
  String get plugPartialBypass => 'Partial bypass';

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

  @override
  String get compTitle => 'Dynamic Compressor';

  @override
  String get compHint =>
      'Smooths out loud peaks and lifts subtle details for a cohesive sound. The right meter displays real-time gain reduction (GR).';

  @override
  String get compTimeconstant => 'Time Constant';

  @override
  String get compGranularity => 'Granularity';

  @override
  String get compGranularityCoarse => 'Coarse (Low Load)';

  @override
  String get compGranularityNormal => 'Standard (Balanced)';

  @override
  String get compGranularityFine => 'Fine (Multi-band)';

  @override
  String get compTfresolution => 'TF Resolution';

  @override
  String get compTfresTransient => 'Transient';

  @override
  String get compTfresBalanced => 'Balanced';

  @override
  String get compTfresFine => 'High Frequency';

  @override
  String get compModePairBadge => 'Pair Mode';

  @override
  String get compModePairHint =>
      'Allocates compression slots per channel-pair to save CPU and memory. Requires selecting both channels of a pair; semi-selected pairs pass through uncompressed.';

  @override
  String get compModeSemiSelectedWarning =>
      'Pair mode requires selecting full pairs; semi-selected pairs are bypassed';

  @override
  String get autoGainCompensation => 'Auto Gain Compensation';

  @override
  String get autoGainCompensationTooltip =>
      'Dynamically compensates output level to prevent inter-stage clipping.';

  @override
  String get outputGainGate => 'Output Gain Trim';

  @override
  String get outputGainGateTooltip =>
      'Fine-tune the output level of this stage (-12.0 to +6.0 dB).';

  @override
  String get arbmagSubtitle =>
      'Based on an 8192-point causal minimum-phase FIR convolution engine. Supports AutoEq GraphicEQ curves or custom frequency responses to calibrate headphones and speakers with high precision.';

  @override
  String get arbmagPresetFlat => 'Flat';

  @override
  String get arbmagPresetHarman => 'Harman Target';

  @override
  String get arbmagPresetDiffuse => 'Diffuse-Field';

  @override
  String get arbmagImport => 'Import File';

  @override
  String get arbmagPaste => 'Paste';

  @override
  String get arbmagClear => 'Clear Curve';

  @override
  String get arbmagEmptyHint =>
      'No curve loaded. Select a target preset above, import an AutoEq GraphicEQ file, or paste code.';

  @override
  String get arbmagEditor => 'GraphicEQ Code Editor';

  @override
  String get arbmagApply => 'Apply Code';

  @override
  String get arbmagInvalidFormat =>
      'Invalid GraphicEQ format or no valid frequency nodes found';

  @override
  String get crossfeedTitle => 'Crossfeed';

  @override
  String get crossfeedMode => 'Mode';

  @override
  String get crossfeedDesc =>
      'Simulates acoustic crosstalk to relieve headphone in-the-head listening fatigue';

  @override
  String get crossfeedModeDefault => 'Default Standard';

  @override
  String get crossfeedModeChuMoy => 'Chu Moy Classic';

  @override
  String get crossfeedModeJanMeier => 'Jan Meier Enhanced';

  @override
  String get crossfeedModeCustom => 'Custom';

  @override
  String get crossfeedCutoff => 'Cutoff Frequency';

  @override
  String get crossfeedFeed => 'Feed Level';

  @override
  String crossfeedActiveDesc(String mode, String fcut, String feed) {
    return 'Active: $mode ($fcut Hz, $feed dB)';
  }

  @override
  String get fxCatFront => 'Front Shaping';

  @override
  String get fxCatCore => 'Core Processing';

  @override
  String get channelCenter => 'Center (C)';

  @override
  String get channelLfe => 'LFE';

  @override
  String get channelSurroundLeft => 'Surround Left (SL)';

  @override
  String get channelSurroundRight => 'Surround Right (SR)';

  @override
  String get channelBackLeft => 'Back Left (BL)';

  @override
  String get channelBackRight => 'Back Right (BR)';

  @override
  String inputChannelsCount(int n) {
    return '$n Channels';
  }

  @override
  String inputBalanceTuned(int n) {
    return 'Tuned $n ch';
  }

  @override
  String get inputBalanceDefault => '100% Default Balance';

  @override
  String get eqPresetElectronic => 'Electronic (EDM)';

  @override
  String get eqPresetHiphop => 'Hip-Hop';

  @override
  String get eqPresetAcoustic => 'Acoustic';

  @override
  String get eqPresetMetal => 'Metal';

  @override
  String get eqPresetPodcast => 'Podcast';

  @override
  String get convIrPrompt => 'Enter or select Impulse Response (IR) file path:';

  @override
  String get convLoadIr => 'Load IR';

  @override
  String get ddcVdcPrompt => 'Enter or select VDC calibration file path:';

  @override
  String get ddcLoadVdc => 'Load VDC';

  @override
  String get arbmagPrompt =>
      'Enter or select AutoEq / GraphicEQ curve file path:';

  @override
  String get testAudioWavPrompt =>
      'Enter or select test audio (WAV) file path:';

  @override
  String get testAudioMp3Prompt => 'Enter or select MP3 audio file path:';

  @override
  String get testAudioLoad => 'Load Audio';

  @override
  String get pathPickerTitle => 'Select Path';

  @override
  String get pathPickerConfirm => 'Confirm';

  @override
  String get pathPickerBrowse => 'Browse...';

  @override
  String get pathPickerClear => 'Clear';

  @override
  String get pathPickerSelectDir => 'Select This Directory';

  @override
  String get pathPickerErrEmpty => 'Path cannot be empty';

  @override
  String get pathPickerErrDirNotExist =>
      'Directory does not exist or access denied';

  @override
  String get pathPickerErrFileNotExist =>
      'File does not exist or access denied';

  @override
  String pathPickerErrFormat(String exts) {
    return 'Unsupported file format (supported: $exts)';
  }

  @override
  String pathPickerSupported(String exts) {
    return 'Supported formats: $exts';
  }

  @override
  String get errEngineClosed => 'Engine is not running';

  @override
  String get errEngineBusy => 'Engine busy, retry later';

  @override
  String get errInvalidLength => 'Invalid length';

  @override
  String get errInvalidEncoding => 'Invalid encoding';

  @override
  String get errInvalidPath => 'Invalid path';

  @override
  String get errBufferTooSmall => 'Insufficient buffer space';

  @override
  String get errFileTooSmall => 'File too small';

  @override
  String get errFileTooLarge => 'File size exceeds the limit';

  @override
  String get errOutOfRange => 'Value out of allowed range';

  @override
  String get errOutOfMemory => 'Out of memory';

  @override
  String get errParseFailed => 'Content parsing failed';

  @override
  String get errIoFailed => 'File I/O failed';

  @override
  String get errRejected => 'Value rejected by engine';

  @override
  String get errUnsupported => 'Unsupported operation';

  @override
  String get errReadOnly => 'Parameter is read-only';

  @override
  String get errInternal => 'Internal engine error';

  @override
  String get lpFindReplace => 'Find & Replace';

  @override
  String get lpSidebarLeft => 'Toggle Left Panel (Outline & Library)';

  @override
  String get lpSidebarRight => 'Toggle Right Panel (Sliders & Console)';

  @override
  String get lpConsole => 'Console';

  @override
  String get lpNewScriptWizard => 'Script Wizard';

  @override
  String get lpApoImportTitle => 'Import APO TXT';

  @override
  String get lpConfirmDiscardTitle => 'Discard Changes?';

  @override
  String get lpConfirmDiscardBody =>
      'The current script has unsaved modifications. Loading new content will discard these changes. Proceed?';

  @override
  String get lpConfirmDiscardAction => 'Discard & Load';

  @override
  String get lpConsoleClear => 'Clear Output';

  @override
  String get lpExpandEditor => 'Expand';

  @override
  String get lpCollapseEditor => 'Collapse';

  @override
  String get lpUncompiled => 'Uncompiled edits';

  @override
  String get lpRunningOldCode => 'Running previous code';

  @override
  String get lpCompileSuccess => 'Compiled successfully';

  @override
  String get lpCompilingScript => 'Compiling script…';

  @override
  String get lpEyebrowDsp => 'Programmable DSP';

  @override
  String get lpTitleEditor => 'EEL2 Editor';

  @override
  String get lpBtnApplied => 'Applied';

  @override
  String get lpBtnUnapplied => 'Unapplied';

  @override
  String get lpBtnCompile => 'Compile';

  @override
  String get lpTooltipCompileFirst => 'Code modified; compile before applying';

  @override
  String get lpMenuFile => 'File';

  @override
  String get lpFileNewBlank => 'New Blank Script';

  @override
  String get lpFileNewFromTemplate => 'New from Template...';

  @override
  String get lpFileImportApo => 'Import APO Preset...';

  @override
  String get lpFileImportEel => 'Import EEL Script...';

  @override
  String get lpFileSaveAs => 'Save As...';

  @override
  String get lpFileSaveAsPrompt => 'Enter destination path and filename:';

  @override
  String get lpFileOverwriteConfirmTitle => 'File Already Exists';

  @override
  String lpFileOverwriteConfirmBody(String name) {
    return 'The file \"$name\" already exists. Overwrite it?';
  }

  @override
  String get lpFileOverwriteConfirmAction => 'Overwrite';

  @override
  String get lpMenuEdit => 'Edit';

  @override
  String get lpEditFindReplace => 'Find & Replace';

  @override
  String get lpEditToggleOutline => 'Code Outline';

  @override
  String get lpEditFormat => 'Format Code';

  @override
  String get lpEditScrollToTop => 'Scroll to Top';

  @override
  String get lpBtnLibrary => 'Script Library';

  @override
  String get lpLibDialogTitle => 'EEL2 Script Library & Directory Manager';

  @override
  String get lpLibOpenInExplorer => 'Browse in File Manager';

  @override
  String get lpLibDirInvalid => 'Directory does not exist or is invalid';

  @override
  String get lpLibSaveCurrent => 'Save Current Script to Library';

  @override
  String get lpLibCustomDirs => 'Script Directories';

  @override
  String get lpSlidersPanelTitle => 'Parameter Sliders';

  @override
  String get lpSlidersCollapse => 'Collapse Panel';

  @override
  String get lpSlidersExpand => 'Expand Panel';

  @override
  String get lpTabScriptSliders => 'Script Sliders';

  @override
  String get lpTabInputChannels => 'Input Channels (8)';

  @override
  String get lpTabOutputChannels => 'Output Channels (8)';

  @override
  String get lpCustomVarTag => 'Script Var';

  @override
  String get lpCustomVarHint =>
      'Script internal variable (initialized in @init; bind to slider1..8 for host real-time control)';

  @override
  String get lpInputTrimHint =>
      '8-channel unified architecture input trim & master gain';

  @override
  String get lpOutputGainHint =>
      '8-channel independent output post-gain trim (-15dB ~ +15dB)';

  @override
  String get lpResetAll => 'Reset All';

  @override
  String get lpInputMasterGain => 'Master Input Gain';

  @override
  String get lpOutputMasterGain => 'Master Output Gain';

  @override
  String get lpNoScriptSliders => 'No adjustable variables declared in script';

  @override
  String get lpTooltipUnapplyToCompile =>
      'Compilation disabled while applied; unapply first';

  @override
  String get lpLibSystemInitial => '<System Default>';

  @override
  String get lpLibDirs => 'Script Directories';

  @override
  String get lpLibScriptList => 'Script List';

  @override
  String lpApoParseError(int line, String error) {
    return 'Syntax issue on line $line: $error';
  }

  @override
  String get lpApoNoFiltersPreampOnly => 'Preamp Only Mode (No Filters)';

  @override
  String get plugScanDirsSelectAll => 'Select all';

  @override
  String get plugScanDirsClear => 'Clear all checks';

  @override
  String plugScanDirsEnabledCount(int enabled, int total) {
    return '$enabled/$total enabled';
  }

  @override
  String get plugScanDirsBuiltin => 'Built-in';

  @override
  String get plugScanDirsBuiltinHint =>
      'Folder shipped with the app; created automatically and cannot be removed';

  @override
  String get plugScanDirsRemove => 'Remove this folder';

  @override
  String get plugFormatSoon =>
      'Scanning and hosting for this format will arrive in a later release';

  @override
  String get liveprogFontReset => 'click to reset';

  @override
  String get presetDeleteTitle => 'Delete preset';

  @override
  String get presetDeleteBody => 'Delete this preset? This cannot be undone.';

  @override
  String get presetDeleteAction => 'Delete';

  @override
  String presetOverwritten(String name) {
    return 'Overwrote the existing preset \"$name\"';
  }
}
