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

#ifndef _3RD_PARTY_STEINBERG_VST3_VST_IATTRIBUTELIST_H_
#define _3RD_PARTY_STEINBERG_VST3_VST_IATTRIBUTELIST_H_

#include <steinberg/vst3/base/Types.h>
#include <steinberg/vst3/base/FUnknown.h>
#include <steinberg/vst3/vst/Types.h>

namespace Steinberg
{
    namespace Vst
    {
        /**
         * Attribute list used in IMessage and IStreamAttributes: Vst::IAttributeList
         *
         * An attribute list associates values with a key (id: some predefined keys can be found in
         * @ref presetAttributes).
         */
        #include <steinberg/vst3/base/WarningsPush.h>
        class IAttributeList: public FUnknown
        {
            public:
                typedef const char* AttrID;

            public:
                /**
                 * Sets integer value.
                 */
                virtual tresult PLUGIN_API setInt(AttrID id, int64 value) = 0;

                /**
                 * Gets integer value.
                 */
                virtual tresult PLUGIN_API getInt(AttrID id, int64& value) = 0;

                /**
                 * Sets float value.
                 */
                virtual tresult PLUGIN_API setFloat(AttrID id, double value) = 0;

                /**
                 * Gets float value.
                 */
                virtual tresult PLUGIN_API getFloat(AttrID id, double& value) = 0;

                /**
                 * Sets string value (UTF16) (must be null-terminated!).
                 */
                virtual tresult PLUGIN_API setString(AttrID id, const TChar * string) = 0;

                /**
                 * Gets string value (UTF16). Note that Size is in Byte, not the string Length!
                 * Do not forget to multiply the length by sizeof (TChar)!
                 */
                virtual tresult PLUGIN_API getString(AttrID id, TChar* string, uint32 sizeInBytes) = 0;

                /**
                 * Sets binary data.
                 */
                virtual tresult PLUGIN_API setBinary(AttrID id, const void *data, uint32 sizeInBytes) = 0;

                /**
                 * Gets binary data.
                 */
                virtual tresult PLUGIN_API getBinary(AttrID id, const void *& data, uint32& sizeInBytes) = 0;

            public:
                static const FUID iid;
        };
        #include <steinberg/vst3/base/WarningsPop.h>

    } /* namespace Vst */
} /* namespace Steinberg */


#endif /* _3RD_PARTY_STEINBERG_VST3_VST_IATTRIBUTELIST_H_ */
