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

#ifndef _3RD_PARTY_STEINBERG_VST3_VST_ICONTEXTMENUITEM_H_
#define _3RD_PARTY_STEINBERG_VST3_VST_ICONTEXTMENUITEM_H_

#include <steinberg/vst3/gui/IPlugView.h>

#include <steinberg/vst3/base/AlignPush.h>

namespace Steinberg
{
    namespace Vst
    {
        /**
         * IContextMenuItem is an entry element of the context menu.
         */
        struct IContextMenuItem
        {
            String128 name;                                 ///< Name of the item
            int32 tag;                                      ///< Identifier tag of the item
            int32 flags;                                    ///< Flags of the item

            enum Flags {
                kIsSeparator    = 1 << 0,                   ///< Item is a separator
                kIsDisabled     = 1 << 1,                   ///< Item is disabled
                kIsChecked      = 1 << 2,                   ///< Item is checked
                kIsGroupStart   = 1 << 3 | kIsDisabled,     ///< Item is a group start (like sub folder)
                kIsGroupEnd     = 1 << 4 | kIsSeparator,    ///< Item is a group end
            };
        };
    } /* namespace Vst */
} /* namespace Steinberg */

#include <steinberg/vst3/base/AlignPop.h>


#endif /* _3RD_PARTY_STEINBERG_VST3_VST_ICONTEXTMENUITEM_H_ */
