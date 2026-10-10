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

#ifndef _3RD_PARTY_STEINBERG_VST3_GUI_IPLUGVIEW_H_
#define _3RD_PARTY_STEINBERG_VST3_GUI_IPLUGVIEW_H_

#include <steinberg/vst3/base/FUnknown.h>
#include <steinberg/vst3/vst/Types.h>
#include <steinberg/vst3/gui/ViewRect.h>

namespace Steinberg
{
    class IPlugFrame;

    /**
     * Plug-in definition of a view.
     *
     * Sizing of a view
     *
     * Usually, the size of a plug-in view is fixed. But both the host and the plug-in can cause
     * a view to be resized:
     *   - Host: If IPlugView::canResize () returns kResultTrue the host will set up the window
     *     so that the user can resize it. While the user resizes the window, IPlugView::checkSizeConstraint()
     *     is called, allowing the plug-in to change the size to a valid supported rectangle size.
     *     The host then resizes the window to this rect and has to call IPlugView::onSize().
     *   - Plug-in: The plug-in can call IPlugFrame::resizeView() and cause the host to resize the window.
     *
     * Afterwards, in the same callstack, the host has to call IPlugView::onSize() if a resize is needed (size was changed).
     * Note that if the host calls IPlugView::getSize() before calling IPlugView::onSize() (if needed),
     * it will get the current (old) size not the wanted one!!
     *
     * Here the calling sequence:
     *   - plug-in->host: IPlugFrame::resizeView (newSize)
     *   - host->plug-in (optional): IPlugView::getSize () returns the currentSize (not the newSize!)
     *   - host->plug-in: if newSize is different from the current size: IPlugView::onSize (newSize)
     *   - host->plug-in (optional): IPlugView::getSize () returns the newSize
     *
     * Please only resize the platform representation of the view when IPlugView::onSize() is called.
     *
     * Keyboard handling
     *
     * The plug-in view receives keyboard events from the host. A view implementation must not handle
     * keyboard events by the means of platform callbacks, but let the host pass them to the view. The host
     * depends on a proper return value when IPlugView::onKeyDown is called, otherwise the plug-in view may
     * cause a malfunction of the host's key command handling.
     *
     * @see IPlugFrame, @ref platformUIType
     */
    #include <steinberg/vst3/base/WarningsPush.h>
    class IPlugView: public FUnknown
    {
        public:
            /**
             * Is Platform UI Type supported
             * @param type IDString of @ref platformUIType
             */
            virtual tresult PLUGIN_API isPlatformTypeSupported(FIDString type) = 0;

            /**
             * The parent window of the view has been created, the (platform) representation of the view
             * should now be created as well.
             *
             * @note that the parent is owned by the caller and you are not allowed to alter it in any way
             * other than adding your own views.
             *
             * @note that in this call the plug-in could call a IPlugFrame::resizeView()!
             * @param parent platform handle of the parent window or view
             * @param type @ref platformUIType which should be created
             */
            virtual tresult PLUGIN_API attached(void *parent, FIDString type) = 0;

            /**
             * The parent window of the view is about to be destroyed.
             * You have to remove all your own views from the parent window or view.
             */
            virtual tresult PLUGIN_API removed() = 0;

            /**
             * Handling of mouse wheel.
             */
            virtual tresult PLUGIN_API onWheel(float distance) = 0;

            /**
             * Handling of keyboard events : Key Down.
             * @param key unicode code of key
             * @param keyCode virtual keycode for non ascii keys - @see @ref VirtualKeyCodes in keycodes.h
             * @param modifiers any combination of modifiers - @see @ref KeyModifier in keycodes.h
             *
             * @return kResultTrue if the key is handled, otherwise kResultFalse.
             *
             * Please note that kResultTrue must only be returned if the key has really been
             * handled. Otherwise key command handling of the host might be blocked!
             */
            virtual tresult PLUGIN_API onKeyDown(char16 key, int16 keyCode, int16 modifiers) = 0;

            /**
             * Handling of keyboard events : Key Up.
             *
             * @param key unicode code of key
             * @param keyCode virtual keycode for non ascii keys - @see @ref VirtualKeyCodes in keycodes.h
             * @param modifiers any combination of KeyModifier - see @ref KeyModifier in keycodes.h
             * @return kResultTrue if the key is handled, otherwise return kResultFalse.
             */
            virtual tresult PLUGIN_API onKeyUp(char16 key, int16 keyCode, int16 modifiers) = 0;

            /**
             * Returns the size of the platform representation of the view.
             */
            virtual tresult PLUGIN_API getSize(ViewRect *size) = 0;

            /**
             * Resizes the platform representation of the view to the given rect.
             *
             * @note that if the plug-in requests a resize (IPlugFrame::resizeView()) onSize has to be
             * called afterward.
             */
            virtual tresult PLUGIN_API onSize(ViewRect *newSize) = 0;

            /**
             * Focus changed message.
             */
            virtual tresult PLUGIN_API onFocus(TBool state) = 0;

            /**
             * Sets IPlugFrame object to allow the plug-in to inform the host about resizing.
             */
            virtual tresult PLUGIN_API setFrame(IPlugFrame *frame) = 0;

            /**
             * Is view sizable by user.
             */
            virtual tresult PLUGIN_API canResize() = 0;

            /**
             * On live resize this is called to check if the view can be resized to the given rect, if not
             * adjust the rect to the allowed size.
             */
            virtual tresult PLUGIN_API checkSizeConstraint(ViewRect *rect) = 0;

        public:
            static const FUID iid;
    };
    #include <steinberg/vst3/base/WarningsPop.h>

} /* namespace Steinberg */

#include <steinberg/vst3/gui/IPlugFrame.h>

#endif /* _3RD_PARTY_STEINBERG_VST3_GUI_IPLUGVIEW_H_ */
