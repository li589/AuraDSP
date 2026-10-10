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

#ifndef _3RD_PARTY_STEINBERG_VST3_BASE_STATIC_H_
#define _3RD_PARTY_STEINBERG_VST3_BASE_STATIC_H_

#include <steinberg/vst3/base.h>

namespace Steinberg
{
    // VST 3.0
    DEF_CLASS_IID(IPluginBase, 0x22888DDB, 0x156E45AE, 0x8358B348, 0x08190625)
    DEF_CLASS_IID(IPluginFactory, 0x7A4D811C, 0x52114A1F, 0xAED9D2EE, 0x0B43BF9F)
    DEF_CLASS_IID(IPluginFactory2, 0x0007B650, 0xF24B4C0B, 0xA464EDB9, 0xF00B2ABB)
    DEF_CLASS_IID(IPluginFactory3, 0x4555A2AB, 0xC1234E57, 0x9B122910, 0x36878931)

    DEF_CLASS_IID(FUnknown, 0x00000000, 0x00000000, 0xC0000000, 0x00000046)

    DEF_CLASS_IID(ICloneable, 0xD45406B9, 0x3A2D4443, 0x9DAD9BA9, 0x85A1454B)
    DEF_CLASS_IID(IDependent, 0xF52B7AAE, 0xDE72416d, 0x8AF18ACE, 0x9DD7BD5E)
    DEF_CLASS_IID(IUpdateHandler, 0xF5246D56, 0x86544d60, 0xB026AFB5, 0x7B697B37)

    DEF_CLASS_IID(IBStream, 0xC3BF6EA2, 0x30994752, 0x9B6BF990, 0x1EE33E9B)
    DEF_CLASS_IID(ISizeableStream, 0x04F9549E, 0xE02F4E6E, 0x87E86A87, 0x47F4E17F)

    DEF_CLASS_IID(IStringResult, 0x550798BC, 0x872049DB, 0x84920A15, 0x3B50B7A8)
    DEF_CLASS_IID(IString, 0xF99DB7A3, 0x0FC14821, 0x800B0CF9, 0x8E348EDF)

    // VST 3.7.5
    DEF_CLASS_IID(IPluginCompatibility, 0x4AFD4B6A, 0x35D7C240, 0xA5C31414, 0xFB7D15E6)

} /* namespace Steinberg */

#endif /* _3RD_PARTY_STEINBERG_VST3_BASE_STATIC_H_ */
