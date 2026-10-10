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

#ifndef _3RD_PARTY_STEINBERG_VST3_VST_MIDI2_H_
#define _3RD_PARTY_STEINBERG_VST3_VST_MIDI2_H_

#include <steinberg/vst3/vst/BusInfo.h>
#include <steinberg/vst3/vst/Types.h>

#include <steinberg/vst3/base/AlignPush.h>

namespace Steinberg
{
    namespace Vst
    {

        using MidiGroup = uint8;
        using MidiChannel = uint8;
        using BusIndex = int32;

        /**
         * Midi2Controller
         * describes a MIDI 2.0 Registered or Assignable Controller
         */
        struct Midi2Controller
        {
            uint8 bank : 7; // msb
            TBool registered : 1; // true: registered, false: assignable
            uint8 index : 7; // lsb
            TBool reserved : 1;
        };

        struct Midi2ControllerParamIDAssignment
        {
            ParamID pId;
            BusIndex busIndex;
            MidiChannel channel;
            Midi2Controller controller;
        };

        struct Midi2ControllerParamIDAssignmentList
        {
            uint32 count;
            Midi2ControllerParamIDAssignment *map;
        };

        struct Midi1ControllerParamIDAssignment
        {
            ParamID pId;
            BusIndex busIndex;
            MidiChannel channel;
            CtrlNumber controller;
        };

        struct Midi1ControllerParamIDAssignmentList
        {
            uint32 count;
            Midi1ControllerParamIDAssignment *map;
        };

    } /* namespace Vst */
} /* namespace Steinberg */

#include <steinberg/vst3/base/AlignPop.h>


#endif /* _3RD_PARTY_STEINBERG_VST3_VST_MIDI2_H_ */
