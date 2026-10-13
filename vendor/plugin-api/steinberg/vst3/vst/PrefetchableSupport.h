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

#ifndef _3RD_PARTY_STEINBERG_VST3_VST_PREFETCHABLESUPPORT_H_
#define _3RD_PARTY_STEINBERG_VST3_VST_PREFETCHABLESUPPORT_H_

#include <steinberg/vst3/base/FUnknown.h>
#include <steinberg/vst3/vst/Types.h>

#include <steinberg/vst3/base/AlignPush.h>

namespace Steinberg
{
    namespace Vst
    {
        /**
         * Prefetchable Support Type
         */
        typedef uint32 PrefetchableSupport;

        /**
         * Prefetchable Support Enum
         */
        enum ePrefetchableSupport
        {
            kIsNeverPrefetchable = 0,   ///< every instance of the plug does not support prefetch processing
            kIsYetPrefetchable,         ///< in the current state the plug support prefetch processing
            kIsNotYetPrefetchable,      ///< in the current state the plug does not support prefetch processing
            kNumPrefetchableSupport
        };

    } /* namespace Vst */
} /* namespace Steinberg */

#include <steinberg/vst3/base/AlignPop.h>


#endif /* _3RD_PARTY_STEINBERG_VST3_VST_PREFETCHABLESUPPORT_H_ */
