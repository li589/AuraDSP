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

#ifndef _3RD_PARTY_STEINBERG_VST3_VST_IUNITDATA_H_
#define _3RD_PARTY_STEINBERG_VST3_VST_IUNITDATA_H_

#include <steinberg/vst3/base/FUnknown.h>
#include <steinberg/vst3/base/IBStream.h>
#include <steinberg/vst3/vst/UnitInfo.h>

namespace Steinberg
{
    namespace Vst
    {
        /**
         * Component extension to access unit data.
         *
         * A component can support unit preset data via this interface or
         * program list data (IProgramListData).
         * @see @ref vst3ProgramLists
         */
        #include <steinberg/vst3/base/WarningsPush.h>
        class IUnitData: public FUnknown
        {
            public:
                /**
                 * Returns kResultTrue if the specified unit supports export and import of preset data.
                 */
                virtual tresult PLUGIN_API unitDataSupported(UnitID unitID) = 0;

                /**
                 * Gets the preset data for the specified unit.
                 */
                virtual tresult PLUGIN_API getUnitData(UnitID unitId, IBStream *data) = 0;

                /**
                 * Sets the preset data for the specified unit.
                 */
                virtual tresult PLUGIN_API setUnitData(UnitID unitId, IBStream *data) = 0;

            public:
                static const FUID iid;
        };
        #include <steinberg/vst3/base/WarningsPop.h>

    } /* namespace Vst */
} /* namespace Steinberg */

#endif /* _3RD_PARTY_STEINBERG_VST3_VST_IUNITDATA_H_ */
