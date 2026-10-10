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

#ifndef _3RD_PARTY_STEINBERG_VST3_VST_IPARAMETERFINDER_H_
#define _3RD_PARTY_STEINBERG_VST3_VST_IPARAMETERFINDER_H_

#include <steinberg/vst3/base/FUnknown.h>
#include <steinberg/vst3/vst/Types.h>

namespace Steinberg
{
    namespace Vst
    {
        /**
         * Extension for IPlugView to find view parameters (lookup value under mouse support)
         *
         * It is highly recommended to implement this interface.
         * A host can implement important functionality when a plug-in supports this interface.
         *
         * For example, all Steinberg hosts require this interface in order to support the "AI Knob".
         */
        #include <steinberg/vst3/base/WarningsPush.h>
        class IParameterFinder: public FUnknown
        {
        public:
            /**
             * Find out which parameter in plug-in view is at given position (relative to plug-in view).
             */
            virtual tresult PLUGIN_API findParameter (int32 xPos, int32 yPos, ParamID & resultTag /*out*/) = 0;

            static const FUID iid;
        };
        #include <steinberg/vst3/base/WarningsPop.h>

    } /* namespace Vst */
} /* namespace Steinberg */



#endif /* _3RD_PARTY_STEINBERG_VST3_VST_IPARAMETERFINDER_H_ */
