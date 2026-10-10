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

#ifndef _3RD_PARTY_STEINBERG_VST3_BASE_PFACTORYINFO_H_
#define _3RD_PARTY_STEINBERG_VST3_BASE_PFACTORYINFO_H_

#include <steinberg/vst3/base/FUnknown.h>
#include <steinberg/vst3/base/Platform.h>

namespace Steinberg
{
    /**
     * Basic Information about the class factory of the plug-in.
     */
    struct PFactoryInfo
    {
        enum FactoryFlags
        {
            /**
             * Nothing
             */
            kNoFlags                    = 0,

            /**
             * The number of exported classes can change each time the Module is loaded. If this flag
             * is set, the host does not cache class information. This leads to a longer startup time
             * because the host always has to load the Module to get the current class information.
             */
            kClassesDiscardable         = 1 << 0,

            /**
             * This flag is deprecated, do not use anymore, resp. it will get ignored from
             * Cubase/Nuendo 12 and later.
             * @deprecated
             */
            kLicenseCheck               = 1 << 1,

            /**
             * Component will not be unloaded until process exit
             */
            kComponentNonDiscardable    = 1 << 3,

            /**
             * Components have entirely unicode encoded strings (True for VST 3 plug-ins so far).
             */
            kUnicode                    = 1 << 4
        };

        enum
        {
            kURLSize            = 256,
            kEmailSize          = 128,
            kNameSize           = 64
        };

        char8 vendor[kNameSize];    ///< e.g. "Steinberg Media Technologies"
        char8 url[kURLSize];        ///< e.g. "http://www.steinberg.de"
        char8 email[kEmailSize];    ///< e.g. "info@steinberg.de"
        int32 flags;                ///< (see FactoryFlags above)
    };

} /* namespace Steinberg */

#endif /* _3RD_PARTY_STEINBERG_VST3_BASE_PFACTORYINFO_H_ */
