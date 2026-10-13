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

#ifndef _3RD_PARTY_STEINBERG_VST3_GUI_VIEWRECT_H_
#define _3RD_PARTY_STEINBERG_VST3_GUI_VIEWRECT_H_

#include <steinberg/vst3/base/TypeSizeCheck.h>
#include <steinberg/vst3/vst/Types.h>

namespace Steinberg
{
    /**
     * Graphical rectangle structure. Used with IPlugView.
     */
    struct ViewRect
    {
        int32 left;
        int32 top;
        int32 right;
        int32 bottom;
    };

    SMTG_TYPE_SIZE_CHECK(ViewRect, 16, 16, 16, 16)

    /**
     * Platform UI Types
     *
     * List of Platform UI types for IPlugView. This list is used to match the GUI-System between
     * the host and a plug-in in case that an OS provides multiple GUI-APIs.
     */
    /**
     * The parent parameter in IPlugView::attached() is a HWND handle (Microsoft Windows).
     * You should attach a child window to it.
     */
    const FIDString kPlatformTypeHWND = "HWND";

    /**
     * The parent parameter in IPlugView::attached() is a WindowRef (Mac OS X).
     * You should attach a HIViewRef to the content view of the window.
     */
    const FIDString kPlatformTypeHIView = "HIView";

    /**
     * The parent parameter in IPlugView::attached() is a NSView pointer (Mac OS X).
     * You should attach a NSView to it.
     */
    const FIDString kPlatformTypeNSView = "NSView";

    /**
     * The parent parameter in IPlugView::attached() is a UIView pointer (iOS).
     * You should attach an UIView to it.
     */
    const FIDString kPlatformTypeUIView = "UIView";

    /**
     * The parent parameter in IPlugView::attached() is a X11 Window supporting XEmbed (X11).
     * You should attach a Window to it that supports the XEmbed extension.
     * See https://standards.freedesktop.org/xembed-spec/xembed-spec-latest.html
     */
    const FIDString kPlatformTypeX11EmbedWindowID = "X11EmbedWindowID";

    /**
     * The parent parameter in IPlugView::attached() is a wl_surface pointer.
     * The plug-in should create a wl_surface and attach it to the parent surface as a wl_subsurface.
     * The plug-in should not connect to the system compositor to do so, but use
     * IWaylandHost::openWaylandConnection().
     * See https://wayland.freedesktop.org/docs/html
     */
    const FIDString kPlatformTypeWaylandSurfaceID = "WaylandSurfaceID";

} /* namespace Steinberg */

#endif /* _3RD_PARTY_STEINBERG_VST3_GUI_VIEWRECT_H_ */
