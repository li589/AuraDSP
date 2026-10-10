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

#ifndef _3RD_PARTY_STEINBERG_VST3_VST_IINFOLISTENER_H_
#define _3RD_PARTY_STEINBERG_VST3_VST_IINFOLISTENER_H_

#include <steinberg/vst3/base/FUnknown.h>
#include <steinberg/vst3/vst/IAttributeList.h>

namespace Steinberg
{
    namespace Vst
    {
        namespace ChannelContext
        {
            /**
             * Channel context interface.
             *
             * Allows the host to inform the plug-in about the context in which the plug-in is instantiated,
             * mainly channel based info (color, name, index,...). Index can be defined inside a namespace
             * (for example, index start from 1 to N for Type Input/Output Channel (Index namespace) and index
             * start from 1 to M for Type Audio Channel).
             *
             * As soon as the plug-in provides this IInfoListener interface, the host will call setChannelContextInfos
             * for each change occurring to this channel (new name, new color, new indexation,...)
             *
             * @example
             *
             * tresult PLUGIN_API MyPlugin::setChannelContextInfos (IAttributeList* list)
             * {
             *     if (list)
             *     {
             *         // optional we can ask for the Channel Name Length
             *         int64 length;
             *         if (list->getInt(ChannelContext::kChannelNameLengthKey, length) == kResultTrue)
             *         {
             *             // ...
             *         }
             *
             *         // get the Channel Name where we, as plug-in, are instantiated
             *         String128 name;
             *         if (list->getString(ChannelContext::kChannelNameKey, name, sizeof(name)) == kResultTrue)
             *         {
             *             // ...
             *         }
             *
             *         // get the Channel UID
             *         if (list->getString(ChannelContext::kChannelUIDKey, name, sizeof(name)) == kResultTrue)
             *         {
             *             // ...
             *         }
             *
             *         // get Channel Index
             *         int64 index;
             *         if (list->getInt(ChannelContext::kChannelIndexKey, index) == kResultTrue)
             *         {
             *             // ...
             *         }
             *
             *         // get the Channel Color
             *         int64 color;
             *         if (list->getInt(ChannelContext::kChannelColorKey, color) == kResultTrue)
             *         {
             *             uint32 channelColor = (uint32)color;
             *             String str;
             *             str.printf ("%x%x%x%x", ChannelContext::GetAlpha (channelColor),
             *             ChannelContext::GetRed (channelColor),
             *             ChannelContext::GetGreen (channelColor),
             *             ChannelContext::GetBlue (channelColor));
             *             String128 string128;
             *             Steinberg::UString(string128, 128).fromAscii (str);
             *
             *             // ...
             *         }
             *
             *         // get Channel Index Namespace Order of the current used index namespace
             *         if (list->getInt(ChannelContext::kChannelIndexNamespaceOrderKey, index) == kResultTrue)
             *         {
             *             // ...
             *         }
             *
             *         // get the channel Index Namespace Length
             *         if (list->getInt(ChannelContext::kChannelIndexNamespaceLengthKey, length) == kResultTrue)
             *         {
             *             // ...
             *         }
             *
             *         // get the channel Index Namespace
             *         String128 namespaceName;
             *         if (list->getString(ChannelContext::kChannelIndexNamespaceKey, namespaceName, sizeof(namespaceName)) == kResultTrue)
             *         {
             *             // ...
             *         }
             *
             *         // get plug-in Channel Location
             *         int64 location;
             *         if (list->getInt(ChannelContext::kChannelPluginLocationKey, location) == kResultTrue)
             *         {
             *             String128 string128;
             *             switch (location)
             *             {
             *                 case ChannelContext::kPreVolumeFader:
             *                     Steinberg::UString (string128, 128).fromAscii ("PreVolFader");
             *                     break;
             *                 case ChannelContext::kPostVolumeFader:
             *                     Steinberg::UString (string128, 128).fromAscii ("PostVolFader");
             *                     break;
             *                 case ChannelContext::kUsedAsPanner:
             *                     Steinberg::UString (string128, 128).fromAscii ("UsedAsPanner");
             *                     break;
             *                 default:
             *                     Steinberg::UString (string128, 128).fromAscii ("unknown!");
             *                     break;
             *             }
             *         }
             *
             *         // do not forget to call addRef () if you want to keep this list
             *     }
             * }
             */
            #include <steinberg/vst3/base/WarningsPush.h>
            class IInfoListener: public FUnknown
            {
                public:
                    /**
                     * Receive the channel context infos from host.
                     */
                    virtual tresult PLUGIN_API setChannelContextInfos (IAttributeList* list) = 0;

                public:
                    static const FUID iid;
            };
            #include <steinberg/vst3/base/WarningsPop.h>

        } /* namespace ChannelContext */
    } /* namespace Vst */
} /* namespace Steinberg */


#endif /* _3RD_PARTY_STEINBERG_VST3_VST_IINFOLISTENER_H_ */
