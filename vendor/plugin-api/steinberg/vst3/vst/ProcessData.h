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

#ifndef _3RD_PARTY_STEINBERG_VST3_VST_PROCESSDATA_H_
#define _3RD_PARTY_STEINBERG_VST3_VST_PROCESSDATA_H_

#include <steinberg/vst3/vst/Speaker.h>
#include <steinberg/vst3/vst/IComponent.h>
#include <steinberg/vst3/vst/IEventList.h>
#include <steinberg/vst3/vst/IParameterChanges.h>
#include <steinberg/vst3/vst/ProcessContext.h>

#include <steinberg/vst3/base/AlignPush.h>

namespace Steinberg
{
    namespace Vst
    {
        /**
         * Component Flags used as classFlags in PClassInfo2
         */
        enum ComponentFlags
        {
            /**
             * Component can be run on remote computer
             */
            kDistributable          = 1 << 0,

            /**
             * Component supports simple IO mode (or works in simple mode anyway) see @ref vst3IoMode
             */
            kSimpleModeSupported    = 1 << 1
        };

        /**
         * Symbolic sample size.
         * @see ProcessSetup, ProcessData
         */
        enum SymbolicSampleSizes
        {
            /**
             * 32-bit precision
             */
            kSample32,

            /**
             * 64-bit precision
             */
            kSample64
        };

        /**
         * Processing mode informs the plug-in about the context and at which frequency the process call is called.
         * VST3 defines 3 modes:
         *   - kRealtime
         *   - kPrefetch
         *   - kOffline
         * @note about Process Modes switching:
         *   - Switching between kRealtime and kPrefetch process modes are done in realtime thread without need of calling
         *     IAudioProcessor::setupProcessing, the plug-in should check in process call the member processMode of ProcessData
         *     in order to know in which mode it is processed.
         *   - Switching between kRealtime (or kPrefetch) and kOffline requires that the host calls IAudioProcessor::setupProcessing
         *     in order to inform the plug-in about this mode change.
         *
         * @see ProcessSetup, ProcessData
         */
        enum ProcessModes
        {
            /**
             * Realtime processing: each process call is called at a realtime frequency
             * (defined by [numSamples of ProcessData] / samplerate). The plug-in should always
             * try to process as fast as possible in order to let enough time slice to other plug-ins.
             */
            kRealtime,
            /**
             * Prefetch processing: each process call could be called at a variable frequency (jitter, slower / faster
             * than realtime), the plug-in should process at the same quality level than realtime, plug-in must not slow
             * down to realtime (e.g. disk streaming)! The host should avoid to process in kPrefetch mode such sampler based plug-in.
             */
            kPrefetch,
             /**
              * Offline processing: each process call could be faster than realtime or slower, higher quality than realtime could
              * be used. plug-ins using disk streaming should be sure that they have enough time in the process call for streaming,
              * if needed by slowing down to realtime or slower.
              */
            kOffline
        };

        /**
         * kNoTail to be returned by getTailSamples when no tail is wanted
         * @see IAudioProcessor::getTailSamples
         */
        static const uint32 kNoTail = 0;

        /**
         * kInfiniteTail to be returned by getTailSamples when infinite tail is wanted
         * @see IAudioProcessor::getTailSamples
         */
        static const uint32 kInfiniteTail = kMaxInt32u;

        /**
         * Audio processing setup.
         * @see IAudioProcessor::setupProcessing
         */
        struct ProcessSetup
        {
            /**
             * Processing mode @see @ref ProcessModes
             */
            int32 processMode;

            /**
             * Sample size @see @ref SymbolicSampleSizes
             */
            int32 symbolicSampleSize;

            /**
             * Maximum number of samples per audio block
             */
            int32 maxSamplesPerBlock;

            /**
             * Sample rate
             */
            SampleRate sampleRate;
        };

        /**
         * Processing buffers of an audio bus.
         *
         * This structure contains the processing buffer for each channel of an audio bus.
         *   - The number of channels (numChannels) must always match the current bus arrangement.
         *     It could be set to value '0' when the host wants to flush the parameters (when the plug-in is not processed).
         *   - The size of the channel buffer array must always match the number of channels. So the host
         *     must always supply an array for the channel buffers, regardless if the bus is active or not.
         *     However, if an audio bus is currently inactive, the actual sample buffer addresses are safe to be null.
         *   - The silence flag is set when every sample of the according buffer has the value '0'. It is
         *     intended to be used as help for optimizations allowing a plug-in to reduce processing activities.
         *     But even if this flag is set for a channel, the channel buffers must still point to valid memory!
         *     This flag is optional. A host is free to support it or not.
         *
         *  @see @ref ProcessData
         */
        struct AudioBusBuffers
        {
            /**
             * Number of audio channels in bus
             */
            int32 numChannels;

            /**
             * Bitset silence state per channel
             */
            uint64 silenceFlags;

            union
            {
                /**
                 * Sample buffers to process with 32-bit precision
                 */
                Sample32** channelBuffers32;

                /**
                 * Sample buffers to process with 64-bit precision
                 */
                Sample64** channelBuffers64;
            };
        };

        /**
         * Any data needed in audio processing.
         *
         * The host prepares AudioBusBuffers for each input/output bus,
         * regardless of the bus activation state. Bus buffer indices always match
         * with bus indices used in IComponent::getBusInfo of media type kAudio.
         * @see @ref AudioBusBuffers, @ref IParameterChanges, @ref IEventList, @ref ProcessContext, @ref IProcessContextRequirements
         */
        struct ProcessData
        {
            /**
             * Processing mode - value of @see @ref ProcessModes
             */
            int32 processMode;

            /**
             * Sample size - value of @see @ref SymbolicSampleSizes
             */
            int32 symbolicSampleSize;

            /**
             * Number of samples to process
             */
            int32 numSamples;

            /**
             * Number of audio input busses
             */
            int32 numInputs;

            /**
             * Number of audio output busses
             */
            int32 numOutputs;

            /**
             * Buffers of input busses
             */
            AudioBusBuffers *inputs;

            /**
             * Buffers of output busses
             */
            AudioBusBuffers *outputs;

            /**
             * Incoming parameter changes for this block
             */
            IParameterChanges *inputParameterChanges;

            /**
             * Outgoing parameter changes for this block (optional)
             */
            IParameterChanges *outputParameterChanges;

            /**
             * Incoming events for this block (optional)
             */
            IEventList *inputEvents;

            /**
             * Outgoing events for this block (optional)
             */
            IEventList *outputEvents;

            /**
             * Processing context (optional, but most welcome)
             */
            ProcessContext *processContext;
        };

    } /* namespace Vst */
} /* namespace Steinberg */

#include <steinberg/vst3/base/AlignPop.h>

#endif /* _3RD_PARTY_STEINBERG_VST3_VST_PROCESSDATA_H_ */
