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

#ifndef _3RD_PARTY_STEINBERG_VST3_VST_IVST3TOAAXWRAPPER_H_
#define _3RD_PARTY_STEINBERG_VST3_VST_IVST3TOAAXWRAPPER_H_

#include <steinberg/vst3/base/FUnknown.h>

namespace Steinberg
{
    namespace Vst
    {
        /**
         * VST 3 to AAX Wrapper interface.
         * Informs the plug-in that a VST 3 to AAX wrapper is used between the plug-in and the real host.
         * Implemented by the AAX Wrapper.
         */
        #include <steinberg/vst3/base/WarningsPush.h>
        class IVst3ToAAXWrapper: public FUnknown
        {
            public:
                static const FUID iid;
        };
        #include <steinberg/vst3/base/WarningsPop.h>

    } /* namespace Vst */
} /* namespace Steinberg */

#endif /* _3RD_PARTY_STEINBERG_VST3_VST_IVST3TOAAXWRAPPER_H_ */
