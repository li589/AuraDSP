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

#ifndef _3RD_PARTY_STEINBERG_VST3_VST_IPREFETCHABLESUPPORT_H_
#define _3RD_PARTY_STEINBERG_VST3_VST_IPREFETCHABLESUPPORT_H_

#include <steinberg/vst3/base/FUnknown.h>
#include <steinberg/vst3/vst/PrefetchableSupport.h>

namespace Steinberg
{
    namespace Vst
    {
        /**
         * Indicates that the plug-in could or not support Prefetch (dynamically).
         *
         * The plug-in should implement this interface if it needs to dynamically change between prefetchable or not.
         * By default (without implementing this interface) the host decides in which mode the plug-in is processed.
         * For more info about the prefetch processing mode check the ProcessModes::kPrefetch documentation.
         *
         * @example
         *
         * tresult PLUGIN_API myPlug::getPrefetchableSupport (PrefetchableSupport& prefetchable)
         * {
         *     prefetchable = kIsNeverPrefetchable;
         *
         *     switch (myPrefetchableMode)
         *     {
         *         case 0: prefetchable = kIsNeverPrefetchable; break;
         *         case 1: prefetchable = kIsYetPrefetchable; break;
         *         case 2: prefetchable = kIsNotYetPrefetchable; break;
         *     }
         *     return kResultOk;
         * }
         */
        #include <steinberg/vst3/base/WarningsPush.h>
        class IPrefetchableSupport: public FUnknown
        {
            public:
                /**
                 * Retrieve the current prefetch support. Use IComponentHandler::restartComponent
                 * (kPrefetchableSupportChanged) to inform the host that this support has changed.
                 */
                virtual tresult PLUGIN_API getPrefetchableSupport(PrefetchableSupport & prefetchable /*out*/) = 0;

            public:
                static const FUID iid;
        };
        #include <steinberg/vst3/base/WarningsPop.h>

    } /* namespace Vst */
} /* namespace Steinberg */

#endif /* _3RD_PARTY_STEINBERG_VST3_VST_IPREFETCHABLESUPPORT_H_ */
