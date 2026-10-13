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

#ifndef _3RD_PARTY_STEINBERG_VST3_VST_IEDITCONTROLLERHOSTEDITING_H_
#define _3RD_PARTY_STEINBERG_VST3_VST_IEDITCONTROLLERHOSTEDITING_H_

#include <steinberg/vst3/base/FUnknown.h>
#include <steinberg/vst3/vst/Types.h>
#include <steinberg/vst3/vst/ParameterInfo.h>

namespace Steinberg
{
    namespace Vst
    {
        /**
         * Parameter Editing from host
         *
         * If this interface is implemented by the edit controller, and when performing edits from outside
         * the plug-in (host / remote) of a not automatable and not read-only, and not hidden flagged parameter (kind of helper parameter),
         * the host will start with a beginEditFromHost before calling setParamNormalized and end with an endEditFromHost.
         * Here the sequence that the host will call:
         *
         * @example
         *   //------------------------------------------------------------------------
         *   plugEditController->beginEditFromHost (id);
         *   plugEditController->setParamNormalized (id, value);
         *   plugEditController->setParamNormalized (id, value + 0.1);
         *   // ...
         *   plugEditController->endEditFromHost (id);
         *   @see @ref IEditController
         */
        #include <steinberg/vst3/base/WarningsPush.h>
        class IEditControllerHostEditing: public FUnknown
        {
            public:
                /**
                 * Called before a setParamNormalized sequence, a endEditFromHost will be call at the end of the editing action.
                 */
                virtual tresult PLUGIN_API beginEditFromHost(ParamID paramID) = 0;

                /**
                 * Called after a beginEditFromHost and a sequence of setParamNormalized.
                 */
                virtual tresult PLUGIN_API endEditFromHost(ParamID paramID) = 0;

            public:
                static const FUID iid;
        };
        #include <steinberg/vst3/base/WarningsPop.h>

    } /* namespace Vst */
} /* namespace Steinberg */

#endif /* _3RD_PARTY_STEINBERG_VST3_VST_IEDITCONTROLLERHOSTEDITING_H_ */
