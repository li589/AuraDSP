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

#ifndef _3RD_PARTY_STEINBERG_VST3_BASE_ISTRINGRESULT_H_
#define _3RD_PARTY_STEINBERG_VST3_BASE_ISTRINGRESULT_H_

#include <steinberg/vst3/base/Types.h>
#include <steinberg/vst3/base/FUnknown.h>

namespace Steinberg
{
    /**
     * Interface to return an ascii string of variable size.
     *
     * In order to manage memory allocation and deallocation properly,
     * this interface is used to transfer a string as result parameter of
     * a method requires a string of unknown size.
     */
    #include <steinberg/vst3/base/WarningsPush.h>
    class IStringResult: public FUnknown
    {
        public:
            virtual void PLUGIN_API setText(const char8 *text) = 0;

        public:
            static const FUID iid;
    };
    #include <steinberg/vst3/base/WarningsPop.h>

} /* namespace Steinberg */

#endif /* _3RD_PARTY_STEINBERG_VST3_BASE_ISTRINGRESULT_H_ */
