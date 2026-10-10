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

#ifndef _3RDPARTY_STEINBERG_VST3_BASE_FTYPES_H_
#define _3RDPARTY_STEINBERG_VST3_BASE_FTYPES_H_

#include <steinberg/vst3/base/Platform.h>
#include <cstdint>

#ifdef UNICODE_OFF
    #ifdef UNICODE
    #undef UNICODE
    #endif
#else
    #define UNICODE 1
#endif /* UNICODE_OFF */

#ifdef UNICODE
    #define _UNICODE 1
#endif /* UNICODE */

namespace Steinberg
{
    // Integral Types
    typedef char int8;
    typedef uint8_t uint8;
    typedef unsigned char uchar;

    typedef int16_t int16;
    typedef uint16_t uint16;

    typedef int32_t int32;
    typedef uint32_t uint32;

    static const int32 kMaxInt32 = INT32_MAX;
    static const int32 kMinInt32 = INT32_MIN;
    static const int32 kMaxLong = kMaxInt32;
    static const int32 kMinLong = kMinInt32;
    static const uint32 kMaxInt32u = UINT32_MAX;

    typedef int64_t int64;
    typedef uint64_t uint64;
    static const int64 kMaxInt64 = INT64_MAX;
    static const int64 kMinInt64 = INT64_MIN;
    static const uint64 kMaxInt64u = UINT64_MAX;

    // other Semantic Types
    /**
     * Size type
     */
    typedef int64 TSize;

    /**
     * result code
     */
    typedef int32 tresult;


    static const float kMaxFloat = 3.40282346638528860E38;
    static const double kMaxDouble = 1.7976931348623158E308;

#if SMTG_PLATFORM_64
    typedef uint64 TPtrInt;
#else
    typedef uint32 TPtrInt;
#endif

    /**
     * Boolean type
     */
    typedef uint8 TBool;

    // Char / Strings
    typedef char char8;
    typedef char16_t char16;

#ifdef UNICODE
    typedef char16 tchar;
#else
    typedef char8 tchar;
#endif

    typedef const char8 *CStringA;
    typedef const char16 *CStringW;
    typedef const tchar *CString;
    inline bool strEmpty (const tchar* str) { return (!str || *str == 0); }
    inline bool str8Empty (const char8* str) { return (!str || *str == 0); }
    inline bool str16Empty (const char16* str) { return (!str || *str == 0); }

    /**
     * Identifier as string (used for attributes, messages)
     */
    typedef const char8* FIDString;

    const FIDString kPlatformStringWin = "WIN";
    const FIDString kPlatformStringMac = "MAC";
    const FIDString kPlatformStringIOS = "IOS";
    const FIDString kPlatformStringLinux = "Linux";
    const FIDString kPlatformStringPosix = "POSIX";
#if SMTG_OS_WINDOWS
    const FIDString kPlatformString = kPlatformStringWin;
#elif SMTG_OS_IOS
    const FIDString kPlatformString = kPlatformStringIOS;
#elif SMTG_OS_MACOS
    const FIDString kPlatformString = kPlatformStringMac;
#elif SMTG_OS_LINUX
    const FIDString kPlatformString = kPlatformStringLinux;
#elif SMTG_OS_POSIX
    const FIDString kPlatformString = kPlatformStringPosix;
#endif

    /**
     *  Coordinates
     */
    typedef int32 UCoord;
    static const UCoord kMaxCoord = ((UCoord)0x7FFFFFFF);
    static const UCoord kMinCoord = ((UCoord)-0x7FFFFFFF);
} /* namespace Steinberg */


/** Byte-order Conversion Macros 
*/
#define SWAP_32(l) \
{ \
    ::Steinberg::uint32 *pl = (::Steinberg::uint32 *) & (l); \
    ::Steinberg::uint32 v = *pl; \
    v = ((v & 0xff00ff00) >> 8) | ((v & 0x00ff00ff) << 8); \
    *pl = (v >> 16) | (v << 16); \
}

#define SWAP_16(w) \
{ \
    ::Steinberg::uint16 *pw = (::Steinberg::uint16 *) & (w); \
    ::Steinberg::uint16 v = *pw; \
    *pw = (v >> 8) | (v << 8); \
}

#define SWAP_64(i) \
{ \
    ::Steinberg::uint64 *pi = (::Steinberg::uint64 *) & (i); \
    ::Steinberg::uint64 v = *pi; \
    v = ((v & 0xff00ff00ff00ff00ULL) >> 8) | ((v & 0x00ff00ff00ff00ffULL) << 8); \
    v = ((v & 0xffff0000ffff0000ULL) >> 16) | ((v & 0x0000ffff0000ffffULL) << 16); \
    *pi = (v >> 32) | (v << 32); \
}

namespace Steinberg
{
    static inline void FSwap (int8&) {}
    static inline void FSwap (uint8&) {}
    static inline void FSwap (int16& i16) { SWAP_16 (i16) }
    static inline void FSwap (uint16& i16) { SWAP_16 (i16) }
    static inline void FSwap (int32& i32) { SWAP_32 (i32) }
    static inline void FSwap (uint32& i32) { SWAP_32 (i32) }
    static inline void FSwap (int64& i64) { SWAP_64 (i64) }
    static inline void FSwap (uint64& i64) { SWAP_64 (i64) }
}

// always inline macros (only when RELEASE is 1)
//----------------------------------------------------------------------------
#if defined(RELEASE) && RELEASE
    #if SMTG_OS_MACOS || SMTG_OS_LINUX || STMG_OS_POSIX || defined(__MINGW32__)
        #define SMTG_ALWAYS_INLINE      __inline__ __attribute__((__always_inline__))
        #define SMTG_NEVER_INLINE       __attribute__((noinline))
    #elif SMTG_OS_WINDOWS
        #define SMTG_ALWAYS_INLINE      __forceinline
        #define SMTG_NEVER_INLINE       __declspec(noinline)
    #endif
#endif

#ifndef SMTG_ALWAYS_INLINE
    #define SMTG_ALWAYS_INLINE          inline
#endif
#ifndef SMTG_NEVER_INLINE
    #define SMTG_NEVER_INLINE
#endif

#endif /* _3RDPARTY_STEINBERG_VST3_BASE_FTYPES_H_ */
