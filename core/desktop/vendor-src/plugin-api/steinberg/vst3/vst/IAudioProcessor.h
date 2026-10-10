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

#ifndef _3RD_PARTY_STEINBERG_VST3_VST_IAUDIOPROCESSOR_H_
#define _3RD_PARTY_STEINBERG_VST3_VST_IAUDIOPROCESSOR_H_

#include <steinberg/vst3/vst/Speaker.h>
#include <steinberg/vst3/vst/PlugType.h>
#include <steinberg/vst3/vst/ProcessData.h>
#include <steinberg/vst3/vst/IComponent.h>

/**
 * Class Category Name for Audio Processor Component
 */
#ifndef kVstAudioEffectClass
    #define kVstAudioEffectClass "Audio Module Class"
#endif /* kVstAudioEffectClass */

namespace Steinberg
{
    namespace Vst
    {
        /**
         * Audio processing interface: Vst::IAudioProcessor
         * This interface must always be supported by audio processing plug-ins.
         */
        #include <steinberg/vst3/base/WarningsPush.h>
        class IAudioProcessor : public FUnknown
        {
            public:
                /**
                 * Try to set (host => plug-in) a wanted arrangement for inputs and outputs.
                 * The host should always deliver the same number of input and output busses than the plug-in
                 * needs (see @ref IComponent::getBusCount). The plug-in has 3 possibilities to react on this
                 * setBusArrangements call:
                 *   1. The plug-in accepts these arrangements, then it should modify, if needed, its busses to match
                 *      these new arrangements (later on asked by the host with IComponent::getBusInfo () or
                 *      IAudioProcessor::getBusArrangement ()) and then should return kResultTrue.
                 *   2. The plug-in does not accept or support these requested arrangements for all
                 *      inputs/outputs or just for some or only one bus, but the plug-in can try to adapt its current
                 *      arrangements according to the requested ones (requested arrangements for kMain busses should be
                 *      handled with more priority than the ones for kAux busses), then it should modify its busses arrangements
                 *      and should return kResultFalse.
                 *   3. Same than the point 2 above the plug-in does not support these requested arrangements but the plug-in
                 *      cannot find corresponding arrangements, the plug-in could keep its current arrangement or fall back to
                 *      a default arrangement by modifying its busses arrangements and should return kResultFalse.
                 *
                 * @param inputs pointer to an array of @ref SpeakerArrangement
                 * @param numIns number of @ref SpeakerArrangement in inputs array
                 * @param outputs pointer to an array of @ref SpeakerArrangement
                 * @param numOuts number of /ref SpeakerArrangement in outputs array
                 * @return kResultTrue when Arrangements is supported and is the current one, else kResultFalse.
                 */
                virtual tresult PLUGIN_API setBusArrangements(SpeakerArrangement *inputs, int32 numIns, SpeakerArrangement *outputs, int32 numOuts) = 0;

                /**
                 * Gets the bus arrangement for a given direction (input/output) and index.
                 * @note IComponent::getBusInfo() and IAudioProcessor::getBusArrangement() should be always return the same
                 * information about the busses arrangements.
                 */
                virtual tresult PLUGIN_API getBusArrangement(BusDirection dir, int32 index, SpeakerArrangement & arr) = 0;

                /**
                 * Asks if a given sample size is supported see @ref SymbolicSampleSizes.
                 */
                virtual tresult PLUGIN_API canProcessSampleSize(int32 symbolicSampleSize) = 0;

                /**
                 * Gets the current Latency in samples.
                 *
                 * The returned value defines the group delay or the latency of the plug-in. For example, if the plug-in internally needs
                 * to look in advance (like compressors) 512 samples then this plug-in should report 512 as latency.
                 *
                 * If during the use of the plug-in this latency change, the plug-in has to inform the host by
                 * using IComponentHandler::restartComponent (kLatencyChanged), this could lead to audio playback interruption
                 * because the host has to recompute its internal mixer delay compensation.
                 * Note that for player live recording this latency should be zero or small.
                 */
                virtual uint32 PLUGIN_API getLatencySamples() = 0;

                /**
                 * Called in disable state (setActive not called with true) before setProcessing is called and processing will begin.
                 */
                virtual tresult PLUGIN_API setupProcessing(ProcessSetup & setup) = 0;

                /**
                 * Informs the plug-in about the processing state. This will be called before any process calls
                 * start with true and after with false.
                 *
                 * @note that setProcessing (false) may be called after setProcessing (true) without any process calls.
                 * @note this function could be called in the UI or in Processing Thread, thats why the plug-in
                 * should only light operation (no memory allocation or big setup reconfiguration),
                 * this could be used to reset some buffers (like Delay line or Reverb).
                 *
                 * The host has to be sure that it is called only when the plug-in is enable (setActive (true) was called).
                 */
                virtual tresult PLUGIN_API setProcessing(TBool state) = 0;

                /**
                 * The Process call, where all information (parameter changes, event, audio buffer) are passed.
                 */
                virtual tresult PLUGIN_API process(ProcessData & data) = 0;

                /**
                 * Gets tail size in samples. For example, if the plug-in is a Reverb plug-in and it knows that
                 * the maximum length of the Reverb is 2sec, then it has to return in getTailSamples()
                 * (in VST2 it was getGetTailSize ()): 2*sampleRate.
                 *
                 * This information could be used by host for offline processing, process optimization and
                 * downmix (avoiding signal cut (clicks)).
                 *
                 * It should return:
                 *   - kNoTail when no tail
                 *   - x * sampleRate when x Sec tail.
                 *   - kInfiniteTail when infinite tail.
                 */
                virtual uint32 PLUGIN_API getTailSamples() = 0;

            public:
                static const FUID iid;
        };
        #include <steinberg/vst3/base/WarningsPop.h>

    } /* namespace Vst */
} /* namespace Steinberg */

#endif /* _3RD_PARTY_STEINBERG_VST3_VST_IAUDIOPROCESSOR_H_ */
