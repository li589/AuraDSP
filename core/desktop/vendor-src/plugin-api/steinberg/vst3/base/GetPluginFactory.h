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

#ifndef _3RD_PARTY_STEINBERG_VST3_BASE_GETPLUGINFACTORY_H_
#define _3RD_PARTY_STEINBERG_VST3_BASE_GETPLUGINFACTORY_H_

#include <steinberg/vst3/base/Platform.h>
#include <steinberg/vst3/base/IPluginFactory.h>

#if SMTG_OS_WINDOWS

    #define STMG_INIT_FUNCTION  \
        SMTG_EXPORT_SYMBOL bool InitDll()
    #define STMG_FINI_FUNCTION  \
        SMTG_EXPORT_SYMBOL bool ExitDll()

#elif SMTG_OS_MACOS || SMTG_OS_IOS || SMTG_OS_OSX

    #include <CoreFoundation/CoreFoundation.h>

    #define STMG_INIT_FUNCTION  \
        SMTG_EXPORT_SYMBOL bool bundleEntry (CFBundleRef)
    #define STMG_FINI_FUNCTION  \
        SMTG_EXPORT_SYMBOL bool bundleExit (void)

#else /* SMTG_OS_LINUX || SMTG_OS_POSIX */

    #define STMG_INIT_FUNCTION  \
        SMTG_EXPORT_SYMBOL bool ModuleEntry (void*)
    #define STMG_FINI_FUNCTION  \
        SMTG_EXPORT_SYMBOL bool ModuleExit (void)

#endif

/**
 *  Plug-in entry point.
 *  Any plug-in must define and export this function.
 *  @example A typical implementation of GetPluginFactory looks like this:
 *
 * STMG_GET_PLUGIN_FACTORY_FUNCTION
 * {
 *     if (!gPluginFactory)
 *     {
 *         static PFactoryInfo factoryInfo =
 *         {
 *             "My Company Name",
 *             "http://www.mywebpage.com",
 *             "mailto:myemail@address.com",
 *             PFactoryInfo::kNoFlags
 *         };
 *
 *         gPluginFactory = new CPluginFactory (factoryInfo);
 *
 *         static PClassInfo componentClass =
 *         {
 *             INLINE_UID (0x00000000, 0x00000000, 0x00000000, 0x00000000), // replace by a valid uid
 *             1,
 *             "Service",    // category
 *             "Name"
 *         };
 *
 *         gPluginFactory->registerClass (&componentClass, MyComponentClass::newInstance);
 *     }
 *     else
 *         gPluginFactory->addRef ();
 *
 *     return gPluginFactory;
 * }
 */
#define STMG_GET_PLUGIN_FACTORY_FUNCTION \
    SMTG_EXPORT_SYMBOL ::Steinberg::IPluginFactory* PLUGIN_API GetPluginFactory()

namespace Steinberg
{
    typedef IPluginFactory * (PLUGIN_API *GetFactoryProc)();
} /* namespace Steinberg */

#endif /* _3RD_PARTY_STEINBERG_VST3_BASE_GETPLUGINFACTORY_H_ */
