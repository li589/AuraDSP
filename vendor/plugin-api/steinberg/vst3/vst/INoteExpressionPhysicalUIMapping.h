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

#ifndef _3RD_PARTY_STEINBERG_VST3_VST_INOTEEXPRESSIONPHYSICALUIMAPPING_H_
#define _3RD_PARTY_STEINBERG_VST3_VST_INOTEEXPRESSIONPHYSICALUIMAPPING_H_

#include <steinberg/vst3/base/FUnknown.h>
#include <steinberg/vst3/vst/PhysicalUIMapList.h>

namespace Steinberg
{
    namespace Vst
    {
        /**
         * Extended plug-in interface IEditController for note expression event support.
         *
         * With this plug-in interface, the host can retrieve the preferred physical mapping associated to note
         * expression supported by the plug-in.
         *
         * When the mapping changes (for example when switching presets) the plug-in needs
         * to inform the host about it via \ref IComponentHandler::restartComponent (kNoteExpressionChanged).
         *
         * @example
         *
         * //------------------------------------------------------------------------
         * // here an example of how a VST3 plug-in could support this INoteExpressionPhysicalUIMapping interface.
         * // we need to define somewhere the iids:
         *
         * //in MyController class declaration
         * class MyController: public Vst::EditController, public Vst::INoteExpressionPhysicalUIMapping
         * {
         *     // ...
         *     //--- INoteExpressionPhysicalUIMapping ---------------------------------
         *     tresult PLUGIN_API getPhysicalUIMapping (int32 busIndex, int16 channel, PhysicalUIMapList& list) SMTG_OVERRIDE;
         *
         *     // ...
         *     OBJ_METHODS (MyController, Vst::EditController)
         *     DEFINE_INTERFACES
         *         // ...
         *         DEF_INTERFACE (Vst::INoteExpressionPhysicalUIMapping)
         *     END_DEFINE_INTERFACES (Vst::EditController)
         *     //...
         * }
         *
         * // In mycontroller.cpp
         * #include "pluginterfaces/vst/ivstnoteexpression.h"
         *
         * namespace Steinberg
         * {
         *     namespace Vst
         *     {
         *         DEF_CLASS_IID (INoteExpressionPhysicalUIMapping)
         *     }
         * }
         *
         * //------------------------------------------------------------------------
         * tresult PLUGIN_API MyController::getPhysicalUIMapping (int32 busIndex, int16 channel, PhysicalUIMapList& list)
         * {
         *     if (busIndex == 0 && channel == 0)
         *     {
         *         for (uint32 i = 0; i < list.count; ++i)
         *         {
         *             NoteExpressionTypeID type = kInvalidTypeID;
         *             if (kPUIXMovement == list.map[i].physicalUITypeID)
         *                 list.map[i].noteExpressionTypeID = kCustomStart + 1;
         *             else if (kPUIYMovement == list.map[i].physicalUITypeID)
         *                 list.map[i].noteExpressionTypeID = kCustomStart + 2;
         *         }
         *         return kResultTrue;
         *     }
         *     return kResultFalse;
         * }
         */
        #include <steinberg/vst3/base/WarningsPush.h>
        class INoteExpressionPhysicalUIMapping: public FUnknown
        {
            public:
                /**
                 * Fills the list of mapped [physical UI (in) - note expression (out)] for a given bus index
                 * and channel.
                 */
                virtual tresult PLUGIN_API getPhysicalUIMapping(int32 busIndex, int16 channel, PhysicalUIMapList & list) = 0;

            public:
                static const FUID iid;
        };
        #include <steinberg/vst3/base/WarningsPop.h>

    } /* namespace Vst */
} /* namespace Steinberg */


#endif /* _3RD_PARTY_STEINBERG_VST3_VST_INOTEEXPRESSIONPHYSICALUIMAPPING_H_ */
