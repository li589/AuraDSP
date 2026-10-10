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

#ifndef _3RD_PARTY_STEINBERG_VST3_BASE_H_
#define _3RD_PARTY_STEINBERG_VST3_BASE_H_

#include <steinberg/vst3/version.h>

// Platform-specific macros and type definitions
#include <steinberg/vst3/base/Platform.h>
#include <steinberg/vst3/base/Types.h>
#include <steinberg/vst3/base/TypeSizeCheck.h>

// Miscellaneous data structures
#include <steinberg/vst3/base/PFactoryInfo.h>
#include <steinberg/vst3/base/PClassInfo.h>
#include <steinberg/vst3/base/PClassInfo2.h>
#include <steinberg/vst3/base/PClassInfoW.h>

// Interfaces
#include <steinberg/vst3/base/FUnknown.h>
#include <steinberg/vst3/base/IDependent.h>
#include <steinberg/vst3/base/ICloneable.h>
#include <steinberg/vst3/base/IUpdateHandler.h>
#include <steinberg/vst3/base/IBStream.h>
#include <steinberg/vst3/base/ISizableStream.h>
#include <steinberg/vst3/base/IStringResult.h>
#include <steinberg/vst3/base/IString.h>
#include <steinberg/vst3/base/IPluginBase.h>
#include <steinberg/vst3/base/IPluginFactory.h>
#include <steinberg/vst3/base/IPluginFactory2.h>
#include <steinberg/vst3/base/IPluginFactory3.h>
#include <steinberg/vst3/base/IPluginCompatibility.h>

// Utility funcitons
#include <steinberg/vst3/base/GetPluginFactory.h>
#include <steinberg/vst3/base/StrDefs.h>
#include <steinberg/vst3/base/TUID.h>

#endif /* _3RD_PARTY_STEINBERG_VST3_BASE_H_ */
