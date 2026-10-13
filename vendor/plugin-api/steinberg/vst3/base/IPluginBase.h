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

#ifndef _3RD_PARTY_STEINBERG_VST3_BASE_IPLUGINBASE_H_
#define _3RD_PARTY_STEINBERG_VST3_BASE_IPLUGINBASE_H_

#include <steinberg/vst3/base/FUnknown.h>
#include <steinberg/vst3/base/Platform.h>

namespace Steinberg
{

    //------------------------------------------------------------------------
    /**
     * Basic interface to a plug-in component: IPluginBase.
     *
     * The host uses this interface to initialize and to terminate the plug-in component.
     * The context that is passed to the initialize method contains any interface to the
     * host that the plug-in will need to work. These interfaces can vary from category to category.
     * A list of supported host context interfaces should be included in the documentation
     * of a specific category.
     */
    #include <steinberg/vst3/base/WarningsPush.h>
    class IPluginBase: public FUnknown
    {
        public:
            /**
             * The host passes a number of interfaces as context to initialize the plug-in class.
             * @param context, passed by the host, is mandatory and should implement IHostApplication
             * @note Extensive memory allocations etc. should be performed in this method rather than in
             * the class' constructor! If the method does NOT return kResultOk, the object is released
             * immediately. In this case terminate is not called!
             */
            virtual tresult PLUGIN_API initialize(FUnknown *context) = 0;

            /**
             * This function is called before the plug-in is unloaded and can be used for
             * cleanups. You have to release all references to any host application interfaces.
             */
            virtual tresult PLUGIN_API terminate() = 0;

        public:
            static const FUID iid;
    };
    #include <steinberg/vst3/base/WarningsPop.h>

} /* namespace Steinberg */

#endif /* _3RD_PARTY_STEINBERG_VST3_BASE_IPLUGINBASE_H_ */
