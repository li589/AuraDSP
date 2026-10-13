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

#ifndef _3RD_PARTY_STEINBERG_VST3_VST_IUNITINFO_H_
#define _3RD_PARTY_STEINBERG_VST3_VST_IUNITINFO_H_

#include <steinberg/vst3/base/FUnknown.h>
#include <steinberg/vst3/base/IBStream.h>
#include <steinberg/vst3/vst/UnitInfo.h>

namespace Steinberg
{
    namespace Vst
    {
        /**
         * Edit controller extension to describe the plug-in structure.
         *
         * IUnitInfo describes the internal structure of the plug-in.
         *   - The root unit is the component itself, so getUnitCount must return 1 at least.
         *   - The root unit id has to be 0 (kRootUnitId).
         *   - Each unit can reference one program list - this reference must not change.
         *   - Each unit, using a program list, references one program of the list.
         * @see @ref vst3Units, IUnitHandler
         */
        #include <steinberg/vst3/base/WarningsPush.h>
        class IUnitInfo: public FUnknown
        {
            public:
                /**
                 * Returns the flat count of units.
                 */
                virtual int32 PLUGIN_API getUnitCount() = 0;

                /**
                 * Gets UnitInfo for a given index in the flat list of unit.
                 */
                virtual tresult PLUGIN_API getUnitInfo(int32 unitIndex, UnitInfo & info /*out*/) = 0;

                /**
                 * Gets the count of Program List.
                 */
                virtual int32 PLUGIN_API getProgramListCount() = 0;

                /**
                 * Gets for a given index the Program List Info.
                 */
                virtual tresult PLUGIN_API getProgramListInfo(int32 listIndex, ProgramListInfo & info /*out*/) = 0;

                /**
                 * Gets for a given program list ID and program index its program name.
                 */
                virtual tresult PLUGIN_API getProgramName(ProgramListID listId, int32 programIndex, String128 name /*out*/) = 0;

                /**
                 * Gets for a given program list ID, program index and attributeId the associated attribute value.
                 */
                virtual tresult PLUGIN_API getProgramInfo(ProgramListID listId, int32 programIndex, CString attributeId /*in*/, String128 attributeValue /*out*/) = 0;

                /**
                 * Returns kResultTrue if the given program index of a given program list ID supports PitchNames.
                 */
                virtual tresult PLUGIN_API hasProgramPitchNames(ProgramListID listId, int32 programIndex) = 0;

                /**
                 * Gets the PitchName for a given program list ID, program index and pitch.
                 * If PitchNames are changed the plug-in should inform the host with IUnitHandler::notifyProgramListChange.
                 */
                virtual tresult PLUGIN_API getProgramPitchName(ProgramListID listId, int32 programIndex, int16 midiPitch, String128 name /*out*/) = 0;

                /**
                 * Gets the current selected unit.
                 */
                virtual UnitID PLUGIN_API getSelectedUnit() = 0;

                /**
                 * Sets a new selected unit.
                 */
                virtual tresult PLUGIN_API selectUnit(UnitID unitId) = 0;

                /**
                 * Gets the according unit if there is an unambiguous relation between a channel or a bus and a unit.
                 * This method mainly is intended to find out which unit is related to a given MIDI input channel.
                 */
                virtual tresult PLUGIN_API getUnitByBus(MediaType type, BusDirection dir, int32 busIndex, int32 channel, UnitID & unitId /*out*/) = 0;

                /**
                 * Receives a preset data stream.
                 *   - If the component supports program list data (IProgramListData), the destination of the data
                 *     stream is the program specified by list-Id and program index (first and second parameter)
                 *   - If the component supports unit data (IUnitData), the destination is the unit specified by the first
                 *     parameter - in this case parameter programIndex is < 0).
                 */
                virtual tresult PLUGIN_API setUnitProgramData(int32 listOrUnitId, int32 programIndex, IBStream *data) = 0;

            public:
                static const FUID iid;
        };
        #include <steinberg/vst3/base/WarningsPop.h>

    } /* namespace Vst */
} /* namespace Steinberg */

#endif /* _3RD_PARTY_STEINBERG_VST3_VST_IUNITINFO_H_ */
