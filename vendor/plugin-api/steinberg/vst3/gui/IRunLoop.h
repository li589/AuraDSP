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

#ifndef _3RD_PARTY_STEINBERG_VST3_GUI_IRUNLOOP_H_
#define _3RD_PARTY_STEINBERG_VST3_GUI_IRUNLOOP_H_

#include <steinberg/vst3/base/FUnknown.h>
#include <steinberg/vst3/gui/IEventHandler.h>
#include <steinberg/vst3/gui/ITimerHandler.h>

namespace Steinberg
{
    namespace Linux
    {
        /**
         * Linux host run loop interface
         *
         * On Linux the host has to provide this interface to the plug-in as there's no global event run loop
         * defined as on other platforms.
         *
         * This can be done by IPlugFrame and the context which is passed to the plug-in as an argument
         * in the method IPlugFactory3::setHostContext. This way the plug-in can get a runloop even if
         * it does not have an editor.
         *
         * A plug-in can register an event handler for a file descriptor. The host has to call the event
         * handler when the file descriptor is marked readable.
         *
         * A plug-in also can register a timer which will be called repeatedly until it is unregistered.
         */
        #include <steinberg/vst3/base/WarningsPush.h>
        class IRunLoop: public FUnknown
        {
            public:
                virtual tresult PLUGIN_API registerEventHandler(IEventHandler *handler, FileDescriptor fd) = 0;
                virtual tresult PLUGIN_API unregisterEventHandler(IEventHandler *handler) = 0;

                virtual tresult PLUGIN_API registerTimer(ITimerHandler *handler, TimerInterval milliseconds) = 0;
                virtual tresult PLUGIN_API unregisterTimer(ITimerHandler *handler) = 0;

            public:
                static const FUID iid;
        };
        #include <steinberg/vst3/base/WarningsPop.h>

    } /* namespace Linux */
} /* namespace Steinberg */

#endif /* _3RD_PARTY_STEINBERG_VST3_GUI_IRUNLOOP_H_ */
