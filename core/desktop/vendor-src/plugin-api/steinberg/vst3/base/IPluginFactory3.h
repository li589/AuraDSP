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

#ifndef _3RD_PARTY_STEINBERG_VST3_BASE_IPLUGINFACTORY3_H_
#define _3RD_PARTY_STEINBERG_VST3_BASE_IPLUGINFACTORY3_H_

#include <steinberg/vst3/base/FUnknown.h>
#include <steinberg/vst3/base/PFactoryInfo.h>
#include <steinberg/vst3/base/PClassInfoW.h>
#include <steinberg/vst3/base/IPluginFactory2.h>

namespace Steinberg
{
    /**
     * Class factory supporting PClassInfoW (Version 3)
     */
    #include <steinberg/vst3/base/WarningsPush.h>
    class IPluginFactory3: public IPluginFactory2
    {
        public:
            /**
             * Returns the unicode class info for a given index.
             */
            virtual tresult PLUGIN_API getClassInfoUnicode(int32 index, PClassInfoW *info) = 0;

            /**
             * Receives information about host
             */
            virtual tresult PLUGIN_API setHostContext(FUnknown *context) = 0;

        public:
            static const FUID iid;
    };
    #include <steinberg/vst3/base/WarningsPop.h>

} /* namespace Steinberg */

#endif /* _3RD_PARTY_STEINBERG_VST3_BASE_IPLUGINFACTORY3_H_ */
