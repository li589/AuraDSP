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

#if SMTG_OS_MACOS
    #pragma GCC diagnostic ignored "-Wunknown-warning-option"
    #pragma GCC diagnostic ignored "-Wpragma-pack"
    #if SMTG_PLATFORM_64
        #pragma pack(push, 16)
    #else
        #pragma pack(push, 1)
    #endif
#elif defined __BORLANDC__
    #pragma -a8
#elif SMTG_OS_WINDOWS
    //! @brief warning C4103: alignment changed after including header, may be due to missing #pragma pack(pop)
    #ifdef _MSC_VER
        #pragma warning(disable : 4103)
    #endif
    #pragma pack(push)
    #if SMTG_PLATFORM_64
        #pragma pack(16)
    #else
        #pragma pack(8)
    #endif
#elif SMTG_OS_LINUX
    #if SMTG_PLATFORM_64
        #pragma pack(push, 16)
    #else
        #pragma pack(push, 8)
    #endif
#endif

