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

#ifndef _3RD_PARTY_STEINBERG_VST3_VST_IMIDILEARN2_H_
#define _3RD_PARTY_STEINBERG_VST3_VST_IMIDILEARN2_H_

#include <steinberg/vst3/base/FUnknown.h>
#include <steinberg/vst3/vst/Midi2.h>

#include <steinberg/vst3/base/AlignPush.h>

namespace Steinberg
{
    namespace Vst
    {
        /**
         * MIDI Learn interface: Vst::IMidiLearn2
         *
         * If this interface is implemented by the edit controller, the host will call this method whenever
         * there is live MIDI-CC input for the plug-in. This way, the plug-in can change its MIDI-CC parameter
         * mapping and notify the host using IComponentHandler::restartComponent with the
         * kMidiCCAssignmentChanged flag.
         *
         * Use this if you want to implement custom MIDI-Learn functionality in your plug-in.
         *
         * @extends IEditController
         * @since 3.8.0
         */
        #include <steinberg/vst3/base/WarningsPush.h>
        class IMidiLearn2: public FUnknown
        {
            public:
                /**
                 * Called on live input MIDI 2.0-CC change associated to a given bus index and MIDI channel
                 *
                 * @note UI-thread & (Initialized | Connected)
                 */
                virtual tresult PLUGIN_API onLiveMidi2ControllerInput(BusIndex index, MidiChannel channel, Midi2Controller midiCC) = 0;

                /**
                 * Called on live input MIDI 1.0-CC change associated to a given bus index and MIDI channel
                 *
                 * @note UI-thread & (Initialized | Connected)
                 */
                virtual tresult PLUGIN_API onLiveMidi1ControllerInput(BusIndex index, MidiChannel channel, CtrlNumber midiCC) = 0;

            public:
                static const FUID iid;
        };
        #include <steinberg/vst3/base/WarningsPop.h>

    } /* namespace Vst */
} /* namespace Steinberg */

#include <steinberg/vst3/base/AlignPop.h>




#endif /* _3RD_PARTY_STEINBERG_VST3_VST_IMIDILEARN2_H_ */
