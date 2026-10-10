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

#ifndef _3RD_PARTY_STEINBERG_VST3_GUI_IWAYLANDFRAME_H_
#define _3RD_PARTY_STEINBERG_VST3_GUI_IWAYLANDFRAME_H_

#include <steinberg/vst3/base/FUnknown.h>
#include <steinberg/vst3/vst/Types.h>
#include <steinberg/vst3/gui/ViewRect.h>
#include <steinberg/vst3/gui/Wayland.h>

namespace Steinberg
{

    /**
     * IWaylandFrame interface
     *
     * Interface to query additional information about the host plug-in frame in a Wayland session.
     * To be implemented by the VST3 IPlugFrame class.
     *
     * @since 3.8.0
     * @see IPlugFrame
     */
    #include <steinberg/vst3/base/WarningsPush.h>
    class IWaylandFrame: public FUnknown
    {
        public:
            /**
             * Get the parent Wayland surface.
             * The plug-in must not change the state of the parent surface.
             * @note UI-thread & plugView
             */
            virtual wl_surface* PLUGIN_API getWaylandSurface (wl_display* display) = 0;

            /**
             * Get the parent XDG surface for creating popup windows.
             * If the parent surface is not an xdg_surface, this returns the first xdg_surface that
             * can be found in the surface hierarchy, starting the search with the parent surface.
             * The plug-in must not change the state of the parent surface.
             * The size and position of the parent surface, relative to the top left corner of
             * the plug-in surface, is returned in parentSize.
             *
             * @note UI-thread & plugView
             */
            virtual xdg_surface * PLUGIN_API getParentSurface(ViewRect& parentSize, wl_display* display) = 0;

            /**
             * Get the XDG toplevel surface containing the plug-in frame.
             * The plug-in must not change the state of the returned xdg_toplevel.
             *
             * @note UI-thread & plugView
             */
            virtual xdg_toplevel * PLUGIN_API getParentToplevel(wl_display* display) = 0;

        public:
            static const FUID iid;
    };
    #include <steinberg/vst3/base/WarningsPop.h>

} // namespace Steinberg

#endif /* _3RD_PARTY_STEINBERG_VST3_GUI_IWAYLANDFRAME_H_ */
