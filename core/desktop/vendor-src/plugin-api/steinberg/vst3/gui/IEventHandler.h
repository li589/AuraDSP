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

#ifndef _3RD_PARTY_STEINBERG_VST3_GUI_IEVENTHANDLER_H_
#define _3RD_PARTY_STEINBERG_VST3_GUI_IEVENTHANDLER_H_

#include <steinberg/vst3/base/FUnknown.h>

namespace Steinberg
{
    namespace Linux
    {
        typedef int         FileDescriptor;

        /**
         * Linux event handler interface
         * @see IRunLoop
         */
        #include <steinberg/vst3/base/WarningsPush.h>
        class IEventHandler: public FUnknown
        {
            public:
                virtual void PLUGIN_API onFDIsSet(FileDescriptor fd) = 0;

            public:
                static const FUID iid;
        };
        #include <steinberg/vst3/base/WarningsPop.h>


    } /* namespace Linux */
} /* namespace Steinberg */

#endif /* _3RD_PARTY_STEINBERG_VST3_GUI_IEVENTHANDLER_H_ */
