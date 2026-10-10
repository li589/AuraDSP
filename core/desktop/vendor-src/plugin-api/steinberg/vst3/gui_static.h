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

#ifndef _3RD_PARTY_STEINBERG_VST3_GUI_STATIC_H_
#define _3RD_PARTY_STEINBERG_VST3_GUI_STATIC_H_

#include <steinberg/vst3/gui.h>

namespace Steinberg
{
    DEF_CLASS_IID(IPlugView, 0x5BC32507, 0xD06049EA, 0xA6151B52, 0x2B755B29)
    DEF_CLASS_IID(IPlugFrame, 0x367FAF01, 0xAFA94693, 0x8D4DA2A0, 0xED0882A3)
    DEF_CLASS_IID(IPlugViewContentScaleSupport, 0x65ED9690, 0x8AC44525, 0x8AADEF7A, 0x72EA703F)
    DEF_CLASS_IID(IWaylandHost, 0x5E9582EE, 0x86594652, 0xB213678E, 0x7F1A705E)
    DEF_CLASS_IID(IWaylandFrame, 0x809FAEC6, 0x231C4FFA, 0x98ED046C, 0x6E9E2003)

    namespace Linux
    {
        DEF_CLASS_IID(IEventHandler, 0x561E65C9, 0x13A0496F, 0x813A2C35, 0x654D7983)
        DEF_CLASS_IID(ITimerHandler, 0x10BDD94F, 0x41424774, 0x821FAD8F, 0xECA72CA9)
        DEF_CLASS_IID(IRunLoop, 0x18C35366, 0x97764F1A, 0x9C5B8385, 0x7A871389)
    } /* namespace Linux */
} /* namespace Steinberg */

#endif /* _3RD_PARTY_STEINBERG_VST3_GUI_STATIC_H_ */
