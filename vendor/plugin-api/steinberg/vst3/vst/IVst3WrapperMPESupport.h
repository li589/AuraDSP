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

#ifndef _3RD_PARTY_STEINBERG_VST3_VST_IVST3WRAPPERMPESUPPORT_H_
#define _3RD_PARTY_STEINBERG_VST3_VST_IVST3WRAPPERMPESUPPORT_H_

#include <steinberg/vst3/base/FUnknown.h>

namespace Steinberg
{
    namespace Vst
    {
        /**
         * Wrapper MPE Support interface.
         *
         * Implemented on wrappers that support MPE to Note Expression translation.
         *
         * By default, MPE input processing is enabled, the masterChannel will be zero, the memberBeginChannel
         * will be one and the memberEndChannel will be 14.
         *
         * As MPE is a subset of the VST3 Note Expression feature, mapping from the three MPE expressions is
         * handled via the INoteExpressionPhysicalUIMapping interface.
         */
        #include <steinberg/vst3/base/WarningsPush.h>
        class IVst3WrapperMPESupport: public FUnknown
        {
            public:
                /**
                 * Enable or disable MPE processing
                 * @param state true to enable, false to disable MPE processing
                 * @return kResultTrue on success
                 */
                virtual tresult PLUGIN_API enableMPEInputProcessing(TBool state) = 0;

                /**
                 * Setup the MPE processing
                 * @param masterChannel MPE master channel (zero based)
                 * @param memberBeginChannel MPE member begin channel (zero based)
                 * @param memberEndChannel MPE member end channel (zero based)
                 * @return kResultTrue on success
                 */
                virtual tresult PLUGIN_API setMPEInputDeviceSettings(int32 masterChannel,
                                                                     int32 memberBeginChannel,
                                                                     int32 memberEndChannel) = 0;
            public:
                static const FUID iid;
        };
        #include <steinberg/vst3/base/WarningsPop.h>

    } /* namespace Vst */
} /* namespace Steinberg */

#endif /* _3RD_PARTY_STEINBERG_VST3_VST_IVST3WRAPPERMPESUPPORT_H_ */
