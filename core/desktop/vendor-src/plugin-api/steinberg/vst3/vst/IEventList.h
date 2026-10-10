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

#ifndef _3RD_PARTY_STEINBERG_VST3_VST_EVENTLIST_H_
#define _3RD_PARTY_STEINBERG_VST3_VST_EVENTLIST_H_

#include <steinberg/vst3/base/FUnknown.h>
#include <steinberg/vst3/vst/Event.h>

namespace Steinberg
{
    namespace Vst
    {
        /**
         * List of events to process: Vst::IEventList
         * @see ProcessData, Event
         */
        #include <steinberg/vst3/base/WarningsPush.h>
        class IEventList: public FUnknown
        {
            public:
                /**
                 * Returns the count of events.
                 */
                virtual int32 PLUGIN_API getEventCount () = 0;

                /**
                 * Gets parameter by index.
                 */
                virtual tresult PLUGIN_API getEvent (int32 index, Event & e /*out*/) = 0;

                /**
                 * Adds a new event.
                 */
                virtual tresult PLUGIN_API addEvent (Event & e /*in*/) = 0;

            public:
                static const FUID iid;
        };
        #include <steinberg/vst3/base/WarningsPop.h>

    } /* namespace Vst */
} /* namespace Steinberg */

#endif /* _3RD_PARTY_STEINBERG_VST3_VST_EVENTLIST_H_ */
