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

#ifndef _3RD_PARTY_STEINBERG_VST3_VST_CHANNELCONTEXT_H_
#define _3RD_PARTY_STEINBERG_VST3_VST_CHANNELCONTEXT_H_

#include <steinberg/vst3/vst/Types.h>
#include <steinberg/vst3/vst/IAttributeList.h>

#include <steinberg/vst3/base/AlignPush.h>

namespace Steinberg
{
    namespace Vst
    {
        namespace ChannelContext
        {
            /**
             * Values used for kChannelPluginLocationKey
             */
            enum ChannelPluginLocation
            {
                kPreVolumeFader = 0,
                kPostVolumeFader,
                kUsedAsPanner
            };

            /**
             * ARGB (Alpha-Red-Green-Blue)
             */
            typedef uint32 ColorSpec;
            typedef uint8 ColorComponent;

            /**
             * Returns the Blue part of the given ColorSpec
             */
            inline ColorComponent GetBlue(ColorSpec cs)
            {
                return ColorComponent(cs & 0x000000ff);
            }

            /**
             * Returns the Green part of the given ColorSpec
             */
            inline ColorComponent GetGreen(ColorSpec cs)
            {
                return ColorComponent((cs >> 8) & 0x000000ff);
            }

            /**
             * Returns the Red part of the given ColorSpec
             */
            inline ColorComponent GetRed(ColorSpec cs)
            {
                return ColorComponent((cs >> 16) & 0x000000ff);
            }

            /**
             * Returns the Alpha part of the given ColorSpec
             */
            inline ColorComponent GetAlpha(ColorSpec cs)
            {
                return ColorComponent((cs >> 24) & 0x000000ff);
            }

            /**
             * Keys used as AttrID (Attribute ID) in the return IAttributeList of
             * IInfoListener::setChannelContextInfos
             */

            /**
             * string (TChar) [optional]: unique id string used to identify a channel
             */
            const CString kChannelUIDKey = "channel uid";

            /**
             * integer (int64) [optional]: number of characters in kChannelUIDKey
             */
            const CString kChannelUIDLengthKey = "channel uid length";

            /**
             * string (TChar) [optional]: name of the channel like displayed in the mixer
             */
            const CString kChannelNameKey = "channel name";

            /**
             * integer (int64) [optional]: number of characters in kChannelNameKey
             */
            const CString kChannelNameLengthKey = "channel name length";

            /**
             * color (ColorSpec) [optional]: used color for the channel in mixer or track
             */
            const CString kChannelColorKey = "channel color";

            /**
             * integer (int64) [optional]: index of the channel in a channel index namespace, start with 1 not 0!
             */
            const CString kChannelIndexKey = "channel index";

            /**
             * integer (int64) [optional]: define the order of the current used index namespace, start with 1 not 0!
             * For example:
             *   - index namespace is "Input"   -> order 1,
             *   - index namespace is "Channel" -> order 2,
             *   - index namespace is "Output"  -> order 3
             */
            const CString kChannelIndexNamespaceOrderKey = "channel index namespace order";

            /**
             * string (TChar) [optional]: name of the channel index namespace for example "Input", "Output", "Channel", ...
             */
            const CString kChannelIndexNamespaceKey = "channel index namespace";

            /**
             * integer (int64) [optional]: number of characters in kChannelIndexNamespaceKey
             */
            const CString kChannelIndexNamespaceLengthKey = "channel index namespace length";

            /**
             * PNG image representation as binary [optional]
             */
            const CString kChannelImageKey = "channel image";

            /**
             * integer (int64) [optional]: routing position of the plug-in in the channel (see ChannelPluginLocation)
             */
            const CString kChannelPluginLocationKey = "channel plugin location";

        } /* namespace ChannelContext */
    } /* namespace Vst */
} /* namespace Steinberg */

#include <steinberg/vst3/base/AlignPop.h>


#endif /* _3RD_PARTY_STEINBERG_VST3_VST_CHANNELCONTEXT_H_ */
