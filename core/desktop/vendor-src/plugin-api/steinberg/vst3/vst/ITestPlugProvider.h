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

#ifndef _3RD_PARTY_STEINBERG_VST3_VST_ITESTPLUGPROVIDER_H_
#define _3RD_PARTY_STEINBERG_VST3_VST_ITESTPLUGPROVIDER_H_

#include <steinberg/vst3/base/FUnknown.h>
#include <steinberg/vst3/base/IStringResult.h>
#include <steinberg/vst3/base/IString.h>
#include <steinberg/vst3/base/IPluginFactory.h>

#include <steinberg/vst3/vst/IComponent.h>
#include <steinberg/vst3/vst/IEditController.h>

namespace Steinberg
{
    namespace Vst
    {
        /**
         * Test Helper.
         *
         * This class provides access to the component and the controller of a plug-in when running a unit
         * test (@see ITest).
         *
         * You get this interface as the context argument in the ITestFactory::createTests method.
         */
        #include <steinberg/vst3/base/WarningsPush.h>
        class ITestPlugProvider: public FUnknown
        {
            public:
                /**
                 * Get the component of the plug-in.
                 *
                 * The reference count of the component is increased in this function and you need to call
                 * releasePlugIn when done with the component.
                 */
                virtual IComponent* PLUGIN_API getComponent() = 0;

                /**
                 * Get the controller of the plug-in.
                 *
                 * The reference count of the controller is increased in this function and you need to call
                 * releasePlugIn when done with the controller.
                 */
                virtual IEditController* PLUGIN_API getController() = 0;

                /**
                 * Release the component and/or controller
                 */
                virtual tresult PLUGIN_API releasePlugIn(IComponent *component,
                                                         IEditController *controller) = 0;

                /**
                 * Get the sub categories of the plug-in
                 */
                virtual tresult PLUGIN_API getSubCategories (IStringResult& result) const = 0;

                /**
                 * Get the component UID of the plug-in
                 */
                virtual tresult PLUGIN_API getComponentUID(TUID uid) const = 0;

            public:
                static const FUID iid;
        };
        #include <steinberg/vst3/base/WarningsPop.h>

    } /* namespace Vst */
} /* namespace Steinberg */

#endif /* _3RD_PARTY_STEINBERG_VST3_VST_ITESTPLUGPROVIDER_H_ */
