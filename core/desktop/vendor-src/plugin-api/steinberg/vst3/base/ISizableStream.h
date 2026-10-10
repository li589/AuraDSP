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

#ifndef _3RD_PARTY_STEINBERG_VST3_BASE_ISIZABLESTREAM_H_
#define _3RD_PARTY_STEINBERG_VST3_BASE_ISIZABLESTREAM_H_

#include <steinberg/vst3/base/FUnknown.h>
#include <steinberg/vst3/base/IBStream.h>

namespace Steinberg
{
    /**
     * Stream with a size.
     * Extends IBStream when stream type supports it (like file and memory stream).
     */
    #include <steinberg/vst3/base/WarningsPush.h>
    class ISizeableStream: public FUnknown
    {
        public:
            /**
             * Return the stream size
             */
            virtual tresult PLUGIN_API getStreamSize(int64 & size) = 0;

            /**
             * Set the steam size. File streams can only be resized if they are write enabled.
             */
            virtual tresult PLUGIN_API setStreamSize(int64 size) = 0;

            static const FUID iid;
    };
    #include <steinberg/vst3/base/WarningsPop.h>

} /* namespace Steinberg */


#endif /* _3RD_PARTY_STEINBERG_VST3_BASE_ISIZABLESTREAM_H_ */
