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

#ifndef _3RD_PARTY_STEINBERG_VST3_VST_IMESSAGE_H_
#define _3RD_PARTY_STEINBERG_VST3_VST_IMESSAGE_H_

#include <steinberg/vst3/base/FUnknown.h>
#include <steinberg/vst3/vst/IAttributeList.h>

namespace Steinberg
{
    namespace Vst
    {
        /**
         * Private plug-in message
         *
         * Messages are sent from a VST controller component to a VST editor component and vice versa.
         * @see @ref IAttributeList, @ref IConnectionPoint, @ref vst3Communication
        */
        #include <steinberg/vst3/base/WarningsPush.h>
        class IMessage: public FUnknown
        {
            public:
                /**
                 * Returns the message ID (for example "TextMessage").
                 */
                virtual FIDString PLUGIN_API getMessageID() = 0;

                /**
                 * Sets a message ID (for example "TextMessage").
                 */
                virtual void PLUGIN_API setMessageID(FIDString id /*in*/) = 0;

                /**
                 * Returns the attribute list associated to the message.
                 */
                virtual IAttributeList * PLUGIN_API getAttributes() = 0;

            public:
                static const FUID iid;
        };
        #include <steinberg/vst3/base/WarningsPop.h>

    } /* namespace Vst */
} /* namespace Steinberg */

#endif /* _3RD_PARTY_STEINBERG_VST3_VST_IMESSAGE_H_ */
