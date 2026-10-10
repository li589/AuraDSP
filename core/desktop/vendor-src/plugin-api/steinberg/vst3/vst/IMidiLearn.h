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

#ifndef _3RD_PARTY_STEINBERG_VST3_VST_IMIDILEARN_H_
#define _3RD_PARTY_STEINBERG_VST3_VST_IMIDILEARN_H_

#include <steinberg/vst3/base/FUnknown.h>
#include <steinberg/vst3/vst/Types.h>

namespace Steinberg
{
    namespace Vst
    {
        /**
         * MIDI Learn interface: Vst::IMidiLearn.
         *
         * If this interface is implemented by the edit controller, the host will call this method whenever
         * there is live MIDI-CC input for the plug-in. This way, the plug-in can change its MIDI-CC parameter
         * mapping and notify the host using the IComponentHandler::restartComponent with the
         * kMidiCCAssignmentChanged flag.
         *
         * Use this if you want to implement custom MIDI-Learn functionality in your plug-in.
         *
         * @example
         * //------------------------------------------------
         * // in MyController class declaration
         * class MyController : public Vst::EditController, public Vst::IMidiLearn
         * {
         *     // ...
         *     //--- IMidiLearn ---------------------------------
         *     tresult PLUGIN_API onLiveMIDIControllerInput(int32 busIndex, int16 channel,
         *                                                  CtrlNumber midiCC) SMTG_OVERRIDE;
         *     // ...
         *     OBJ_METHODS (MyController, Vst::EditController)
         *     DEFINE_INTERFACES
         *         // ...
         *         DEF_INTERFACE (Vst::IMidiLearn)
         *     END_DEFINE_INTERFACES (Vst::EditController)
         *     //...
         * }
         *
         * //------------------------------------------------
         * // in mycontroller.cpp
         * #include "pluginterfaces/vst/ivstmidilearn.h
         * namespace Steinberg {
         *     namespace Vst {
         *         DEF_CLASS_IID (IMidiLearn)
         *     }
         * }
         *
         * //------------------------------------------------------------------------
         * tresult PLUGIN_API MyController::onLiveMIDIControllerInput(int32 busIndex,
         *                                                            int16 channel, CtrlNumber midiCC)
         * {
         *     // if we are not in doMIDILearn (triggered by a UI button for example)
         *     // or wrong channel then return
         *     if (!doMIDILearn || busIndex != 0 || channel != 0 || midiLearnParamID == InvalidParamID)
         *         return kResultFalse;
         *
         *     // adapt our internal MIDICC -> parameterID mapping
         *     midiCCMapping[midiCC] = midiLearnParamID;
         *
         *     // new mapping then inform the host that our MIDI assignment has changed
         *     if (auto componentHandler = getComponentHandler ())
         *     {
         *         componentHandler->restartComponent (kMidiCCAssignmentChanged);
         *     }
         *
         *     return kResultTrue;
         * }
         */
        #include <steinberg/vst3/base/WarningsPush.h>
        class IMidiLearn: public FUnknown
        {
            public:
                /**
                 * Called on live input MIDI-CC change associated to a given bus index and MIDI channel
                 */
                virtual tresult PLUGIN_API onLiveMIDIControllerInput(int32 busIndex, int16 channel, CtrlNumber midiCC) = 0;

            public:
                static const FUID iid;
        };
        #include <steinberg/vst3/base/WarningsPop.h>

    } /* namespace Vst */
} /* namespace Steinberg */

#endif /* _3RD_PARTY_STEINBERG_VST3_VST_IMIDILEARN_H_ */
