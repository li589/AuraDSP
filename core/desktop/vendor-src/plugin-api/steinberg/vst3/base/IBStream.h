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

#ifndef _3RD_PARTY_STEINBERG_VST3_BASE_IBSTREAM_H_
#define _3RD_PARTY_STEINBERG_VST3_BASE_IBSTREAM_H_

#include <steinberg/vst3/base/FUnknown.h>

namespace Steinberg
{
    /**
     * Base class for streams.
     *   - read/write binary data from/to stream
     *   - get/set stream read-write position (read and write position is the same)
     */
    #include <steinberg/vst3/base/WarningsPush.h>
    class IBStream: public FUnknown
    {
        public:
            enum IStreamSeekMode
            {
                kIBSeekSet = 0, ///< set absolute seek position
                kIBSeekCur,     ///< set seek position relative to current position
                kIBSeekEnd      ///< set seek position relative to stream end
            };

            /**
             * Reads binary data from stream.
             * @param buffer destination buffer
             * @param numBytes amount of bytes to be read
             * @param numBytesRead result how many bytes have been read from stream (set to 0 if this is of no interest)
             */
            virtual tresult PLUGIN_API read(void* buffer, int32 numBytes, int32* numBytesRead = nullptr) = 0;

            /**
             * Writes binary data to stream.
             * @param buffer source buffer
             * @param numBytes amount of bytes to write
             * @param numBytesWritten result - how many bytes have been written to stream (set to 0 if this is of no interest)
             */
            virtual tresult PLUGIN_API write(void* buffer, int32 numBytes, int32* numBytesWritten = nullptr) = 0;

            /**
             * Sets stream read-write position.
             * @param pos new stream position (dependent on mode)
             * @param mode value of enum IStreamSeekMode
             * @param result new seek position (set to 0 if this is of no interest)
             */
            virtual tresult PLUGIN_API seek(int64 pos, int32 mode, int64* result = nullptr) = 0;

            /**
             * Gets current stream read-write position.
             * @param pos is assigned the current position if function succeeds
             */
            virtual tresult PLUGIN_API tell(int64* pos) = 0;

        public:
            static const FUID iid;
    };
    #include <steinberg/vst3/base/WarningsPop.h>

} /* namespace Steinberg */




#endif /* _3RD_PARTY_STEINBERG_VST3_BASE_IBSTREAM_H_ */
