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

#ifndef _3RD_PARTY_STEINBERG_VST3_VST_INOTEEXPRESSIONCONTROLLER_H_
#define _3RD_PARTY_STEINBERG_VST3_VST_INOTEEXPRESSIONCONTROLLER_H_

#include <steinberg/vst3/base/FUnknown.h>
#include <steinberg/vst3/vst/Types.h>
#include <steinberg/vst3/vst/NoteExpression.h>

namespace Steinberg
{
    namespace Vst
    {
        /**
         * Extended plug-in interface IEditController for note expression event support: Vst::INoteExpressionController
         *
         * With this plug-in interface, the host can retrieve all necessary note expression information supported by the plug-in.
         * Note expression information (@ref NoteExpressionTypeInfo) are specific for given channel and event bus.
         *
         * Note that there is only one NoteExpressionTypeID per given channel of an event bus.
         *
         * The method getNoteExpressionStringByValue allows conversion from a normalized value to a string representation
         * and the getNoteExpressionValueByString method from a string to a normalized value.
         *
         * When the note expression state changes (for example when switching presets) the plug-in needs
         * to inform the host about it via @ref IComponentHandler::restartComponent (kNoteExpressionChanged).
         */
        #include <steinberg/vst3/base/WarningsPush.h>
        class INoteExpressionController : public FUnknown
        {
        public:
            /**
             * Returns number of supported note change types for event bus index and channel.
             */
            virtual int32 PLUGIN_API getNoteExpressionCount(int32 busIndex, int16 channel) = 0;

            /**
             * Returns note change type info.
             */
            virtual tresult PLUGIN_API getNoteExpressionInfo(int32 busIndex, int16 channel, int32 noteExpressionIndex, NoteExpressionTypeInfo& info /*out*/) = 0;

            /**
             * Gets a user readable representation of the normalized note change value.
             */
            virtual tresult PLUGIN_API getNoteExpressionStringByValue(int32 busIndex, int16 channel, NoteExpressionTypeID id, NoteExpressionValue valueNormalized /*in*/, String128 string /*out*/) = 0;

            /**
             * Converts the user readable representation to the normalized note change value.
             */
            virtual tresult PLUGIN_API getNoteExpressionValueByString(int32 busIndex, int16 channel, NoteExpressionTypeID id, const TChar* string /*in*/, NoteExpressionValue& valueNormalized /*out*/) = 0;

            static const FUID iid;
        };
        #include <steinberg/vst3/base/WarningsPop.h>

    } /* namespace Vst */
} /* namespace Steinberg */

#endif /* _3RD_PARTY_STEINBERG_VST3_VST_INOTEEXPRESSIONCONTROLLER_H_ */
