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

#ifndef _3RD_PARTY_STEINBERG_VST3_VST_IVSTMESSAGE_H_
#define _3RD_PARTY_STEINBERG_VST3_VST_IVSTMESSAGE_H_

#include <steinberg/vst3/base/FUnknown.h>
#include <steinberg/vst3/vst/IMessage.h>

namespace Steinberg
{
    namespace Vst
    {
        /**
         * Connect a component with another one: Vst::IConnectionPoint
         *
         * This interface is used for the communication of separate components.
         * @note that some hosts will place a proxy object between the components so that they are not directly connected.
         *
         * @see @ref vst3Communication
         */
        #include <steinberg/vst3/base/WarningsPush.h>
        class IConnectionPoint: public FUnknown
        {
            public:
                /**
                 * Connects this instance with another connection point.
                 */
                virtual tresult PLUGIN_API connect(IConnectionPoint *other) = 0;

                /**
                 * Disconnects a given connection point from this.
                 */
                virtual tresult PLUGIN_API disconnect(IConnectionPoint *other) = 0;

                /**
                 * Called when a message has been sent from the connection point to this.
                 */
                virtual tresult PLUGIN_API notify(IMessage *message) = 0;

            public:
                static const FUID iid;
        };
        #include <steinberg/vst3/base/WarningsPop.h>

    } /* namespace Vst */
} /* namespace Steinberg */

#endif /* _3RD_PARTY_STEINBERG_VST3_VST_IVSTMESSAGE_H_ */
