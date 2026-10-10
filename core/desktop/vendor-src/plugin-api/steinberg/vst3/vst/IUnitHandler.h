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

#ifndef _3RD_PARTY_STEINBERG_VST3_VST_IUNITHANDLER_H_
#define _3RD_PARTY_STEINBERG_VST3_VST_IUNITHANDLER_H_

#include <steinberg/vst3/base/FUnknown.h>
#include <steinberg/vst3/base/IBStream.h>
#include <steinberg/vst3/vst/UnitInfo.h>

namespace Steinberg
{
    namespace Vst
    {
        /**
         * Host callback for unit support.
         * Host callback interface, used with IUnitInfo.
         * Retrieve via queryInterface from IComponentHandler.
         * @see @ref vst3Units, @ref IUnitInfo
        */
        #include <steinberg/vst3/base/WarningsPush.h>
        class IUnitHandler: public FUnknown
        {
            public:
                /**
                 * Notify host when a module is selected in plug-in GUI.
                 */
                virtual tresult PLUGIN_API notifyUnitSelection(UnitID unitId) = 0;

                /**
                 * Tell host that the plug-in controller changed a program list (rename, load, PitchName changes).
                 * @param listId is the specified program list ID to inform.
                 * @param programIndex when kAllProgramInvalid, all program information is invalid, otherwise only
                 *        the program of given index.
                 */
                virtual tresult PLUGIN_API notifyProgramListChange(ProgramListID listId, int32 programIndex) = 0;

            public:
                static const FUID iid;
        };
        #include <steinberg/vst3/base/WarningsPop.h>

    } /* namespace Vst */
} /* namespace Steinberg */

#endif /* _3RD_PARTY_STEINBERG_VST3_VST_IUNITHANDLER_H_ */
