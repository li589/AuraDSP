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

#ifndef _3RD_PARTY_STEINBERG_VST3_VST_UNITINFO_H_
#define _3RD_PARTY_STEINBERG_VST3_VST_UNITINFO_H_

#include <steinberg/vst3/vst/Types.h>

#include <steinberg/vst3/base/AlignPush.h>

namespace Steinberg
{
    namespace Vst
    {
        /**
         * Special UnitIDs for UnitInfo
         */
        static const UnitID kRootUnitId = 0;        ///< identifier for the top level unit (root)
        static const UnitID kNoParentUnitId = -1;   ///< used for the root unit which does not have a parent.

        /**
         * Special ProgramListIDs for UnitInfo
         */
        static const ProgramListID kNoProgramListId = -1;   ///< no programs are used in the unit.

        /**
         * Basic Unit Description.
         * @see IUnitInfo
         */
        struct UnitInfo
        {
            UnitID id;                      ///< unit identifier
            UnitID parentUnitId;            ///< identifier of parent unit (kNoParentUnitId: does not apply, this unit is the root)
            String128 name;                 ///< name, optional for the root component, required otherwise
            ProgramListID programListId;    ///< id of program list used in unit (kNoProgramListId = no programs used in this unit)
        };

        /**
         * Basic Program List Description.
         * @see IUnitInfo
         */
        struct ProgramListInfo
        {
            ProgramListID id;               ///< program list identifier
            String128 name;                 ///< name of program list
            int32 programCount;             ///< number of programs in this list
        };

        /**
         * Special programIndex value for IUnitHandler::notifyProgramListChange
         */
        static const int32 kAllProgramInvalid = -1;     ///< all program information is invalid

    } /* namespace Vst */
} /* namespace Steinberg */

#include <steinberg/vst3/base/AlignPop.h>


#endif /* _3RD_PARTY_STEINBERG_VST3_VST_UNITINFO_H_ */
