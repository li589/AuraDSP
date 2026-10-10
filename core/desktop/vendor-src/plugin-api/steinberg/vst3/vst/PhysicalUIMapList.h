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

#ifndef _3RD_PARTY_STEINBERG_VST3_VST_PHYSICALUIMAPLIST_H_
#define _3RD_PARTY_STEINBERG_VST3_VST_PHYSICALUIMAPLIST_H_

#include <steinberg/vst3/vst/NoteExpression.h>

#include <steinberg/vst3/base/AlignPush.h>

namespace Steinberg
{
    namespace Vst
    {
        /**
         * Physical UI Type
         */
        typedef uint32 PhysicalUITypeID;

        /**
         * PhysicalUITypeIDs describes the type of Physical UI (PUI) which could be
         * associated to a note expression.
         * @see PhysicalUIMap
         */
        enum PhysicalUITypeIDs
        {
            /**
             * absolute X position when touching keys of PUIs. Range [0=left, 0.5=middle, 1=right]
             */
            kPUIXMovement = 0,

            /**
             * absolute Y position when touching keys of PUIs. Range [0=bottom/near, 0.5=center, 1=top/far]
             */
            kPUIYMovement,

            /**
             * pressing a key down on keys of PUIs. Range [0=No Pressure, 1=Full Pressure]
             */
            kPUIPressure,

            /**
             * count of current defined PUIs
             */
            kPUITypeCount,

            /**
             * indicates an invalid or not initialized PUI type
             */
            kInvalidPUITypeID = 0xFFFFFFFF
        };

        /**
         * PhysicalUIMap describes a mapping of a noteExpression Type to a Physical UI Type.
         * It is used in PhysicalUIMapList.
         * @see PhysicalUIMapList
         */
        struct PhysicalUIMap
        {
            /**
             * This represents the physical UI. /see PhysicalUITypeIDs, this is set by the caller of
             * getPhysicalUIMapping
             */
            PhysicalUITypeID physicalUITypeID;

            /**
             * This represents the associated noteExpression TypeID to the given physicalUITypeID. This
             * will be filled by the plug-in in the call getPhysicalUIMapping, set it to kInvalidTypeID if
             * no Note Expression is associated to the given PUI.
             */
            NoteExpressionTypeID noteExpressionTypeID;
        };

        /**
         * PhysicalUIMapList describes a list of PhysicalUIMap
         * @see INoteExpressionPhysicalUIMapping
         */
        struct PhysicalUIMapList
        {
            /**
             * Count of entries in the map array, set by the caller of getPhysicalUIMapping.
             */
            uint32 count;

            /**
             * Pointer to a list of PhysicalUIMap containing count entries.
             */
            PhysicalUIMap* map;
        };

    } /* namespace Vst */
} /* namespace Steinberg */

#include <steinberg/vst3/base/AlignPop.h>

#endif /* _3RD_PARTY_STEINBERG_VST3_VST_PHYSICALUIMAPLIST_H_ */
