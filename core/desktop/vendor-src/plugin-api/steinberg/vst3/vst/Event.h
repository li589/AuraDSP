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

#ifndef _3RD_PARTY_STEINBERG_VST3_VST_EVENT_H_
#define _3RD_PARTY_STEINBERG_VST3_VST_EVENT_H_

#include <steinberg/vst3/base/FUnknown.h>
#include <steinberg/vst3/vst/Types.h>
#include <steinberg/vst3/vst/NoteExpression.h>

#include <steinberg/vst3/base/AlignPush.h>

namespace Steinberg
{
    namespace Vst
    {
        /**
         * Controller Numbers (MIDI)
         */
        enum ControllerNumbers
        {
            kCtrlBankSelectMSB          =   0,      ///< Bank Select MSB
            kCtrlModWheel               =   1,      ///< Modulation Wheel
            kCtrlBreath                 =   2,      ///< Breath controller

            kCtrlFoot                   =   4,      ///< Foot Controller
            kCtrlPortaTime              =   5,      ///< Portamento Time
            kCtrlDataEntryMSB           =   6,      ///< Data Entry MSB
            kCtrlVolume                 =   7,      ///< Channel Volume (formerly Main Volume)
            kCtrlBalance                =   8,      ///< Balance

            kCtrlPan                    =   10,     ///< Pan
            kCtrlExpression             =   11,     ///< Expression
            kCtrlEffect1                =   12,     ///< Effect Control 1
            kCtrlEffect2                =   13,     ///< Effect Control 2

            // General Purpose Controllers #1 to #4
            kCtrlGPC1                   =   16,     ///< General Purpose Controller #1
            kCtrlGPC2                   =   17,     ///< General Purpose Controller #2
            kCtrlGPC3                   =   18,     ///< General Purpose Controller #3
            kCtrlGPC4                   =   19,     ///< General Purpose Controller #4

            kCtrlBankSelectLSB          =   32,     ///< Bank Select LSB

            kCtrlDataEntryLSB           =   38,     ///< Data Entry LSB

            kCtrlSustainOnOff           =   64,     ///< Damper Pedal On/Off (Sustain)
            kCtrlPortaOnOff             =   65,     ///< Portamento On/Off
            kCtrlSustenutoOnOff         =   66,     ///< Sustenuto On/Off
            kCtrlSoftPedalOnOff         =   67,     ///< Soft Pedal On/Off
            kCtrlLegatoFootSwOnOff      =   68,     ///< Legato Footswitch On/Off
            kCtrlHold2OnOff             =   69,     ///< Hold 2 On/Off

            // Sound Controllers #1 to #10
            kCtrlSoundVariation         =   70,     ///< Sound Variation
            kCtrlFilterCutoff           =   71,     ///< Filter Cutoff (Timbre/Harmonic Intensity)
            kCtrlReleaseTime            =   72,     ///< Release Time
            kCtrlAttackTime             =   73,     ///< Attack Time
            kCtrlFilterResonance        =   74,     ///< Filter Resonance (Brightness)
            kCtrlDecayTime              =   75,     ///< Decay Time
            kCtrlVibratoRate            =   76,     ///< Vibrato Rate
            kCtrlVibratoDepth           =   77,     ///< Vibrato Depth
            kCtrlVibratoDelay           =   78,     ///< Vibrato Delay
            kCtrlSoundCtrler10          =   79,     ///< undefined

            // General Purpose Controllers #5 to #8
            kCtrlGPC5                   =   80,     ///< General Purpose Controller #5
            kCtrlGPC6                   =   81,     ///< General Purpose Controller #6
            kCtrlGPC7                   =   82,     ///< General Purpose Controller #7
            kCtrlGPC8                   =   83,     ///< General Purpose Controller #8

            kCtrlPortaControl           =   84,     ///< Portamento Control

            // Effect Controllers
            kCtrlEff1Depth              =   91,     ///< Effect 1 Depth (Reverb Send Level)
            kCtrlEff2Depth              =   92,     ///< Effect 2 Depth (Tremolo Level)
            kCtrlEff3Depth              =   93,     ///< Effect 3 Depth (Chorus Send Level)
            kCtrlEff4Depth              =   94,     ///< Effect 4 Depth (Delay/Variation/Detune Level)
            kCtrlEff5Depth              =   95,     ///< Effect 5 Depth (Phaser Level)

            kCtrlDataIncrement          =   96,     ///< Data Increment (+1)
            kCtrlDataDecrement          =   97,     ///< Data Decrement (-1)
            kCtrlNRPNSelectLSB          =   98,     ///< NRPN Select LSB
            kCtrlNRPNSelectMSB          =   99,     ///< NRPN Select MSB
            kCtrlRPNSelectLSB           =   100,    ///< RPN Select LSB
            kCtrlRPNSelectMSB           =   101,    ///< RPN Select MSB

            // Other Channel Mode Messages
            kCtrlAllSoundsOff           =   120,    ///< All Sounds Off
            kCtrlResetAllCtrlers        =   121,    ///< Reset All Controllers
            kCtrlLocalCtrlOnOff         =   122,    ///< Local Control On/Off
            kCtrlAllNotesOff            =   123,    ///< All Notes Off
            kCtrlOmniModeOff            =   124,    ///< Omni Mode Off + All Notes Off
            kCtrlOmniModeOn             =   125,    ///< Omni Mode On  + All Notes Off
            kCtrlPolyModeOnOff          =   126,    ///< Poly Mode On/Off + All Sounds Off
            kCtrlPolyModeOn             =   127,    ///< Poly Mode On

            // Extra
            kAfterTouch                 =   128,    ///< After Touch (associated to Channel Pressure)
            kPitchBend                  =   129,    ///< Pitch Bend Change

            kCountCtrlNumber,                   ///< Count of Controller Number

            // Extra for kLegacyMIDICCOutEvent
            kCtrlProgramChange          =   130,    ///< Program Change (use LegacyMIDICCOutEvent.value only)
            kCtrlPolyPressure           =   131,    ///< Polyphonic Key Pressure (use LegacyMIDICCOutEvent.value for pitch and
                                                    /// LegacyMIDICCOutEvent.value2 for pressure)
            kCtrlQuarterFrame           =   132,    ///< Quarter Frame ((use LegacyMIDICCOutEvent.value only)

            kSystemSongSelect           =   133,    ///< Song Select (use LegacyMIDICCOutEvent.value only)
            kSystemSongPointer          =   134,    ///< Song Pointer (use LegacyMIDICCOutEvent.value for LSB and
                                                    /// LegacyMIDICCOutEvent.value2 for MSB)
            kSystemCableSelect          =   135,    ///< Cable Select (use LegacyMIDICCOutEvent.value only)
            kSystemTuneRequest          =   136,    ///< Tune Request (use LegacyMIDICCOutEvent.value only)
            kSystemMidiClockStart       =   137,    ///< Midi Clock Start (use LegacyMIDICCOutEvent.value only)
            kSystemMidiClockContinue    =   138,    ///< Midi Clock Continue (use LegacyMIDICCOutEvent.value only)
            kSystemMidiClockStop        =   139,    ///< Midi Clock Stop (use LegacyMIDICCOutEvent.value only)
            kSystemActiveSensing        =   140,    ///< Active Sensing (use LegacyMIDICCOutEvent.value only)
        };

        /**
         * Reserved note identifier (noteId) range for a plug-in. Guaranteed not used by the host.
         */
        enum NoteIDUserRange
        {
            kNoteIDUserRangeLowerBound = -10000,
            kNoteIDUserRangeUpperBound = -1000,
        };

        /**
         * Note-on event specific data. Used in @ref Event (union)
         * Pitch uses the twelve-tone equal temperament tuning (12-TET).
         */
        struct NoteOnEvent
        {
            int16 channel;      ///< channel index in event bus
            int16 pitch;        ///< range [0, 127] = [C-2, G8] with A3=440Hz (12-TET: twelve-tone equal temperament)
            float tuning;       ///< 1.f = +1 cent, -1.f = -1 cent
            float velocity;     ///< range [0.0, 1.0]
            int32 length;       ///< in sample frames (optional, Note Off has to follow in any case!)
            int32 noteId;       ///< note identifier (if not available then -1)
        };

        /**
         * Note-off event specific data. Used in @ref Event (union)
         */
        struct NoteOffEvent
        {
            int16 channel;      ///< channel index in event bus
            int16 pitch;        ///< range [0, 127] = [C-2, G8] with A3=440Hz (12-TET)
            float velocity;     ///< range [0.0, 1.0]
            int32 noteId;       ///< associated noteOn identifier (if not available then -1)
            float tuning;       ///< 1.f = +1 cent, -1.f = -1 cent
        };

        /**
         * Data event specific data. Used in @ref Event (union)
         */
        struct DataEvent
        {
            uint32 size;        ///< size in bytes of the data block bytes
            uint32 type;        ///< type of this data block (see \ref DataTypes)
            const uint8* bytes; ///< pointer to the data block

            /**
             * Value for DataEvent::type
             */
            enum DataTypes
            {
                /**
                 * for MIDI system exclusive message
                 */
                kMidiSysEx = 0
            };
        };

        /**
         * PolyPressure event specific data. Used in @ref Event (union)
         */
        struct PolyPressureEvent
        {
            int16 channel;      ///< channel index in event bus
            int16 pitch;        ///< range [0, 127] = [C-2, G8] with A3=440Hz
            float pressure;     ///< range [0.0, 1.0]
            int32 noteId;       ///< event should be applied to the noteId (if not -1)
        };

        /**
         * Chord event specific data. Used in @ref Event (union)
         */
        struct ChordEvent
        {
            int16 root;         ///< range [0, 127] = [C-2, G8] with A3=440Hz
            int16 bassNote;     ///< range [0, 127] = [C-2, G8] with A3=440Hz
            int16 mask;         ///< root is bit 0
            uint16 textLen;     ///< the number of characters (TChar) between the beginning of text and the terminating
                                ///< null character (without including the terminating null character itself)
            const TChar* text;  ///< UTF-16, null terminated Hosts Chord Name
        };

        /**
         * Scale event specific data. Used in @ref Event (union)
         */
        struct ScaleEvent
        {
            int16 root;         ///< range [0, 127] = root Note/Transpose Factor
            int16 mask;         ///< Bit 0 =  C,  Bit 1 = C#, ... (0x5ab5 = Major Scale)
            uint16 textLen;     ///< the number of characters (TChar) between the beginning of text and the terminating
                                ///< null character (without including the terminating null character itself)
            const TChar* text;  ///< UTF-16, null terminated, Hosts Scale Name
        };

        /**
         * Legacy MIDI CC Out event specific data. Used in @ref Event (union)
         * This kind of event is reserved for generating MIDI CC as output event for kEvent Bus during the process call.
         */
        struct LegacyMIDICCOutEvent
        {
            uint8 controlNumber;///< see enum ControllerNumbers [0, 255]
            int8 channel;       ///< channel index in event bus [0, 15]
            int8 value;         ///< value of Controller [0, 127]
            int8 value2;        ///< [0, 127] used for pitch bend (kPitchBend) and polyPressure (kCtrlPolyPressure)
        };

        /**
         * Event
         * Structure representing a single Event of different types associated to a specific event (@ref kEvent) bus.
        */
        struct Event
        {
            int32 busIndex;             ///< event bus index
            int32 sampleOffset;         ///< sample frames related to the current block start sample position
            TQuarterNotes ppqPosition;  ///< position in project
            uint16 flags;               ///< combination of @ref EventFlags

            /**
             * Event Flags - used for Event::flags
             */
            enum EventFlags
            {
                kIsLive                         = 1 << 0,           ///< indicates that the event is played live (directly from keyboard)

                kUserReserved1                  = 1 << 14,          ///< reserved for user (for internal use)
                kUserReserved2                  = 1 << 15           ///< reserved for user (for internal use)
            };

            /**
             * Event Types - used for Event::type
             */
            enum EventTypes
            {
                kNoteOnEvent                    = 0,                ///< is @ref NoteOnEvent
                kNoteOffEvent                   = 1,                ///< is @ref NoteOffEvent
                kDataEvent                      = 2,                ///< is @ref DataEvent
                kPolyPressureEvent              = 3,                ///< is @ref PolyPressureEvent
                kNoteExpressionValueEvent       = 4,                ///< is @ref NoteExpressionValueEvent
                kNoteExpressionTextEvent        = 5,                ///< is @ref NoteExpressionTextEvent
                kChordEvent                     = 6,                ///< is @ref ChordEvent
                kScaleEvent                     = 7,                ///< is @ref ScaleEvent
                kNoteExpressionIntValueEvent    = 8,                ///< is \ref NoteExpressionIntValueEvent
                kLegacyMIDICCOutEvent           = 65535             ///< is @ref LegacyMIDICCOutEvent
            };

            uint16 type;                ///< a value from \ref EventTypes
            union
            {
                NoteOnEvent noteOn;                                 ///< type == kNoteOnEvent
                NoteOffEvent noteOff;                               ///< type == kNoteOffEvent
                DataEvent data;                                     ///< type == kDataEvent
                PolyPressureEvent polyPressure;                     ///< type == kPolyPressureEvent
                NoteExpressionValueEvent noteExpressionValue;       ///< type == kNoteExpressionValueEvent
                NoteExpressionTextEvent noteExpressionText;         ///< type == kNoteExpressionTextEvent
                NoteExpressionIntValueEvent noteExpressionIntValue; ///< type == kNoteExpressionIntValueEvent
                ChordEvent chord;                                   ///< type == kChordEvent
                ScaleEvent scale;                                   ///< type == kScaleEvent
                LegacyMIDICCOutEvent midiCCOut;                     ///< type == kLegacyMIDICCOutEvent
            };
        };

    } /* namespace Vst */
} /* namespace Steinberg */

#include <steinberg/vst3/base/AlignPop.h>



#endif /* _3RD_PARTY_STEINBERG_VST3_VST_EVENT_H_ */
