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

#ifndef _3RD_PARTY_STEINBERG_VST3_VST_PARAMETERINFO_H_
#define _3RD_PARTY_STEINBERG_VST3_VST_PARAMETERINFO_H_

#include <steinberg/vst3/vst/Types.h>

#include <steinberg/vst3/base/AlignPush.h>

namespace Steinberg
{
    namespace Vst
    {
        /** Controller Parameter Info.
         *  A parameter info describes a parameter of the controller.
         *  The id must always be the same for a parameter as this uniquely identifies the parameter.
         */
        struct ParameterInfo
        {
            ParamID id;             ///< unique identifier of this parameter (named tag too)
            String128 title;        ///< parameter title (e.g. "Volume")
            String128 shortTitle;   ///< parameter shortTitle (e.g. "Vol")
            String128 units;        ///< parameter unit (e.g. "dB")
            int32 stepCount;        ///< number of discrete steps (0: continuous, 1: toggle, discrete value otherwise
                                    ///< (corresponding to max - min, for example: 127 for a min = 0 and a max = 127) - see \ref vst3ParameterIntro)
            ParamValue defaultNormalizedValue;  ///< default normalized value [0,1] (in case of discrete value: defaultNormalizedValue = defDiscreteValue / stepCount)
            UnitID unitId;          ///< id of unit this parameter belongs to (see @ref vst3Units)

            int32 flags;            ///< ParameterFlags (see below)
            enum ParameterFlags
            {
                /**
                 * No flags wanted (SDK 3.0.0)
                 */
                kNoFlags = 0,

                /**
                 * Parameter can be automated (SDK 3.0.0)
                 */
                kCanAutomate = 1 << 0,

                /**
                 * Parameter cannot be changed from outside the plug-in, implies that kCanAutomate is NOT set (SDK 3.0.0)
                 */
                kIsReadOnly = 1 << 1,

                /**
                 * Attempts to set the parameter value out of the limits will result in a wrap around (SDK 3.0.2)
                 */
                kIsWrapAround = 1 << 2,

                /**
                 * Parameter should be displayed as list in generic editor or automation editing (SDK 3.1.0)
                 */
                kIsList = 1 << 3,

                /**
                 * Parameter should be NOT displayed and cannot be changed from outside the plug-in.
                 * It implies that kCanAutomate is NOT set and kIsReadOnly is set (SDK 3.7.0)
                 */
                kIsHidden = 1 << 4,

                /**
                 * Parameter is a program change (unitId gives info about associated unit - see \ref vst3ProgramLists) (SDK 3.0.0)
                 */
                kIsProgramChange = 1 << 15,

                /**
                 * Special bypass parameter (only one allowed): plug-in can handle bypass.
                 * Highly recommended to export a bypass parameter for effect plug-in. (SDK 3.0.0)
                 */
                kIsBypass = 1 << 16
            };
        };

        /**
         * View Types used for IEditController::createView
         */
        namespace ViewType
        {
            const CString kEditor = "editor";
        } /* namespace ViewType */

        /**
         * Flags used for IComponentHandler::restartComponent
         */
        enum RestartFlags : int32
        {
            /**
             * The Component should be reloaded
             * The host has to unload completely the plug-in (controller/processor) and reload it.
             */
            kReloadComponent            = 1 << 0,

            /**
             * Input / Output Bus configuration has changed
             *
             * The plug-in informs the host that either the bus configuration or the bus count has changed.
             * The host has to deactivate the plug-in, asks the plug-in for its wanted new bus configurations,
             * adapts its processing graph and reactivate the plug-in.
             */
            kIoChanged                  = 1 << 1,

            /**
             * Multiple parameter values have changed  (as result of a program change for example)
             *
             * The host invalidates all caches of parameter values and asks the edit controller for the current values.
             */
            kParamValuesChanged         = 1 << 2,

            /**
             * Latency has changed
             *
             * The plug informs the host that its latency has changed, getLatencySamples should return the new latency
             * after setActive (true) was called The host has to deactivate and reactivate the plug-in, then afterwards
             * the host could ask for the current latency (getLatencySamples)
             *
             * @see IAudioProcessor::getLatencySamples
             */
            kLatencyChanged             = 1 << 3,

            /**
             * Parameter titles, default values or flags (ParameterFlags) have changed
             * The host invalidates all caches of parameter infos and asks the edit controller for the current infos.
             */
            kParamTitlesChanged         = 1 << 4,

            /**
             * MIDI Controllers and/or Program Changes Assignments have changed
             *
             * The plug-in informs the host that its MIDI-CC mapping has changed (for example after a MIDI learn o
             * new loaded preset) or if the stepCount or UnitID of a ProgramChange parameter has changed.
             *
             * The host has to rebuild the MIDI-CC => parameter mapping (getMidiControllerAssignment)
             * and reread program changes parameters (stepCount and associated unitID)
             */
            kMidiCCAssignmentChanged    = 1 << 5,

            /**
             * Note Expression has changed (info, count, PhysicalUIMapping, ...)
             *
             * Either the note expression type info, the count of note expressions or the physical UI mapping has changed.
             * The host invalidates all caches of note expression infos and asks the edit controller for the current ones.
             * @see INoteExpressionController, NoteExpressionTypeInfo and INoteExpressionPhysicalUIMapping
             */
            kNoteExpressionChanged      = 1 << 6,

            /**
             * Input / Output bus titles have changed
             *
             * The host invalidates all caches of bus titles and asks the edit controller for the current titles.
             */
            kIoTitlesChanged            = 1 << 7,

            /**
             * Prefetch support has changed
             *
             * The plug-in informs the host that its PrefetchSupport has changed
             * The host has to deactivate the plug-in, calls IPrefetchableSupport::getPrefetchableSupport and reactivate the
             * plug-in
             *
             * @see IPrefetchableSupport
             */
            kPrefetchableSupportChanged = 1 << 8,

            /**
             * RoutingInfo has changed
             *
             * The plug-in informs the host that its internal routing (relation of an event-input-channel to an audio-output-bus)
             * has changed. The host ask the plug-in for the new routing with IComponent::getRoutingInfo, @ref vst3Routing
             *
             * @see IComponent
             */
            kRoutingInfoChanged         = 1 << 9,

            /**
             * Key switches has changed (info, count)
             *
             * Either the Key switches info, the count of Key switches has changed.
             * The host invalidates all caches of Key switches infos and asks the edit controller (IKeyswitchController) for the
             * current ones.
             *
             * @see IKeyswitchController
             */
             kKeyswitchChanged          = 1 << 10,

             /**
              * Mapping of ParamID has changed
              *
              * The Plug-in informs the host that its parameters ID has changed. This has to be called by the
              * edit controller in the method setComponentState or setState (during projects loading) when the
              * plug-in detects that the given state was associated to an older version of the plug-in, or to a
              * plug-in to replace (for ex. migrating VST2 => VST3), with a different set of parameter IDs, then
              * the host could remap any used parameters like automation by asking the IRemapParamID interface
              * (which extends IEditController).
              *
              * @see IRemapParamID (SDK 3.7.11)
              */
             kParamIDMappingChanged      = 1 << 11
        };

        /**
         * Knob Mode Type
         */
        using KnobMode = int32;

        /** Knob Mode */
        enum KnobModes : KnobMode
        {
            kCircularMode = 0,      ///< Circular with jump to clicked position
            kRelativCircularMode,   ///< Circular without jump to clicked position
            kLinearMode             ///< Linear: depending on vertical movement
        };

    } /* namespace Vst */
} /* namespace Steinberg */

#include <steinberg/vst3/base/AlignPop.h>

#endif /* _3RD_PARTY_STEINBERG_VST3_VST_PARAMETERINFO_H_ */
