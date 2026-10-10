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

#ifndef _3RD_PARTY_STEINBERG_VST3_VST_BUSINFO_H_
#define _3RD_PARTY_STEINBERG_VST3_VST_BUSINFO_H_

#include <steinberg/vst3/vst/Types.h>
#include <steinberg/vst3/base/PFactoryInfo.h>

#include <steinberg/vst3/base/AlignPush.h>

namespace Steinberg
{
    namespace Vst
    {
        /**
         * Standard value for PFactoryInfo::flags
         */
        const int32 kDefaultFactoryFlags = PFactoryInfo::kUnicode;

        /** vstBus VST busses
         *
         * Bus Description
         *
         * A bus can be understood as a "collection of data channels" belonging together.
         * It describes a data input or a data output of the plug-in.
         * A VST component can define any desired number of busses.
         * Dynamic usage of busses is handled in the host by activating and deactivating busses.
         * All busses are initially inactive.
         * The component has to define the maximum number of supported busses and it has to
         * define which of them have to be activated by default after instantiation of the plug-in (This is
         * only a wish, the host is allow to not follow it, and only activate the first bus for example).
         * A host that can handle multiple busses, allows the user to activate busses which are initially all inactive.
         * The kMain busses have to place before any others kAux busses.
         * See also: IComponent::getBusInfo, IComponent::activateBus
         */

        /**
         * Bus media types
         */
        enum MediaTypes
        {
            /**
             * Audio
             */
            kAudio = 0,

            /**
             * Events
             */
            kEvent,

            kNumMediaTypes
        };

        /**
         * Bus directions
         */
        enum BusDirections
        {
            /**
             * Input bus
             */
            kInput = 0,

            /**
             * Output bus
             */
            kOutput
        };

        /**
         * Bus types
         */
        enum BusTypes
        {
            /**
             * Main bus
             */
            kMain = 0,

            /**
             * Auxiliary bus (sidechain)
             */
            kAux
        };

        /**
         * BusInfo:
         * This is the structure used with getBusInfo, informing the host about what is a specific given bus.
         * @see Steinberg::Vst::IComponent::getBusInfo
         */
        struct BusInfo
        {
            /**
             * Media type - has to be a value of @ref MediaTypes
             */
            MediaType mediaType;

            /**
             * Input or output @ref BusDirections
             */
            BusDirection direction;

            /**
             * Number of channels (if used then need to be recheck after
             * @ref IAudioProcessor::setBusArrangements is called).
             * For a bus of type MediaTypes::kEvent the channelCount corresponds
             * to the number of supported MIDI channels by this bus
             */
            int32 channelCount;

            /**
             * Name of the bus
             */
            String128 name;

            /**
             * Main or aux - has to be a value of @ref BusTypes
             */
            BusType busType;

            /**
             * flags - a combination of @ref BusFlags
             */
            uint32 flags;

            enum BusFlags
            {
                /**
                 * The bus should be activated by the host per default on instantiation (activateBus call is requested).
                 * By default a bus is inactive.
                 */
                kDefaultActive = 1 << 0,

                /**
                 * The bus does not contain ordinary audio data, but data used for control changes at sample rate.
                 * The data is in the same format as the audio data [-1..1].
                 * A host has to prevent unintended routing to speakers to prevent damage.
                 * Only valid for audio media type busses.
                 */
                kIsControlVoltage = 1 << 1
            };
        };
    } /* namespace Vst */
} /* namespace Steinberg */

#include <steinberg/vst3/base/AlignPop.h>

#endif /* _3RD_PARTY_STEINBERG_VST3_VST_BUSINFO_H_ */
