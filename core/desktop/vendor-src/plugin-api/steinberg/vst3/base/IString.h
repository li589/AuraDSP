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

#ifndef _3RD_PARTY_STEINBERG_VST3_BASE_ISTRING_H_
#define _3RD_PARTY_STEINBERG_VST3_BASE_ISTRING_H_

#include <steinberg/vst3/base/Types.h>
#include <steinberg/vst3/base/FUnknown.h>

namespace Steinberg
{
    /**
     * Interface to a string of variable size and encoding.
     */
    #include <steinberg/vst3/base/WarningsPush.h>
    class IString: public FUnknown
    {
        public:
            /**
             * Assign ASCII string
             */
            virtual void PLUGIN_API setText8(const char8 *text) = 0;

            /**
             * Assign unicode string
             */
            virtual void PLUGIN_API setText16(const char16 *text) = 0;

            /**
             * Return ASCII string. If the string is unicode so far, it will be converted.
             * So you need to be careful, because the conversion can result in data loss.
             * It is save though to call getText8 if isWideString() returns false
             */
            virtual const char8 * PLUGIN_API getText8() = 0;

            /**
             * Return unicode string. If the string is ASCII so far, it will be converted.
             */
            virtual const char16 * PLUGIN_API getText16() = 0;

            /**
             * !Do not use this method! Early implementations take the given pointer as
             * internal string and this will cause problems because 'free' will be used to delete the passed memory.
             * implementations will redirect 'take' to setText8 and setText16
             */
            virtual void PLUGIN_API take(void* s, bool isWide) = 0;

            /**
             * Returns true if the string is in unicode format, returns false if the string is ASCII
             */
            virtual bool PLUGIN_API isWideString() const = 0;

        public:
            static const FUID iid;
    };
    #include <steinberg/vst3/base/WarningsPop.h>

} /* namespace Steinberg */

#endif /* _3RD_PARTY_STEINBERG_VST3_BASE_ISTRING_H_ */

