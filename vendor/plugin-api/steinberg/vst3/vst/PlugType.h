/*
 * Copyright 2023, Steinberg Media Technologies GmbH, All Rights Reserved
 * Copyright 2023 Linux Studio Plugins Project <lsp.plugin@gmail.com>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

#ifndef _3RD_PARTY_STEINBERG_VST3_VST_PLUGTYPE_H_
#define _3RD_PARTY_STEINBERG_VST3_VST_PLUGTYPE_H_

#include <steinberg/vst3/base/Types.h>

namespace Steinberg
{
    namespace Vst
    {
        /**
         * Component Types used as subCategories in PClassInfo2
         */
        namespace PlugType
        {
            SMTG_CONSTEXPR const CString kFx                    = "Fx";             ///< others type (not categorized)
            SMTG_CONSTEXPR const CString kFxAnalyzer            = "Fx|Analyzer";    ///< Scope, FFT-Display, Loudness Processing...
            SMTG_CONSTEXPR const CString kFxBass                = "Fx|Bass";        ///< Tools dedicated to Bass Guitar
            SMTG_CONSTEXPR const CString kFxChannelStrip        = "Fx|Channel Strip"; ///< Tools dedicated to Channel Strip
            SMTG_CONSTEXPR const CString kFxDelay               = "Fx|Delay";       ///< Delay, Multi-tap Delay, Ping-Pong Delay...
            SMTG_CONSTEXPR const CString kFxDistortion          = "Fx|Distortion";  ///< Amp Simulator, Sub-Harmonic, SoftClipper...
            SMTG_CONSTEXPR const CString kFxDrums               = "Fx|Drums";       ///< Tools dedicated to Drums...
            SMTG_CONSTEXPR const CString kFxDynamics            = "Fx|Dynamics";    ///< Compressor, Expander, Gate, Limiter, Maximizer, Tape Simulator, EnvelopeShaper...
            SMTG_CONSTEXPR const CString kFxEQ                  = "Fx|EQ";          ///< Equalization, Graphical EQ...
            SMTG_CONSTEXPR const CString kFxFilter              = "Fx|Filter";      ///< WahWah, ToneBooster, Specific Filter,...
            SMTG_CONSTEXPR const CString kFxGenerator           = "Fx|Generator";   ///< Tone Generator, Noise Generator...
            SMTG_CONSTEXPR const CString kFxGuitar              = "Fx|Guitar";      ///< Tools dedicated to Guitar
            SMTG_CONSTEXPR const CString kFxInstrument          = "Fx|Instrument";  ///< Fx which could be loaded as Instrument too
            SMTG_CONSTEXPR const CString kFxInstrumentExternal  = "Fx|Instrument|External"; ///< Fx which could be loaded as Instrument too and is external (wrapped Hardware)
            SMTG_CONSTEXPR const CString kFxMastering           = "Fx|Mastering";   ///< Dither, Noise Shaping,...
            SMTG_CONSTEXPR const CString kFxMicrophone          = "Fx|Microphone";  ///< Tools dedicated to Microphone
            SMTG_CONSTEXPR const CString kFxModulation          = "Fx|Modulation";  ///< Phaser, Flanger, Chorus, Tremolo, Vibrato, AutoPan, Rotary, Cloner...
            SMTG_CONSTEXPR const CString kFxNetwork             = "Fx|Network";     ///< using Network
            SMTG_CONSTEXPR const CString kFxPitchShift          = "Fx|Pitch Shift"; ///< Pitch Processing, Pitch Correction, Vocal Tuning...
            SMTG_CONSTEXPR const CString kFxRestoration         = "Fx|Restoration"; ///< Denoiser, Declicker,...
            SMTG_CONSTEXPR const CString kFxReverb              = "Fx|Reverb";      ///< Reverberation, Room Simulation, Convolution Reverb...
            SMTG_CONSTEXPR const CString kFxSpatial             = "Fx|Spatial";     ///< MonoToStereo, StereoEnhancer,...
            SMTG_CONSTEXPR const CString kFxSurround            = "Fx|Surround";    ///< dedicated to surround processing: LFE Splitter, Bass Manager...
            SMTG_CONSTEXPR const CString kFxTools               = "Fx|Tools";       ///< Volume, Mixer, Tuner...
            SMTG_CONSTEXPR const CString kFxVocals              = "Fx|Vocals";      ///< Tools dedicated to Vocals

            SMTG_CONSTEXPR const CString kInstrument            = "Instrument";         ///< Effect used as instrument (sound generator), not as insert
            SMTG_CONSTEXPR const CString kInstrumentDrum        = "Instrument|Drum";    ///< Instrument for Drum sounds
            SMTG_CONSTEXPR const CString kInstrumentExternal    = "Instrument|External";///< External Instrument (wrapped Hardware)
            SMTG_CONSTEXPR const CString kInstrumentPiano       = "Instrument|Piano";   ///< Instrument for Piano sounds
            SMTG_CONSTEXPR const CString kInstrumentSampler     = "Instrument|Sampler"; ///< Instrument based on Samples
            SMTG_CONSTEXPR const CString kInstrumentSynth       = "Instrument|Synth";   ///< Instrument based on Synthesis
            SMTG_CONSTEXPR const CString kInstrumentSynthSampler = "Instrument|Synth|Sampler";  ///< Instrument based on Synthesis and Samples

            SMTG_CONSTEXPR const CString kAmbisonics            = "Ambisonics";     ///< used for Ambisonics channel (FX or Panner/Mixconverter/Up-Mixer/Down-Mixer when combined with other category)
            SMTG_CONSTEXPR const CString kAnalyzer              = "Analyzer";       ///< Meter, Scope, FFT-Display, not selectable as insert plug-in
            SMTG_CONSTEXPR const CString kNoOfflineProcess      = "NoOfflineProcess";   ///< will be NOT used for plug-in offline processing (will work as normal insert plug-in)
            SMTG_CONSTEXPR const CString kOnlyARA               = "OnlyARA";        ///< used for plug-ins that require ARA to operate (will not work as normal insert plug-in)
            SMTG_CONSTEXPR const CString kOnlyOfflineProcess    = "OnlyOfflineProcess"; ///< used for plug-in offline processing  (will not work as normal insert plug-in)
            SMTG_CONSTEXPR const CString kOnlyRealTime          = "OnlyRT";         ///< indicates that it supports only realtime process call, no processing faster than realtime
            SMTG_CONSTEXPR const CString kSpatial               = "Spatial";        ///< used for SurroundPanner
            SMTG_CONSTEXPR const CString kSpatialFx             = "Spatial|Fx";     ///< used for SurroundPanner and as insert effect
            SMTG_CONSTEXPR const CString kUpDownMix             = "Up-Downmix";     ///< used for Mixconverter/Up-Mixer/Down-Mixer

            SMTG_CONSTEXPR const CString kMono                  = "Mono";           ///< used for Mono only plug-in [optional]
            SMTG_CONSTEXPR const CString kStereo                = "Stereo";         ///< used for Stereo only plug-in [optional]
            SMTG_CONSTEXPR const CString kSurround              = "Surround";       ///< used for Surround only plug-in [optional]

        } /* namespace PlugType */
    } /* namespace Vst */
} /* namespace Steinberg */




#endif /* _3RD_PARTY_STEINBERG_VST3_VST_PLUGTYPE_H_ */
