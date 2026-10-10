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

#ifndef _3RD_PARTY_STEINBERG_VST3_VST_ICOMPONENTHANDLER_H_
#define _3RD_PARTY_STEINBERG_VST3_VST_ICOMPONENTHANDLER_H_

#include <steinberg/vst3/base/FUnknown.h>
#include <steinberg/vst3/vst/Types.h>
#include <steinberg/vst3/vst/ParameterInfo.h>

namespace Steinberg
{
    namespace Vst
    {
        /**
         * Host callback interface for an edit controller
         *
         * Allow transfer of parameter editing to component (processor) via host and support automation.
         * Cause the host to react on configuration changes (restartComponent).
         * @see @ref IEditController
         */
        #include <steinberg/vst3/base/WarningsPush.h>
        class IComponentHandler: public FUnknown
        {
            public:
                /**
                 * To be called before calling a performEdit (e.g. on mouse-click-down event).
                 * This must be called in the UI-Thread context!
                 */
                virtual tresult PLUGIN_API beginEdit(ParamID id) = 0;

                /**
                 * Called between beginEdit and endEdit to inform the handler that a given parameter has a new
                 * value. This must be called in the UI-Thread context!
                 */
                virtual tresult PLUGIN_API performEdit(ParamID id, ParamValue valueNormalized) = 0;

                /**
                 * To be called after calling a performEdit (e.g. on mouse-click-up event).
                 * This must be called in the UI-Thread context!
                 */
                virtual tresult PLUGIN_API endEdit(ParamID id) = 0;

                /**
                 * Instructs host to restart the component. This must be called in the UI-Thread context!
                 * @param flags is a combination of RestartFlags
                 */
                virtual tresult PLUGIN_API restartComponent(int32 flags) = 0;

            public:
                static const FUID iid;
        };
        #include <steinberg/vst3/base/WarningsPop.h>

    } /* namespace Vst */
} /* namespace Steinberg */

#endif /* _3RD_PARTY_STEINBERG_VST3_VST_ICOMPONENTHANDLER_H_ */
