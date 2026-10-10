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

#ifndef _3RD_PARTY_STEINBERG_VST3_VST_ICONTEXTMENU_H_
#define _3RD_PARTY_STEINBERG_VST3_VST_ICONTEXTMENU_H_

#include <steinberg/vst3/gui/IPlugView.h>
#include <steinberg/vst3/vst/IContextMenuItem.h>
#include <steinberg/vst3/vst/IContextMenuTarget.h>

#include <steinberg/vst3/base/AlignPush.h>

namespace Steinberg
{
    namespace Vst
    {
        /**
         * Context Menu interface: Vst::IContextMenu
         *
         * A context menu is composed of Item (entry). A Item is defined by a name, a tag, a flag
         * and a associated target (called when this item will be selected/executed).
         * With IContextMenu the plug-in can retrieve a Item, add a Item, remove a Item and pop-up the menu.
         *
         * @see @ref IComponentHandler3 for more information.
         */
        #include <steinberg/vst3/base/WarningsPush.h>
        class IContextMenu: public FUnknown
        {
            public:
                typedef IContextMenuItem Item;

                /**
                 * Gets the number of menu items.
                 */
                virtual int32 PLUGIN_API getItemCount() = 0;

                /**
                 * Gets a menu item and its target (target could be not assigned).
                 */
                virtual tresult PLUGIN_API getItem(int32 index, Item & item /*out*/, IContextMenuTarget **target /*out*/) = 0;

                /**
                 * Adds a menu item and its target.
                 */
                virtual tresult PLUGIN_API addItem(const Item & item, IContextMenuTarget *target) = 0;

                /**
                 * Removes a menu item.
                 */
                virtual tresult PLUGIN_API removeItem(const Item & item, IContextMenuTarget *target) = 0;

                /**
                 * Pop-ups the menu. Coordinates are relative to the top-left position of the plug-ins view.
                 */
                virtual tresult PLUGIN_API popup(UCoord x, UCoord y) = 0;

            public:
                static const FUID iid;
        };
        #include <steinberg/vst3/base/WarningsPop.h>

    } /* namespace Vst */
} /* namespace Steinberg */

#include <steinberg/vst3/base/AlignPop.h>


#endif /* _3RD_PARTY_STEINBERG_VST3_VST_ICONTEXTMENU_H_ */
