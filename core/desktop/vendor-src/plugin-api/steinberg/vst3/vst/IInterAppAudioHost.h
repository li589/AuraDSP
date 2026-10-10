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

#ifndef _3RD_PARTY_STEINBERG_VST3_VST_IINTERAPPAUDIOHOST_H_
#define _3RD_PARTY_STEINBERG_VST3_VST_IINTERAPPAUDIOHOST_H_

#include <steinberg/vst3/base/FUnknown.h>
#include <steinberg/vst3/gui/ViewRect.h>
#include <steinberg/vst3/vst/Event.h>
#include <steinberg/vst3/vst/IInterAppAudioPresetManager.h>

namespace Steinberg
{
    namespace Vst
    {
        /**
         * Inter-App Audio host Interface.
         * Implemented by the InterAppAudio Wrapper.
         */
        #include <steinberg/vst3/base/WarningsPush.h>
        class IInterAppAudioHost: public FUnknown
        {
            public:
                /** get the size of the screen
                 * @param size size of the screen
                 * @param scale scale of the screen
                 * @return kResultTrue on success
                 */
                virtual tresult PLUGIN_API getScreenSize(ViewRect *size, float *scale) = 0;

                /**
                 * Get status of connection
                 * @return kResultTrue if an Inter-App Audio connection is established
                 */
                virtual tresult PLUGIN_API connectedToHost() = 0;

                /**
                 * Switch to the host.
                 * @return kResultTrue on success
                 */
                virtual tresult PLUGIN_API switchToHost() = 0;

                /**
                 * Send a remote control event to the host
                 * @param event event type, see AudioUnitRemoteControlEvent in the iOS SDK documentation for possible types
                 * @return kResultTrue on success
                 */
                virtual tresult PLUGIN_API sendRemoteControlEvent(uint32 event) = 0;

                /**
                 * Ask for the host icon.
                 * @param icon pointer to a CGImageRef
                 * @return kResultTrue on success
                 */
                virtual tresult PLUGIN_API getHostIcon(void **icon) = 0;

                /**
                 * Schedule an event from the user interface thread
                 * @param event the event to schedule
                 * @return kResultTrue on success
                 */
                virtual tresult PLUGIN_API scheduleEventFromUI(Event & event) = 0;

                /**
                 * Get the preset manager
                 * @param cid class ID to use by the preset manager
                 * @return the preset manager. Needs to be released by called.
                 */
                virtual IInterAppAudioPresetManager * PLUGIN_API createPresetManager(const TUID & cid) = 0;

                /**
                 * Show the settings view
                 * currently includes MIDI settings and Tempo setting
                 * @return kResultTrue on success
                 */
                virtual tresult PLUGIN_API showSettingsView() = 0;

            public:
                static const FUID iid;
        };
        #include <steinberg/vst3/base/WarningsPop.h>

    } /* namespace Vst */
} /* namespace Steinberg */



#endif /* _3RD_PARTY_STEINBERG_VST3_VST_IINTERAPPAUDIOHOST_H_ */
