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

#ifndef _3RD_PARTY_STEINBERG_VST3_BASE_TUID_H_
#define _3RD_PARTY_STEINBERG_VST3_BASE_TUID_H_

#include <steinberg/vst3/base/Platform.h>
#include <steinberg/vst3/base/Types.h>
#include <cstring>

#if SMTG_CPP11_STDLIBSUPPORT
    #include <type_traits>
#endif /* SMTG_CPP11_STDLIBSUPPORT */

//------------------------------------------------------------------------
//  Unique Identifier macros
//------------------------------------------------------------------------

#if COM_COMPATIBLE
    #define INLINE_UID(l1, l2, l3, l4) \
    { \
        (::Steinberg::int8)(((::Steinberg::uint32)(l1) & 0x000000FF)      ), (::Steinberg::int8)(((::Steinberg::uint32)(l1) & 0x0000FF00) >>  8), \
        (::Steinberg::int8)(((::Steinberg::uint32)(l1) & 0x00FF0000) >> 16), (::Steinberg::int8)(((::Steinberg::uint32)(l1) & 0xFF000000) >> 24), \
        (::Steinberg::int8)(((::Steinberg::uint32)(l2) & 0x00FF0000) >> 16), (::Steinberg::int8)(((::Steinberg::uint32)(l2) & 0xFF000000) >> 24), \
        (::Steinberg::int8)(((::Steinberg::uint32)(l2) & 0x000000FF)      ), (::Steinberg::int8)(((::Steinberg::uint32)(l2) & 0x0000FF00) >>  8), \
        (::Steinberg::int8)(((::Steinberg::uint32)(l3) & 0xFF000000) >> 24), (::Steinberg::int8)(((::Steinberg::uint32)(l3) & 0x00FF0000) >> 16), \
        (::Steinberg::int8)(((::Steinberg::uint32)(l3) & 0x0000FF00) >>  8), (::Steinberg::int8)(((::Steinberg::uint32)(l3) & 0x000000FF)      ), \
        (::Steinberg::int8)(((::Steinberg::uint32)(l4) & 0xFF000000) >> 24), (::Steinberg::int8)(((::Steinberg::uint32)(l4) & 0x00FF0000) >> 16), \
        (::Steinberg::int8)(((::Steinberg::uint32)(l4) & 0x0000FF00) >>  8), (::Steinberg::int8)(((::Steinberg::uint32)(l4) & 0x000000FF)      )  \
    }
#else
    #define INLINE_UID(l1, l2, l3, l4) \
    { \
        (::Steinberg::int8)(((::Steinberg::uint32)(l1) & 0xFF000000) >> 24), (::Steinberg::int8)(((::Steinberg::uint32)(l1) & 0x00FF0000) >> 16), \
        (::Steinberg::int8)(((::Steinberg::uint32)(l1) & 0x0000FF00) >>  8), (::Steinberg::int8)(((::Steinberg::uint32)(l1) & 0x000000FF)      ), \
        (::Steinberg::int8)(((::Steinberg::uint32)(l2) & 0xFF000000) >> 24), (::Steinberg::int8)(((::Steinberg::uint32)(l2) & 0x00FF0000) >> 16), \
        (::Steinberg::int8)(((::Steinberg::uint32)(l2) & 0x0000FF00) >>  8), (::Steinberg::int8)(((::Steinberg::uint32)(l2) & 0x000000FF)      ), \
        (::Steinberg::int8)(((::Steinberg::uint32)(l3) & 0xFF000000) >> 24), (::Steinberg::int8)(((::Steinberg::uint32)(l3) & 0x00FF0000) >> 16), \
        (::Steinberg::int8)(((::Steinberg::uint32)(l3) & 0x0000FF00) >>  8), (::Steinberg::int8)(((::Steinberg::uint32)(l3) & 0x000000FF)      ), \
        (::Steinberg::int8)(((::Steinberg::uint32)(l4) & 0xFF000000) >> 24), (::Steinberg::int8)(((::Steinberg::uint32)(l4) & 0x00FF0000) >> 16), \
        (::Steinberg::int8)(((::Steinberg::uint32)(l4) & 0x0000FF00) >>  8), (::Steinberg::int8)(((::Steinberg::uint32)(l4) & 0x000000FF)      )  \
    }
#endif

#define DEF_CLASS_IID(ClassName, l1, l2, l3, l4) const ::Steinberg::FUID ClassName::iid(l1, l2, l3, l4);

namespace Steinberg
{

    #if COM_COMPATIBLE
        #if SMTG_OS_WINDOWS
            enum
            {
                kNoInterface        = static_cast<tresult>(0x80004002L),    // E_NOINTERFACE
                kResultOk           = static_cast<tresult>(0x00000000L),    // S_OK
                kResultTrue         = kResultOk,
                kResultFalse        = static_cast<tresult>(0x00000001L),    // S_FALSE
                kInvalidArgument    = static_cast<tresult>(0x80070057L),    // E_INVALIDARG
                kNotImplemented     = static_cast<tresult>(0x80004001L),    // E_NOTIMPL
                kInternalError      = static_cast<tresult>(0x80004005L),    // E_FAIL
                kNotInitialized     = static_cast<tresult>(0x8000FFFFL),    // E_UNEXPECTED
                kOutOfMemory        = static_cast<tresult>(0x8007000EL)     // E_OUTOFMEMORY
            };
        #else
            enum
            {
                kNoInterface        = static_cast<tresult>(0x80000004L),    // E_NOINTERFACE
                kResultOk           = static_cast<tresult>(0x00000000L),    // S_OK
                kResultTrue         = kResultOk,
                kResultFalse        = static_cast<tresult>(0x00000001L),    // S_FALSE
                kInvalidArgument    = static_cast<tresult>(0x80000003L),    // E_INVALIDARG
                kNotImplemented     = static_cast<tresult>(0x80000001L),    // E_NOTIMPL
                kInternalError      = static_cast<tresult>(0x80000008L),    // E_FAIL
                kNotInitialized     = static_cast<tresult>(0x8000FFFFL),    // E_UNEXPECTED
                kOutOfMemory        = static_cast<tresult>(0x80000002L)     // E_OUTOFMEMORY
            };
        #endif /* SMTG_OS_WINDOWS */
    #else
        enum
        {
            kNoInterface = -1,
            kResultOk,
            kResultTrue = kResultOk,
            kResultFalse,
            kInvalidArgument,
            kNotImplemented,
            kInternalError,
            kNotInitialized,
            kOutOfMemory
        };
    #endif

    /**
     * Plain UID type
     */
    typedef char TUID[16];

    SMTG_ALWAYS_INLINE bool iidEqual(const void* iid1, const void* iid2)
    {
        const uint64* p1 = reinterpret_cast<const uint64*> (iid1);
        const uint64* p2 = reinterpret_cast<const uint64*> (iid2);
        return p1[0] == p2[0] && p1[1] == p2[1];
    }

    SMTG_ALWAYS_INLINE static uint32 makeLong(uint8 b1, uint8 b2, uint8 b3, uint8 b4)
    {
        return (uint32 (b1) << 24) | (uint32 (b2) << 16) | (uint32 (b3) << 8) | uint32 (b4);
    }

} /* namespace Steinberg */




#endif /* _3RD_PARTY_STEINBERG_VST3_BASE_TUID_H_ */
