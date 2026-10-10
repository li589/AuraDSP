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

#ifndef _3RD_PARTY_STEINBERG_VST3_BASE_IUPDATEHANDLER_H_
#define _3RD_PARTY_STEINBERG_VST3_BASE_IUPDATEHANDLER_H_

#include <steinberg/vst3/base/IDependent.h>

namespace Steinberg
{
    /**
     * Host implements dependency handling for plugins.
     *   - Install/Remove change notifications
     *   - Trigger updates when an object has changed
     *
     * Can be used between host-objects and the Plug-In or
     * inside the Plug-In to handle internal updates!
     *
     * @see IDependent
     */
    #include <steinberg/vst3/base/WarningsPush.h>
    class IUpdateHandler: public FUnknown
    {
        public:
            /**
             * Install update notification for given object. It is essential to
             * remove all dependencies again using 'removeDependent'! Dependencies
             * are not removed automatically when the 'object' is released!
             * @param object interface to object that sends change notifications
             * @param dependent interface through which the update is passed
             */
            virtual tresult PLUGIN_API addDependent(FUnknown *object, IDependent *dependent) = 0;

            /**
             * Remove a previously installed dependency.
             */
            virtual tresult PLUGIN_API removeDependent(FUnknown *object, IDependent *dependent) = 0;

            /**
             * Inform all dependents, that object has changed.
             * @param object is the object that has changed
             * @param message is a value of enum IDependent::ChangeMessage, usually
             * IDependent::kChanged - can be a private message as well (only known to sender and dependent)
             */
            virtual tresult PLUGIN_API triggerUpdates (FUnknown *object, int32 message) = 0;

            /**
             * Same as triggerUpdates, but delivered in idle (usefull to collect updates).
             */
            virtual tresult PLUGIN_API deferUpdates (FUnknown* object, int32 message) = 0;

        public:
            static const FUID iid;
    };
    #include <steinberg/vst3/base/WarningsPop.h>

} /* namespace Steinberg */

#endif /* _3RD_PARTY_STEINBERG_VST3_BASE_IUPDATEHANDLER_H_ */
