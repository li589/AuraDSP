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

#ifndef _3RD_PARTY_STEINBERG_VST3_VST_IMIDIMAPPING_H_
#define _3RD_PARTY_STEINBERG_VST3_VST_IMIDIMAPPING_H_

#include <steinberg/vst3/base/FUnknown.h>
#include <steinberg/vst3/vst/Types.h>
#include <steinberg/vst3/vst/ParameterInfo.h>

namespace Steinberg
{
    namespace Vst
    {
        /**
         * MIDI Mapping interface
         *
         * MIDI controllers are not transmitted directly to a VST component. MIDI as hardware protocol has
         * restrictions that can be avoided in software. Controller data in particular come along with unclear
         * and often ignored semantics. On top of this they can interfere with regular parameter automation and
         * the host is unaware of what happens in the plug-in when passing MIDI controllers directly.
         *
         * So any functionality that is to be controlled by MIDI controllers must be exported as regular parameter.
         * The host will transform incoming MIDI controller data using this interface and transmit them as regular
         * parameter change. This allows the host to automate them in the same way as other parameters.
         * CtrlNumber can be a typical MIDI controller value extended to some others values like pitchbend or
         * aftertouch (see \ref ControllerNumbers).
         *
         * If the mapping has changed, the plug-in must call IComponentHandler::restartComponent (kMidiCCAssignmentChanged)
         * to inform the host about this change.
         *
         * @example
         *
         *   //--------------------------------------
         *   // in myeditcontroller.h
         *   class MyEditController: public EditControllerEx1, public IMidiMapping
         *   {
         *       //...
         *       //---IMidiMapping---------------------------
         *       tresult PLUGIN_API getMidiControllerAssignment (int32 busIndex, int16 channel, CtrlNumber midiControllerNumber, ParamID& id) SMTG_OVERRIDE;
         *       //---Interface---------
         *       OBJ_METHODS (MyEditController, EditControllerEx1)
         *       DEFINE_INTERFACES
         *           DEF_INTERFACE (IMidiMapping)
         *       END_DEFINE_INTERFACES (MyEditController)
         *       REFCOUNT_METHODS (MyEditController)
         *   };
         *
         *   //--------------------------------------
         *   // in myeditcontroller.cpp
         *   tresult PLUGIN_API MyEditController::getMidiControllerAssignment (int32 busIndex, int16 midiChannel, CtrlNumber midiControllerNumber, ParamID& tag)
         *   {
         *       // for my first Event bus and for MIDI channel 0 and for MIDI CC Volume only
         *       if (busIndex == 0 && midiChannel == 0 && midiControllerNumber == kCtrlVolume)
         *       {
         *           tag = kGainId;
         *           return kResultTrue;
         *       }
         *       return kResultFalse;
         *   }
         */
        #include <steinberg/vst3/base/WarningsPush.h>
        class IMidiMapping: public FUnknown
        {
            public:
                /**
                 * Gets an (preferred) associated ParamID for a given Input Event Bus index, channel and MIDI Controller.
                 * @param[in] busIndex - index of Input Event Bus
                 * @param[in] channel - channel of the bus
                 * @param[in] midiControllerNumber - see @ref ControllerNumbers for expected values (could be bigger than 127)
                 * @param[in] id - return the associated ParamID to the given midiControllerNumber
                 */
                virtual tresult PLUGIN_API getMidiControllerAssignment(int32 busIndex, int16 channel, CtrlNumber midiControllerNumber, ParamID & id /*out*/) = 0;

            public:
                static const FUID iid;
        };
        #include <steinberg/vst3/base/WarningsPop.h>

    } /* namespace Vst */
} /* namespace Steinberg */

#endif /* _3RD_PARTY_STEINBERG_VST3_VST_IMIDIMAPPING_H_ */
