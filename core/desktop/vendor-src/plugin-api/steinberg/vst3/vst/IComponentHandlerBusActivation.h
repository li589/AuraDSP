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

#ifndef _3RD_PARTY_STEINBERG_VST3_VST_ICOMPONENTHANDLERBUSACTIVATION_H_
#define _3RD_PARTY_STEINBERG_VST3_VST_ICOMPONENTHANDLERBUSACTIVATION_H_

#include <steinberg/vst3/base/FUnknown.h>
#include <steinberg/vst3/vst/Types.h>

namespace Steinberg
{
    namespace Vst
    {
        /**
         * Extended host callback interface for an edit controller
         *
         * Allows the plug-in to request the host to activate or deactivate a specific bus.
         * If the host accepts this request, it will call later on \ref IComponent::activateBus.
         * This is particularly useful for instruments with more than 1 outputs, where the user could request
         * from the plug-in UI a given output bus activation.
         *
         * @example somewhere in your code when you need to inform the host to enable a specific Bus.
         *   FUnknownPtr<IComponentHandlerBusActivation> busActivation (componentHandler);
         *   if (busActivation)
         *   {
         *      // here we want to activate our audio input sidechain (the 2cd input bus: index 1)
         *      busActivation->requestBusActivation (kAudio, kInput, 1, true);
         *   }
         *
         * @see @ref IComponentHandler
         */
        #include <steinberg/vst3/base/WarningsPush.h>
        class IComponentHandlerBusActivation: public FUnknown
        {
            public:
                /**
                 * request the host to activate or deactivate a specific bus.
                 */
                virtual tresult PLUGIN_API requestBusActivation (MediaType type, BusDirection dir, int32 index, TBool state) = 0;

            public:
                static const FUID iid;
        };
        #include <steinberg/vst3/base/WarningsPop.h>

    } /* namespace Vst */
} /* namespace Steinberg */

#endif /* _3RD_PARTY_STEINBERG_VST3_VST_ICOMPONENTHANDLERBUSACTIVATION_H_ */
