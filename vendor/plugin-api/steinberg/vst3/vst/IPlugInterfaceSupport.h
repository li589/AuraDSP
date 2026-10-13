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

#ifndef _3RD_PARTY_STEINBERG_VST3_VST_IPLUGINTERFACESUPPORT_H_
#define _3RD_PARTY_STEINBERG_VST3_VST_IPLUGINTERFACESUPPORT_H_

#include <steinberg/vst3/base/FUnknown.h>

namespace Steinberg
{
    namespace Vst
    {
        /**
         * Host callback interface for an edit controller.
         *
         * Allows a plug-in to ask the host if a given plug-in interface is supported/used by the host.
         * It is implemented by the hostContext given when the component is initialized.
         *
         * @example
         * tresult PLUGIN_API MyPluginController::initialize (FUnknown* context)
         * {
         *     // ...
         *     FUnknownPtr<IPlugInterfaceSupport> plugInterfaceSupport (context);
         *     if (plugInterfaceSupport)
         *     {
         *         if (plugInterfaceSupport->isPlugInterfaceSupported (IMidiMapping::iid) == kResultTrue)
         *             // IMidiMapping is used by the host
         *     }
         *     // ...
         * }
         *
         * @see @ref IPluginBase
         */
        #include <steinberg/vst3/base/WarningsPush.h>
        class IPlugInterfaceSupport: public FUnknown
        {
            public:
                /**
                 * @return kResultTrue if the associated interface to the given _iid is
                 * supported/used by the host.
                 */
                virtual tresult PLUGIN_API isPlugInterfaceSupported(const TUID _iid) = 0;

            public:
                static const FUID iid;
        };
        #include <steinberg/vst3/base/WarningsPop.h>

    } /* namespace Vst */
} /* namespace Steinberg */


#endif /* _3RD_PARTY_STEINBERG_VST3_VST_IPLUGINTERFACESUPPORT_H_ */
