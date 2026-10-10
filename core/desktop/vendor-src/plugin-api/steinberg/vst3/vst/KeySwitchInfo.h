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

#ifndef _3RD_PARTY_STEINBERG_VST3_VST_KEYSWITCHINFO_H_
#define _3RD_PARTY_STEINBERG_VST3_VST_KEYSWITCHINFO_H_

#include <steinberg/vst3/vst/Types.h>

#include <steinberg/vst3/base/AlignPush.h>

namespace Steinberg
{
    namespace Vst
    {
        /**
         * KeyswitchTypeIDs describes the type of a key switch
         * @see KeyswitchInfo
         */
        enum KeyswitchTypeIDs : uint32
        {
            kNoteOnKeyswitchTypeID = 0, ///< press before noteOn is played
            kOnTheFlyKeyswitchTypeID,   ///< press while noteOn is played
            kOnReleaseKeyswitchTypeID,  ///< press before entering release
            kKeyRangeTypeID             ///< key should be maintained pressed for playing
        };

        typedef uint32 KeyswitchTypeID;

        /**
         * KeyswitchInfo is the structure describing a key switch
         *
         * This structure is used by the method \ref IKeyswitchController::getKeyswitchInfo.
         * @see IKeyswitchController
         */
        struct KeyswitchInfo
        {
            KeyswitchTypeID typeId;     ///< see KeyswitchTypeID
            String128 title;            ///< name of key switch (e.g. "Accentuation")
            String128 shortTitle;       ///< short title (e.g. "Acc")

            int32 keyswitchMin;         ///< associated main key switch min (value between [0, 127])
            int32 keyswitchMax;         ///< associated main key switch max (value between [0, 127])
            int32 keyRemapped;          /** optional remapped key switch (default -1), the plug-in could provide one remapped
                                        key for a key switch (allowing better location on the keyboard of the key switches) */

            int32 unitId;               ///< id of unit this key switch belongs to (see \ref vst3Units), -1 means no unit used.

            int32 flags;                ///< not yet used (set to 0)
        };
    } /* namespace Vst */
} /* namespace Steinberg */

#include <steinberg/vst3/base/AlignPop.h>

#endif /* _3RD_PARTY_STEINBERG_VST3_VST_KEYSWITCHINFO_H_ */
