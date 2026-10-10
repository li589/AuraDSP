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

#ifndef _3RD_PARTY_STEINBERG_VST3_VERSION_H_
#define _3RD_PARTY_STEINBERG_VST3_VERSION_H_

// The compatibility version of official VST3 SDK
#define VST3_VERSION_MAJOR      3
#define VST3_VERSION_MINOR      8
#define VST3_VERSION_MICRO      0

#define VST3_STRINGIFY1(x)      #x
#define VST3_STRINGIFY(x)       VST3_STRINGIFY1(x)

#define VST3_SDK_VERSION        "VST " \
                                VST3_STRINGIFY(VST3_VERSION_MAJOR) "." \
                                VST3_STRINGIFY(VST3_VERSION_MINOR) "." \
                                VST3_STRINGIFY(VST3_VERSION_MICRO)

#endif /* _3RD_PARTY_STEINBERG_VST3_VERSION_H_ */
