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

#ifndef _3RD_PARTY_STEINBERG_VST3_VST_ROUTINGINFO_H_
#define _3RD_PARTY_STEINBERG_VST3_VST_ROUTINGINFO_H_

#include <steinberg/vst3/vst/Types.h>
#include <steinberg/vst3/base/PFactoryInfo.h>
#include <steinberg/vst3/base/IBStream.h>
#include <steinberg/vst3/base/IPluginBase.h>

#include <steinberg/vst3/base/AlignPush.h>

namespace Steinberg
{
    namespace Vst
    {
        /**
         * I/O modes
         */
        enum IoModes
        {
            /**
             * 1:1 Input / Output. Only used for Instruments. See \ref vst3IoMode
             */
            kSimple = 0,

            /**
             * n:m Input / Output. Only used for Instruments.
             */
            kAdvanced,

            /**
             * Plug-in used in an offline processing context.
             */
            kOfflineProcessing
        };

        /**
         * Routing Information:
         * When the plug-in supports multiple I/O busses, a host may want to know how the busses are related. The
         * relation of an event-input-channel to an audio-output-bus in particular is of interest to the host
         * (in order to relate MIDI-tracks to audio-channels)
         * @see IComponent::getRoutingInfo, @ref vst3Routing
         */
        struct RoutingInfo
        {
            MediaType mediaType;    ///< media type see \ref MediaTypes
            int32 busIndex;         ///< bus index
            int32 channel;          ///< channel (-1 for all channels)
        };

    } /* namespace Vst */
} /* namespace Steinberg */

#include <steinberg/vst3/base/AlignPop.h>

#endif /* _3RD_PARTY_STEINBERG_VST3_VST_ROUTINGINFO_H_ */
