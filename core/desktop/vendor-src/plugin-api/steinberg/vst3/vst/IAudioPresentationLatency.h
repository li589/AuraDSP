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

#ifndef _3RD_PARTY_STEINBERG_VST3_VST_IAUDIOPRESENTATIONLATENCY_H_
#define _3RD_PARTY_STEINBERG_VST3_VST_IAUDIOPRESENTATIONLATENCY_H_

#include <steinberg/vst3/base/FUnknown.h>
#include <steinberg/vst3/vst/Types.h>

namespace Steinberg
{
    namespace Vst
    {
        /**
         * Extended IAudioProcessor interface for a component.
         *
         * Inform the plug-in about how long from the moment of generation/acquiring (from file or from Input)
         * it will take for its input to arrive, and how long it will take for its output to be presented (to output or to speaker).
         *
         * @note for Input Presentation Latency: when reading from file, the first plug-in will have an input presentation latency
         * set to zero. When monitoring audio input from an audio device, the initial input latency is the input latency of the audio
         * device itself.
         *
         * @note for Output Presentation Latency: when writing to a file, the last plug-in will have an output presentation latency
         * set to zero.
         *
         * When the output of this plug-in is connected to an audio device, the initial output latency is the output
         * latency of the audio device itself.
         *
         * A value of zero either means no latency or an unknown latency.
         *
         * Each plug-in adding a latency (returning a none zero value for IAudioProcessor::getLatencySamples) will modify the input
         * presentation latency of the next plug-ins in the mixer routing graph and will modify the output presentation latency
         * of the previous plug-ins.
         *
         * @see @ref IAudioProcessor
         * @see @ref IComponent
         */
        #include <steinberg/vst3/base/WarningsPush.h>
        class IAudioPresentationLatency : public FUnknown
        {
        public:
            /**
             * Informs the plug-in about the Audio Presentation Latency in samples for a given
             * direction (kInput/kOutput) and bus index.
             */
            virtual tresult PLUGIN_API setAudioPresentationLatencySamples(BusDirection dir, int32 busIndex, uint32 latencyInSamples) = 0;

            static const FUID iid;
        };
        #include <steinberg/vst3/base/WarningsPop.h>

    } /* namespace Vst */
} /* namespace Steinberg */

#endif /* _3RD_PARTY_STEINBERG_VST3_VST_IAUDIOPRESENTATIONLATENCY_H_ */
