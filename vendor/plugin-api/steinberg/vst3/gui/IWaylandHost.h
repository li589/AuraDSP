/*
 * Copyright 2025, Steinberg Media Technologies GmbH, All Rights Reserved
 * Copyright 2025 Linux Studio Plugins Project <lsp.plugin@gmail.com>
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

#ifndef _3RD_PARTY_STEINBERG_VST3_GUI_IWAYLANDHOST_H_
#define _3RD_PARTY_STEINBERG_VST3_GUI_IWAYLANDHOST_H_

#include <steinberg/vst3/base/FUnknown.h>
#include <steinberg/vst3/gui/Wayland.h>

namespace Steinberg
{
    /**
     * IWaylandHost: Wayland host interface
     *
     * Implemented as a singleton in the host application.
     * Created via IHostApplication::createInstance.
     *
     * @since 3.8.0
     */
    #include <steinberg/vst3/base/WarningsPush.h>
    class IWaylandHost: public FUnknown
    {
        public:
            /**
             * Open a Wayland connection to the host.
             * @note UI-thread & Initialized
             */
            virtual wl_display* PLUGIN_API openWaylandConnection () = 0;

            /**
             * Close a previously created connection.
             * @note UI-thread & Initialized
             */
            virtual tresult PLUGIN_API closeWaylandConnection (wl_display* display) = 0;

        public:
            static const FUID iid;
    };
    #include <steinberg/vst3/base/WarningsPop.h>

}

#endif /* _3RD_PARTY_STEINBERG_VST3_GUI_IWAYLANDHOST_H_ */
