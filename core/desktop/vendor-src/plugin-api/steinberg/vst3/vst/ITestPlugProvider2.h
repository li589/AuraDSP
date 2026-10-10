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

#ifndef _3RD_PARTY_STEINBERG_VST3_VST_ITESTPLUGPROVIDER2_H_
#define _3RD_PARTY_STEINBERG_VST3_VST_ITESTPLUGPROVIDER2_H_

#include <steinberg/vst3/base/FUnknown.h>
#include <steinberg/vst3/base/IStringResult.h>
#include <steinberg/vst3/base/IString.h>
#include <steinberg/vst3/base/IPluginFactory.h>

#include <steinberg/vst3/vst/IComponent.h>
#include <steinberg/vst3/vst/IEditController.h>
#include <steinberg/vst3/vst/ITestPlugProvider.h>

namespace Steinberg
{
    namespace Vst
    {
        /**
         * Test Helper extension.
         */
        #include <steinberg/vst3/base/WarningsPush.h>
        class ITestPlugProvider2: public ITestPlugProvider
        {
            public:
                /**
                 * Get the plugin factory.
                 *
                 * The reference count of the returned factory object is not increased when calling this
                 * function.
                 */
                virtual IPluginFactory * PLUGIN_API getPluginFactory() = 0;

            public:
                static const FUID iid;
        };
        #include <steinberg/vst3/base/WarningsPop.h>

    } /* namespace Vst */
} /* namespace Steinberg */

#endif /* _3RD_PARTY_STEINBERG_VST3_VST_ITESTPLUGPROVIDER2_H_ */
