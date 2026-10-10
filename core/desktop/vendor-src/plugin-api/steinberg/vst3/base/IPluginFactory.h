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

#ifndef _3RD_PARTY_STEINBERG_VST3_BASE_IPLUGINFACTORY_H_
#define _3RD_PARTY_STEINBERG_VST3_BASE_IPLUGINFACTORY_H_

#include <steinberg/vst3/base/FUnknown.h>
#include <steinberg/vst3/base/PFactoryInfo.h>
#include <steinberg/vst3/base/PClassInfo.h>

namespace Steinberg
{
    /**
     * Class factory that any plug-in defines for creating class instances: IPluginFactory.
     *
     * From the host's point of view a plug-in module is a factory which can create
     * a certain kind of object(s). The interface IPluginFactory provides methods
     * to get information about the classes exported by the plug-in and a
     * mechanism to create instances of these classes (that usually define the IPluginBase interface).
     */
    #include <steinberg/vst3/base/WarningsPush.h>
    class IPluginFactory: public FUnknown
    {
        public:
            /**
             * Fill a PFactoryInfo structure with information about the plug-in vendor.
             */
            virtual tresult PLUGIN_API getFactoryInfo(PFactoryInfo *info) = 0;

            /**
             * Returns the number of exported classes by this factory. If you are using the CPluginFactory
             * implementation provided by the SDK, it returns the number of classes you registered with
             * CPluginFactory::registerClass.
             */
            virtual int32 PLUGIN_API countClasses() = 0;

            /**
             * Fill a PClassInfo structure with information about the class at the specified index.
             */
            virtual tresult PLUGIN_API getClassInfo(int32 index, PClassInfo *info) = 0;

            /**
             * Create a new class instance.
             */
            virtual tresult PLUGIN_API createInstance(FIDString cid, FIDString _iid, void **obj) = 0;

        public:
            static const FUID iid;
    };
    #include <steinberg/vst3/base/WarningsPop.h>

} /* namespace Steinberg */

#endif /* _3RD_PARTY_STEINBERG_VST3_BASE_IPLUGINFACTORY_H_ */
