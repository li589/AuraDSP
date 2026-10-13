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

#ifndef _3RD_PARTY_STEINBERG_VST3_VST_IPROGRAMLISTDATA_H_
#define _3RD_PARTY_STEINBERG_VST3_VST_IPROGRAMLISTDATA_H_

#include <steinberg/vst3/base/FUnknown.h>
#include <steinberg/vst3/base/IBStream.h>
#include <steinberg/vst3/vst/UnitInfo.h>

namespace Steinberg
{
    namespace Vst
    {
        /**
         * Component extension to access program list data.
         *
         * A component can support program list data via this interface or/and
         * unit preset data (IUnitData).
         * @see @ref IUnitData, @ref vst3MultitimbralPrograms
         */
        #include <steinberg/vst3/base/WarningsPush.h>
        class IProgramListData: public FUnknown
        {
            public:
                /**
                 * Returns kResultTrue if the given Program List ID supports Program Data.
                 */
                virtual tresult PLUGIN_API programDataSupported(ProgramListID listId) = 0;

                /**
                 * Gets for a given program list ID and program index the program Data.
                 */
                virtual tresult PLUGIN_API getProgramData(ProgramListID listId, int32 programIndex, IBStream* data) = 0;

                /**
                 * Sets for a given program list ID and program index a program Data.
                 */
                virtual tresult PLUGIN_API setProgramData(ProgramListID listId, int32 programIndex, IBStream* data) = 0;

            public:
                static const FUID iid;
        };
        #include <steinberg/vst3/base/WarningsPop.h>

    } /* namespace Vst */
} /* namespace Steinberg */

#endif /* _3RD_PARTY_STEINBERG_VST3_VST_IPROGRAMLISTDATA_H_ */
