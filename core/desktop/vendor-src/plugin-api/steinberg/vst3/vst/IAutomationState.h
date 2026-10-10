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

#ifndef _3RD_PARTY_STEINBERG_VST3_VST_IAUTOMATIONSTATE_H_
#define _3RD_PARTY_STEINBERG_VST3_VST_IAUTOMATIONSTATE_H_

#include <steinberg/vst3/base/FUnknown.h>

namespace Steinberg
{
    namespace Vst
    {
        /**
         * Extended plug-in interface IEditController.
         * Hosts can inform the plug-in about its current automation state (Read/Write/Nothing).
         */
        #include <steinberg/vst3/base/WarningsPush.h>
        class IAutomationState: public FUnknown
        {
            public:
                enum AutomationStates : int32
                {
                    kNoAutomation   = 0,      ///< Not Read and not Write
                    kReadState      = 1 << 0,    ///< Read state
                    kWriteState     = 1 << 1,   ///< Write state

                    kReadWriteState = kReadState | kWriteState, ///< Read and Write enable
                };

                /**
                 * Sets the current Automation state.
                 */
                virtual tresult PLUGIN_API setAutomationState (int32 state) = 0;

            public:
                static const FUID iid;
        };
        #include <steinberg/vst3/base/WarningsPop.h>

    } /* namespace Vst */
} /* namespace Steinberg */

#endif /* _3RD_PARTY_STEINBERG_VST3_VST_IAUTOMATIONSTATE_H_ */
