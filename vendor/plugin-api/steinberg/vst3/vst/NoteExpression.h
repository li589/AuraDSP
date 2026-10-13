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

#ifndef _3RD_PARTY_STEINBERG_VST3_VST_NOTEEXPRESSION_H_
#define _3RD_PARTY_STEINBERG_VST3_VST_NOTEEXPRESSION_H_

#include <steinberg/vst3/vst/Types.h>

#include <steinberg/vst3/base/AlignPush.h>

namespace Steinberg
{
    namespace Vst
    {
        /**
         * Note Expression Types
         */
        typedef uint32 NoteExpressionTypeID;

        /**
         * Note Expression Value
         */
        typedef double NoteExpressionValue;

        /**
         * NoteExpressionTypeIDs describes the type of the note expression.
         * VST predefines some types like volume, pan, tuning by defining their ranges and curves.
         * Used by NoteExpressionEvent::typeId and NoteExpressionTypeID::typeId
         * @see NoteExpressionTypeInfo
         */
        enum NoteExpressionTypeIDs : uint32
        {
            kVolumeTypeID = 0,      ///< Volume, plain range [0 = -oo , 0.25 = 0dB, 0.5 = +6dB, 1 = +12dB]: plain = 20 * log (4 * norm)
            kPanTypeID,             ///< Panning (L-R), plain range [0 = left, 0.5 = center, 1 = right]
            kTuningTypeID,          ///< Tuning, plain range [0 = -120.0 (ten octaves down), 0.5 none, 1 = +120.0 (ten octaves up)]
                                    ///< plain = 240 * (norm - 0.5) and norm = plain / 240 + 0.5
                                    ///< oneOctave is 12.0 / 240.0; oneHalfTune = 1.0 / 240.0;
            kVibratoTypeID,         ///< Vibrato
            kExpressionTypeID,      ///< Expression
            kBrightnessTypeID,      ///< Brightness
            kTextTypeID,            ///< See NoteExpressionTextEvent
            kPhonemeTypeID,         ///< TODO:

            kCustomStart = 100000,  ///< start of custom note expression type ids
            kCustomEnd   = 200000,  ///< end of custom note expression type ids

            kInvalidTypeID = 0xFFFFFFFF ///< indicates an invalid note expression type
        };

        /**
         * Description of a Note Expression Type
         * This structure is part of the NoteExpressionTypeInfo structure, it describes for given NoteExpressionTypeID its default value
         * (for example 0.5 for a kTuningTypeID (kIsBipolar: centered)), its minimum and maximum (for predefined NoteExpressionTypeID the
         * full range is predefined too) and a stepCount when the given NoteExpressionTypeID is limited to discrete values (like on/off state).
         * @see NoteExpressionTypeInfo
         */
        struct NoteExpressionValueDescription
        {
            NoteExpressionValue defaultValue;   ///< default normalized value [0,1]
            NoteExpressionValue minimum;        ///< minimum normalized value [0,1]
            NoteExpressionValue maximum;        ///< maximum normalized value [0,1]
            int32 stepCount;                    ///< number of discrete steps (0: continuous, 1: toggle, discrete value otherwise - see \ref vst3ParameterIntro)
        };

        #if SMTG_OS_WINDOWS && !SMTG_PLATFORM_64
            #include <steinberg/vst3/vst/AlignPush4.h>
        #endif

        /**
         * Note Expression Value event. Used in @ref Event (union)
         *
         * A note expression event affects one single playing note (referring its noteId).
         * This kind of event is send from host to the plug-in like other events (NoteOnEvent, NoteOffEvent,...)
         * in @ref ProcessData during the process call.
         *
         * Note expression events for a specific noteId can only occur after a NoteOnEvent. The host must take care that
         * the event list (@ref IEventList) is properly sorted.
         *
         * Expression events are always absolute normalized values [0.0, 1.0].
         * The predefined types have a predefined mapping of the normalized values (see @ref NoteExpressionTypeIDs)
         *
         * @see @ref INoteExpressionController
         */
        struct NoteExpressionValueEvent
        {
            NoteExpressionTypeID typeId;    ///< see \ref NoteExpressionTypeID
            int32 noteId;                   ///< associated note identifier to apply the change

            NoteExpressionValue value;      ///< normalized value [0.0, 1.0].
        };

        /**
         * Note Expression Int event. Used in @ref Event (union)
         * Same as NoteExpressionValueEvent but use a uint64 instead of a NoteExpressionValue (double)
         * @since 3.8.0
         */
        struct NoteExpressionIntValueEvent
        {
            NoteExpressionTypeID typeId;    ///< see @ref NoteExpressionTypeID
            int32 noteId;                   ///< associated note identifier to apply the change

            uint64 value;
        };

        /**
         * Note Expression Text event. Used in Event (union)
         * A Expression event affects one single playing note.
         * @see @ref INoteExpressionController
         * @see NoteExpressionTypeInfo
         */
        struct NoteExpressionTextEvent
        {
            NoteExpressionTypeID typeId;    ///< see \ref NoteExpressionTypeID (kTextTypeID or kPhoneticTypeID)
            int32 noteId;                   ///< associated note identifier to apply the change

            uint32 textLen;                 ///< the number of characters (TChar) between the beginning of text and the terminating
                                            ///< null character (without including the terminating null character itself)

            const TChar* text;              ///< UTF-16, null terminated
        };

        #if SMTG_OS_WINDOWS && !SMTG_PLATFORM_64
            #include <steinberg/vst3/base/AlignPop.h>
        #endif

        /**
         * NoteExpressionTypeInfo is the structure describing a note expression supported by the plug-in.
         *
         * This structure is used by the method @ref INoteExpressionController::getNoteExpressionInfo.
         *
         * @see INoteExpressionController
         */
        struct NoteExpressionTypeInfo
        {
            NoteExpressionTypeID typeId;            ///< unique identifier of this note Expression type
            String128 title;                        ///< note Expression type title (e.g. "Volume")
            String128 shortTitle;                   ///< note Expression type short title (e.g. "Vol")
            String128 units;                        ///< note Expression type unit (e.g. "dB")
            int32 unitId;                           ///< id of unit this NoteExpression belongs to (see \ref vst3Units), in order to sort the note expression, it is possible to use unitId like for parameters. -1 means no unit used.
            NoteExpressionValueDescription valueDesc;   ///< value description see \ref NoteExpressionValueDescription
            ParamID associatedParameterId;          ///< optional associated parameter ID (for mapping from note expression to global (using the parameter automation for example) and back). Only used when kAssociatedParameterIDValid is set in flags.

            int32 flags;                            ///< NoteExpressionTypeFlags (see below)
            enum NoteExpressionTypeFlags
            {
                kIsBipolar      = 1 << 0,           ///< event is bipolar (centered), otherwise unipolar
                kIsOneShot      = 1 << 1,           ///< event occurs only one time for its associated note (at begin of the noteOn)
                kIsAbsolute     = 1 << 2,           ///< This note expression will apply an absolute change to the sound (not relative (offset))
                kAssociatedParameterIDValid = 1 << 3,///< indicates that the associatedParameterID is valid and could be used
            };
        };

    } /* namespace Vst */
} /* namespace Steinberg */

#include <steinberg/vst3/base/AlignPop.h>


#endif /* _3RD_PARTY_STEINBERG_VST3_VST_NOTEEXPRESSION_H_ */
