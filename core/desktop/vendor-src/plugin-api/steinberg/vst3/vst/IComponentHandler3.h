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

#ifndef _3RD_PARTY_STEINBERG_VST3_VST_ICOMPONENTHANDLER3_H_
#define _3RD_PARTY_STEINBERG_VST3_VST_ICOMPONENTHANDLER3_H_

#include <steinberg/vst3/gui/IPlugView.h>
#include <steinberg/vst3/vst/IContextMenu.h>

namespace Steinberg
{
    namespace Vst
    {
        /**
         * Extended host callback interface Vst::IComponentHandler3 for an edit controller.
         *
         * A plug-in can ask the host to create a context menu for a given exported parameter ID
         * or a generic context menu.
         * The host may pre-fill this context menu with specific items regarding the parameter ID
         * like "Show automation for parameter", "MIDI learn" etc...
         *
         * The plug-in can use the context menu in two ways:
         *   - add its own items to the menu via the IContextMenu interface and call
         *     IContextMenu::popup(..) to create the pop-up. See the \ref IContextMenuExample.
         *   - extract the host menu items and add them to a context menu created by the plug-in.
         *
         * Note: You can and should use this even if you do not add your own items to the menu as
         * this is considered to be a big user value.
         *
         * @see @ref IContextMenu
         * @see @ref IContextMenuTarget
         *
         * @example
         * For example, Cubase adds its owned entries in the context menu opened with right-click on
         * an exported parameter when the plug-in uses createContextMenu.
         * Adding plug-in specific items to the context menu:
         *
         * class PluginContextMenuTarget: public IContextMenuTarget, public FObject
         * {
         *     public:
         *         PluginContextMenuTarget () {}
         *
         *         virtual tresult PLUGIN_API executeMenuItem (int32 tag)
         *         {
         *             // this will be called if the user has executed one of the menu items of the plug-in.
         *             // It will not be called for items of the host.
         *             switch (tag)
         *             {
         *                 case 1: break;
         *                 case 2: break;
         *             }
         *             return kResultTrue;
         *         }
         *
         *     OBJ_METHODS(PluginContextMenuTarget, FObject)
         *     DEFINE_INTERFACES
         *         DEF_INTERFACE (IContextMenuTarget)
         *     END_DEFINE_INTERFACES (FObject)
         *     REFCOUNT_METHODS(FObject)
         * };
         *
         * // The following is the code to create the context menu
         * void popupContextMenu (IComponentHandler* componentHandler, IPlugView* view, const ParamID* paramID, UCoord x, UCoord y)
         * {
         *     if (componentHandler == 0 || view == 0)
         *         return;
         *
         *     FUnknownPtr<IComponentHandler3> handler (componentHandler);
         *     if (handler == 0)
         *         return;
         *
         *     IContextMenu* menu = handler->createContextMenu (view, paramID);
         *     if (menu)
         *     {
         *         // here you can add your entries (optional)
         *         PluginContextMenuTarget* target = new PluginContextMenuTarget ();
         *
         *         IContextMenu::Item item = {0};
         *         UString128 ("My Item 1").copyTo (item.name, 128);
         *         item.tag = 1;
         *         menu->addItem (item, target);
         *
         *         UString128 ("My Item 2").copyTo (item.name, 128);
         *         item.tag = 2;
         *         menu->addItem (item, target);
         *         target->release ();
         *         //--end of adding new entries
         *
         *         // here the the context menu will be pop-up (and it waits a user interaction)
         *         menu->popup (x, y);
         *         menu->release();
         *     }
         * }
         */
        #include <steinberg/vst3/base/WarningsPush.h>
        class IComponentHandler3: public FUnknown
        {
            public:
                /**
                 * Creates a host context menu for a plug-in:
                 *   - If paramID is zero, the host may create a generic context menu.
                 *   - The IPlugView object must be valid.
                 *   - The return IContextMenu object needs to be released afterwards by the plug-in.
                 */
                virtual IContextMenu * PLUGIN_API createContextMenu(IPlugView *plugView, const ParamID *paramID) = 0;

            public:
                static const FUID iid;
        };
        #include <steinberg/vst3/base/WarningsPop.h>

    } /* namespace Vst */
} /* namespace Steinberg */

#endif /* _3RD_PARTY_STEINBERG_VST3_VST_ICOMPONENTHANDLER3_H_ */
