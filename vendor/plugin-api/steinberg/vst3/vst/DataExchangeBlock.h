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

#ifndef _3RD_PARTY_STEINBERG_VST3_VST_DATAEXCHANGEBLOCK_H_
#define _3RD_PARTY_STEINBERG_VST3_VST_DATAEXCHANGEBLOCK_H_

#include <steinberg/vst3/base/FUnknown.h>
#include <steinberg/vst3/vst/IAudioProcessor.h>

#include <steinberg/vst3/base/AlignPush.h>

namespace Steinberg
{
    namespace Vst
    {
        typedef uint32 DataExchangeQueueID;
        typedef uint32 DataExchangeBlockID;
        typedef uint32 DataExchangeUserContextID;

        static SMTG_CONSTEXPR DataExchangeQueueID InvalidDataExchangeQueueID = kMaxInt32;
        static SMTG_CONSTEXPR DataExchangeBlockID InvalidDataExchangeBlockID = kMaxInt32;

        struct DataExchangeBlock
        {
            /**
             * Pointer to the memory buffer
             */
            void* data;
            /**
             * Size of the memory buffer
             */
            uint32 size;

            /**
             * Block identifier
             */
            DataExchangeBlockID blockID;
        };
    } /* namespace Vst */
} /* namespace Steinberg */

#include <steinberg/vst3/base/AlignPop.h>



#endif /* _3RD_PARTY_STEINBERG_VST3_VST_DATAEXCHANGEBLOCK_H_ */
