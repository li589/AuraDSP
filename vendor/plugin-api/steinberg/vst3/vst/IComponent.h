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

#ifndef _3RD_PARTY_STEINBERG_VST3_VST_IVSTCOMPONENT_H_
#define _3RD_PARTY_STEINBERG_VST3_VST_IVSTCOMPONENT_H_

#include <steinberg/vst3/vst/Types.h>

#include <steinberg/vst3/base/IBStream.h>
#include <steinberg/vst3/base/IPluginBase.h>

#include <steinberg/vst3/vst/BusInfo.h>
#include <steinberg/vst3/vst/RoutingInfo.h>

namespace Steinberg
{
    namespace Vst
    {
        /**
         * Component base interface: Vst::IComponent
         *
         * This is the basic interface for a VST component and must always be supported.
         * It contains the common parts of any kind of processing class. The parts that
         * are specific to a media type are defined in a separate interface. An implementation
         * component must provide both the specific interface and IComponent.
         * @see IPluginBase
         */
        #include <steinberg/vst3/base/WarningsPush.h>
        class IComponent : public IPluginBase
        {
            public:
                /**
                 * Called before initializing the component to get information about the controller class.
                 */
                virtual tresult PLUGIN_API getControllerClassId(TUID classId) = 0;

                /**
                 * Called before 'initialize' to set the component usage (optional).
                 * @see @ref IoModes
                 */
                virtual tresult PLUGIN_API setIoMode(IoMode mode) = 0;

                /**
                 * Called after the plug-in is initialized. See @ref MediaTypes, BusDirections
                 */
                virtual int32 PLUGIN_API getBusCount(MediaType type, BusDirection dir) = 0;

                /**
                 * Called after the plug-in is initialized. See @ref MediaTypes, BusDirections
                 */
                virtual tresult PLUGIN_API getBusInfo(MediaType type, BusDirection dir, int32 index, BusInfo & bus /*out*/) = 0;

                /**
                 * Retrieves routing information (to be implemented when more than one regular input or output bus exists).
                 * The inInfo always refers to an input bus while the returned outInfo must refer to an output bus!
                 */
                virtual tresult PLUGIN_API getRoutingInfo(RoutingInfo & inInfo, RoutingInfo & outInfo /*out*/) = 0;

                /**
                 * Called upon (de-)activating a bus in the host application. The plug-in should only processed
                 * an activated bus, the host could provide less see \ref AudioBusBuffers in the process call
                 * (see @ref IAudioProcessor::process) if last busses are not activated. An already activated bus
                 * does not need to be reactivated after a IAudioProcessor::setBusArrangements call.
                 */
                virtual tresult PLUGIN_API activateBus(MediaType type, BusDirection dir, int32 index, TBool state) = 0;

                /**
                 * Activates / deactivates the component.
                 */
                virtual tresult PLUGIN_API setActive(TBool state) = 0;

                /**
                 * Sets complete state of component.
                 */
                virtual tresult PLUGIN_API setState(IBStream *state) = 0;

                /**
                 * Retrieves complete state of component.
                 */
                virtual tresult PLUGIN_API getState(IBStream *state) = 0;

            public:
                static const FUID iid;
        };
        #include <steinberg/vst3/base/WarningsPop.h>

    } /* namespace Vst */
} /* namespace Steinberg */

#endif /* _3RD_PARTY_STEINBERG_VST3_VST_IVSTCOMPONENT_H_ */
