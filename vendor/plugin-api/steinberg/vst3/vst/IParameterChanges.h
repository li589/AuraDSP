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

#ifndef _3RD_PARTY_STEINBERG_VST3_VST_IPARAMETERCHANGES_H_
#define _3RD_PARTY_STEINBERG_VST3_VST_IPARAMETERCHANGES_H_

#include <steinberg/vst3/base/FUnknown.h>
#include <steinberg/vst3/vst/Types.h>
#include <steinberg/vst3/vst/IParamValueQueue.h>

namespace Steinberg
{
    namespace Vst
    {
        /**
         * All parameter changes of a processing block: Vst::IParameterChanges
         *
         * This interface is used to transmit any changes to be applied to parameters
         * in the current processing block. A change can be caused by GUI interaction as
         * well as automation. They are transmitted as a list of queues (@ref IParamValueQueue)
         * containing only queues for parameters that actually did change.
         *
         * @see @ref IParamValueQueue, @ref ProcessData
         */
        #include <steinberg/vst3/base/WarningsPush.h>
        class IParameterChanges : public FUnknown
        {
            public:
                /**
                 * Returns count of Parameter changes in the list.
                 */
                virtual int32 PLUGIN_API getParameterCount () = 0;

                /**
                 * Returns the queue at a given index.
                 */
                virtual IParamValueQueue* PLUGIN_API getParameterData (int32 index) = 0;

                /**
                 * Adds a new parameter queue with a given ID at the end of the list,
                 * returns it and its index in the parameter changes list.
                 */
                virtual IParamValueQueue* PLUGIN_API addParameterData (const ParamID& id, int32& index /*out*/) = 0;

                static const FUID iid;
        };
        #include <steinberg/vst3/base/WarningsPop.h>

    } /* namespace Vst */
} /* namespace Steinberg */


#endif /* _3RD_PARTY_STEINBERG_VST3_VST_IPARAMETERCHANGES_H_ */
