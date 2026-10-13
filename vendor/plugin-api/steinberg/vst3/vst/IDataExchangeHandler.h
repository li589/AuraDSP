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

#ifndef _3RD_PARTY_STEINBERG_VST3_VST_IDATAEXCHANGEHANDLER_H_
#define _3RD_PARTY_STEINBERG_VST3_VST_IDATAEXCHANGEHANDLER_H_

#include <steinberg/vst3/base/FUnknown.h>
#include <steinberg/vst3/vst/DataExchangeBlock.h>
#include <steinberg/vst3/vst/IAudioProcessor.h>

namespace Steinberg
{
    namespace Vst
    {
        /**
         * Host Data Exchange handler interface.
         *
         * The IDataExchangeHandler implements a direct and thread-safe connection from the realtime
         * audio context of the audio processor to the non-realtime audio context of the edit controller.
         * This should be used when the edit controller needs continuous data from the audio process for
         * visualization or other use-cases. To circumvent the bottleneck on the main thread it is possible
         * to configure the connection in a way that the calls to the edit controller will happen on a
         * background thread.
         *
         * Opening a queue:
         * The main operation for a plug-in is to open a queue via the handler before the plug-in is activated
         * (but it must be connected to the edit controller via the IConnectionPoint when the plug-in is using
         * the recommended separation of edit controller and audio processor). The best place to do this is in
         * the IAudioProcessor::setupProcessing method as this is also the place where the plug-in knows the
         * sample rate and maximum block size which the plug-in may need to calculate the queue block size.
         * When a queue is opened the edit controller gets a notification about it and the controller can
         * decide if it wishes to receive the data on the main thread or the background thread.
         *
         * Sending data:
         * In the IAudioProcessor::process call the plug-in can now lock a block from the handler, fill it and
         * when done free the block via the handler which then sends the block to the edit controller. The edit
         * controller then receives the block either on the main thread or on a background thread depending on
         * the setup of the queue.
         * The host guarantees that all blocks are send before the plug-in is deactivated.
         *
         * Closing a queue:
         * The audio processor must close an opened queue and this has to be done after the processor was
         * deactivated and before it is disconnected from the edit controller (see IConnectionPoint).
         *
         * What to do when the queue is full and no block can be locked?
         * The plug-in needs to be prepared for this situation as constraints in the overall system may cause
         * the queue to get full. If you need to get this information to the controller you can declare a
         * hidden parameter which you set to a special value and send this parameter change in your audio
         * process method.
         */
        #include <steinberg/vst3/base/WarningsPush.h>
        class IDataExchangeHandler: public FUnknown
        {
            public:
                /**
                 * Open a new queue
                 *
                 * Only allowed to be called from the main thread when the component is not active but
                 * initialized and connected (see IConnectionPoint)
                 *
                 * @param processor the processor who wants to open the queue
                 * @param blockSize size of one block
                 * @param numBlocks number of blocks in the queue
                 * @param alignment data alignment, if zero will use the platform default alignment if any
                 * @param userContextID an identifier internal to the processor
                 * @param outID on return the ID of the queue
                 * @return kResultTrue on success
                 */
                virtual tresult PLUGIN_API openQueue(IAudioProcessor *processor, uint32 blockSize,
                                                     uint32 numBlocks, uint32 alignment,
                                                     DataExchangeUserContextID userContextID,
                                                     DataExchangeQueueID *outID) = 0;
                /**
                 * Close a queue
                 *
                 * Closes and frees all memory of a previously opened queue
                 * if there are locked blocks in the queue, they are freed and made invalid
                 *
                 * only allowed to be called from the main thread when the component is not active but
                 * initialized and connected
                 *
                 * @param queueID the ID of the queue to close
                 * @return kResultTrue on success
                 */
                virtual tresult PLUGIN_API closeQueue(DataExchangeQueueID queueID) = 0;

                /**
                 * Lock a block if available
                 *
                 * Only allowed to be called from within the IAudioProcessor::process call
                 *
                 * @param queueID the ID of the queue
                 * @param block on return will contain the data pointer and size of the block
                 * @return kResultTrue if a free block was found and kOutOfMemory if all blocks are locked
                 */
                virtual tresult PLUGIN_API lockBlock(DataExchangeQueueID queueId,
                                                     DataExchangeBlock *block) = 0;

                /**
                 * Free a previously locked block
                 *
                 * Only allowed to be called from within the IAudioProcessor::process call
                 *
                 * @param queueID the ID of the queue
                 * @param blockID the ID of the block
                 * @param sendToController if true the block data will be send to the IEditController otherwise
                 *                         it will be discarded
                 * @return kResultTrue on success
                 */
                virtual tresult PLUGIN_API freeBlock(DataExchangeQueueID queueId, DataExchangeBlockID blockID,
                                                     TBool sendToController) = 0;

            public:
                static const FUID iid;
        };
        #include <steinberg/vst3/base/WarningsPop.h>

    } /* namespace Vst */
} /* namespace Steinberg */

#endif /* _3RD_PARTY_STEINBERG_VST3_VST_IDATAEXCHANGEHANDLER_H_ */
