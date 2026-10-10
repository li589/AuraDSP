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

#ifndef _3RD_PARTY_STEINBERG_VST3_VST_IUNITHANDLER2_H_
#define _3RD_PARTY_STEINBERG_VST3_VST_IUNITHANDLER2_H_

#include <steinberg/vst3/base/FUnknown.h>
#include <steinberg/vst3/base/IBStream.h>
#include <steinberg/vst3/vst/UnitInfo.h>

namespace Steinberg
{
    namespace Vst
    {
        /**
         * Host callback for extended unit support.
         * Host callback interface, used with IUnitInfo.
         * Retrieve via queryInterface from IComponentHandler.
         *
         * The plug-in has the possibility to inform the host with notifyUnitByBusChange that something has
         * changed in the bus - unit assignment, the host then has to recall IUnitInfo::getUnitByBus in order
         * to get the new relations between busses and unit.
         * @see @ref vst3Units, @ref IUnitHandler
         */
        #include <steinberg/vst3/base/WarningsPush.h>
        class IUnitHandler2: public FUnknown
        {
            public:
                /**
                 * Tell host that assignment Unit-Bus defined by IUnitInfo::getUnitByBus has changed.
                 */
                virtual tresult PLUGIN_API notifyUnitByBusChange() = 0;

            public:
                static const FUID iid;
        };
        #include <steinberg/vst3/base/WarningsPop.h>

    } /* namespace Vst */
} /* namespace Steinberg */

#endif /* _3RD_PARTY_STEINBERG_VST3_VST_IUNITHANDLER2_H_ */
