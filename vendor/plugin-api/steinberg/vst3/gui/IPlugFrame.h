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

#ifndef _3RD_PARTY_STEINBERG_VST3_GUI_IPLUGFRAME_H_
#define _3RD_PARTY_STEINBERG_VST3_GUI_IPLUGFRAME_H_

#include <steinberg/vst3/base/FUnknown.h>
#include <steinberg/vst3/vst/Types.h>
#include <steinberg/vst3/gui/ViewRect.h>

namespace Steinberg
{
    class IPlugView;

    /**
     * Callback interface passed to IPlugView.
     * Enables a plug-in to resize the view and cause the host to resize the window.
     */
    #include <steinberg/vst3/base/WarningsPush.h>
    class IPlugFrame: public FUnknown
    {
        public:
            /**
             * Called to inform the host about the resize of a given view.
             * Afterwards the host has to call IPlugView::onSize ().
             */
            virtual tresult PLUGIN_API resizeView(IPlugView *view, ViewRect *newSize) = 0;

        public:
            static const FUID iid;
    };
    #include <steinberg/vst3/base/WarningsPop.h>

} /* namespace Steinberg */

#include <steinberg/vst3/gui/IPlugView.h>

#endif /* _3RD_PARTY_STEINBERG_VST3_GUI_IPLUGFRAME_H_ */
