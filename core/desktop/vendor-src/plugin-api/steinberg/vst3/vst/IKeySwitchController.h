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

#ifndef _3RD_PARTY_STEINBERG_VST3_VST_IKEYSWITCHCONTROLLER_H_
#define _3RD_PARTY_STEINBERG_VST3_VST_IKEYSWITCHCONTROLLER_H_

#include <steinberg/vst3/base/FUnknown.h>
#include <steinberg/vst3/vst/Types.h>
#include <steinberg/vst3/vst/KeySwitchInfo.h>

namespace Steinberg
{
    namespace Vst
    {
        /**
         * Extended plug-in interface IEditController for key switches support: Vst::IKeyswitchController
         *
         * When a (instrument) plug-in supports such interface, the host could get from the plug-in the current set
         * of used key switches (megatrig/articulation) for a given channel of a event bus and then automatically use them (like in Cubase 6) to
         * create VST Expression Map (allowing to associated symbol to a given articulation / key switch).
         */
        #include <steinberg/vst3/base/WarningsPush.h>
        class IKeyswitchController: public FUnknown
        {
        public:
            /**
             * Returns number of supported key switches for event bus index and channel.
             */
            virtual int32 PLUGIN_API getKeyswitchCount (int32 busIndex, int16 channel) = 0;

            /**
             * Returns key switch info.
             */
            virtual tresult PLUGIN_API getKeyswitchInfo (int32 busIndex, int16 channel, int32 keySwitchIndex, KeyswitchInfo & info /*out*/) = 0;

            static const FUID iid;
        };
        #include <steinberg/vst3/base/WarningsPop.h>

    } /* namespace Vst */
} /* namespace Steinberg */

#endif /* _3RD_PARTY_STEINBERG_VST3_VST_IKEYSWITCHCONTROLLER_H_ */
