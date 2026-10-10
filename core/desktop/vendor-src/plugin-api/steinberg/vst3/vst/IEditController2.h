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

#ifndef _3RD_PARTY_STEINBERG_VST3_VST_IEDITCONTROLLER2_H_
#define _3RD_PARTY_STEINBERG_VST3_VST_IEDITCONTROLLER2_H_

#include <steinberg/vst3/base/IBStream.h>
#include <steinberg/vst3/base/IPluginBase.h>
#include <steinberg/vst3/vst/Types.h>
#include <steinberg/vst3/vst/ParameterInfo.h>
#include <steinberg/vst3/vst/IEditController.h>

namespace Steinberg
{
    namespace Vst
    {
        /**
         * Edit controller component interface extension
         *
         * Extension to allow the host to inform the plug-in about the host Knob Mode,
         * and to open the plug-in about box or help documentation.
         *
         * @see @ref IEditController, @ref EditController
        */
        #include <steinberg/vst3/base/WarningsPush.h>
        class IEditController2: public FUnknown
        {
            public:
                /**
                 * Host could set the Knob Mode for the plug-in. Return kResultFalse means not supported mode.
                 * @see KnobModes.
                 */
                virtual tresult PLUGIN_API setKnobMode(KnobMode mode) = 0;

                /**
                 * Host could ask to open the plug-in help (could be: opening a PDF document or link to a web page).
                 * The host could call it with onlyCheck set to true for testing support of open Help.
                 * @return kResultFalse means not supported function.
                 */
                virtual tresult PLUGIN_API openHelp(TBool onlyCheck) = 0;

                /**
                 * Host could ask to open the plug-in about box.
                 * The host could call it with onlyCheck set to true for testing support of open AboutBox.
                 * @return kResultFalse means not supported function.
                 */
                virtual tresult PLUGIN_API openAboutBox(TBool onlyCheck) = 0;

            public:
                static const FUID iid;
        };
        #include <steinberg/vst3/base/WarningsPop.h>

    } /* namespace Vst */
} /* namespace Steinberg */

#endif /* _3RD_PARTY_STEINBERG_VST3_VST_IEDITCONTROLLER2_H_ */
