/*
 * Copyright 2025, Steinberg Media Technologies GmbH, All Rights Reserved
 * Copyright 2025 Linux Studio Plugins Project <lsp.plugin@gmail.com>
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

#ifndef _3RD_PARTY_STEINBERG_VST3_VST_IMIDIMAPPING2_H_
#define _3RD_PARTY_STEINBERG_VST3_VST_IMIDIMAPPING2_H_

#include <steinberg/vst3/base/FUnknown.h>
#include <steinberg/vst3/vst/Midi2.h>

#include <steinberg/vst3/base/AlignPush.h>

namespace Steinberg
{
    namespace Vst
    {
        /**
         * MIDI Mapping interface: Vst::IMidiMapping2
         * This interface replaces Vst::IMidiMapping to support the extended MIDI controllers in MIDI 2.0.
         * A MIDI 2.0 capable host first queries for the Vst::IMidiMapping2 interface and uses the old
         * Vst::IMidiMapping interface as a fallback.
         *
         * A plug-in can use the Vst::IPlugInterfaceSupport to check if the host supports Vst::IMidiMapping2.
         *
         * @extends IEditController
         * @since 3.8.0
         */
        #include <steinberg/vst3/base/WarningsPush.h>
        class IMidiMapping2: public FUnknown
        {
            public:
                /**
                 * Gets the number of MIDI 2.0 controller to parameter assignments
                 * @param direction input/output direction
                 * @return number of MIDI 2.0 controller to parameter assignments
                 * @note UI-thread & Connected
                 */
                virtual uint32 PLUGIN_API getNumMidi2ControllerAssignments(BusDirections direction) = 0;

                /**
                 * Gets MIDI 2.0 controller parameter assignments.
                 * The list is preallocated by the host and must be filled by the plug-in.
                 *
                 * @param direction input/output direction
                 * @param list list of assignments
                 * @return kResultTrue on success
                 * @note UI-thread & Connected
                 */
                virtual tresult PLUGIN_API getMidi2ControllerAssignments(BusDirections direction, const Midi2ControllerParamIDAssignmentList & list) = 0;

                /**
                 * Gets the number of MIDI 1.0 controller to parameter assignments
                 *
                 * @param direction input/output direction
                 * @return number of MIDI 1.0 controller to parameter assignments
                 * @note UI-thread & Connected
                 */
                virtual uint32 PLUGIN_API getNumMidi1ControllerAssignments(BusDirections direction) = 0;

                /**
                 * Gets MIDI 1.0 controller parameter assignments
                 *
                 * The list is preallocated by the host and must be filled by the plug-in
                 *
                 * @param direction input/output direction
                 * @param list list of assignments
                 * @return kResultTrue on success
                 * @note UI-thread & Connected
                 */
                virtual tresult PLUGIN_API getMidi1ControllerAssignments(BusDirections direction, const Midi1ControllerParamIDAssignmentList & list) = 0;

            public:
                static const FUID iid;
        };
        #include <steinberg/vst3/base/WarningsPop.h>


    } /* namespace Vst */
} /* namespace Steinberg */

#include <steinberg/vst3/base/AlignPop.h>




#endif /* _3RD_PARTY_STEINBERG_VST3_VST_IMIDIMAPPING2_H_ */
