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

#ifndef _3RD_PARTY_STEINBERG_VST3_GUI_IPLUGVIEWCONTENTSCALESUPPORT_H_
#define _3RD_PARTY_STEINBERG_VST3_GUI_IPLUGVIEWCONTENTSCALESUPPORT_H_

#include <steinberg/vst3/base/FUnknown.h>
#include <steinberg/vst3/vst/Types.h>

namespace Steinberg
{
    /**
     * Plug-in view content scale support
     *
     * This interface communicates the content scale factor from the host to the plug-in view on
     * systems where plug-ins cannot get this information directly like Microsoft Windows.
     *
     * The host calls setContentScaleFactor directly before or after the plug-in view is attached and when
     * the scale factor changes while the view is attached (system change or window moved to another screen
     * with different scaling settings).
     *
     * The host may call setContentScaleFactor in a different context, for example: scaling the plug-in
     * editor for better readability.
     *
     * When a plug-in handles this (by returning kResultTrue), it needs to scale the width and height of
     * its view by the scale factor and inform the host via a IPlugFrame::resizeView(). The host will then
     * call IPlugView::onSize().
     *
     * Note that the host is allowed to call setContentScaleFactor() at any time the IPlugView is valid.
     * If this happens before the IPlugFrame object is set on your view, make sure that when the host calls
     * IPlugView::getSize() afterwards you return the size of your view for that new scale factor.
     *
     * It is recommended to implement this interface on Microsoft Windows to let the host know that the
     * plug-in is able to render in different scalings.
     */
    #include <steinberg/vst3/base/WarningsPush.h>
    class IPlugViewContentScaleSupport : public FUnknown
    {
        public:
            typedef float ScaleFactor;

        public:
            virtual tresult PLUGIN_API setContentScaleFactor(ScaleFactor factor) = 0;

        public:
            static const FUID iid;
    };
    #include <steinberg/vst3/base/WarningsPop.h>

} /* namespace Steinberg */

#include <steinberg/vst3/gui/IPlugFrame.h>

#endif /* _3RD_PARTY_STEINBERG_VST3_GUI_IPLUGVIEWCONTENTSCALESUPPORT_H_ */
