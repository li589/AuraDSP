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

#ifndef _3RD_PARTY_STEINBERG_VST3_VST_IDATAEXCHANGERECEIVER_H_
#define _3RD_PARTY_STEINBERG_VST3_VST_IDATAEXCHANGERECEIVER_H_

#include <steinberg/vst3/base/FUnknown.h>
#include <steinberg/vst3/vst/DataExchangeBlock.h>
#include <steinberg/vst3/vst/IAudioProcessor.h>

namespace Steinberg
{
    namespace Vst
    {
        /**
         * Data Exchange Receiver interface.
         *
         * The receiver interface is required to receive data from the realtime audio process via the
         * IDataExchangeHandler.
         *
         * @see @ref IDataExchangeHandler
         */
        #include <steinberg/vst3/base/WarningsPush.h>
        class IDataExchangeReceiver: public FUnknown
        {
            public:
                /**
                 * Queue opened notification
                 *
                 * Called on the main thread when the processor has opened a queue
                 *
                 * @param userContextID the user context ID of the queue
                 * @param blockSize the size of one block of the queue
                 * @param dispatchedOnBackgroundThread if true on output the blocks are dispatched on a
                 *                                     background thread [defaults to false in which case the
                 *                                     blocks are dispatched on the main thread]
                 */
                virtual void PLUGIN_API queueOpened(DataExchangeUserContextID userContextID, uint32 blockSize,
                                                    TBool& dispatchOnBackgroundThread) = 0;
                /**
                 * Queue closed notification
                 *
                 * called on the main thread when the processor has closed a queue
                 *
                 * @param userContextID the user context ID of the queue
                 */
                virtual void PLUGIN_API queueClosed(DataExchangeUserContextID userContextID) = 0;

                /**
                 * One or more blocks were received
                 *
                 * Called either on the main thread or a background thread depending on the
                 * dispatchOnBackgroundThread value in the queueOpened call.
                 *
                 * The data of the blocks are only valid inside this call and the blocks only become available
                 * to the queue afterwards.
                 *
                 * @param userContextID the user context ID of the queue
                 * @param numBlocks number of blocks
                 * @param blocks the blocks
                 * @param onBackgroundThread true if the call is done on a background thread
                 */
                virtual void PLUGIN_API onDataExchangeBlocksReceived(DataExchangeUserContextID userContextID,
                                                                     uint32 numBlocks,
                                                                     DataExchangeBlock *blocks,
                                                                     TBool onBackgroundThread) = 0;

            public:
                static const FUID iid;
        };
        #include <steinberg/vst3/base/WarningsPop.h>

    } /* namespace Vst */
} /* namespace Steinberg */

#endif /* _3RD_PARTY_STEINBERG_VST3_VST_IDATAEXCHANGERECEIVER_H_ */
