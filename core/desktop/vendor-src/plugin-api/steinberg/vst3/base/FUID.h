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

#ifndef _3RD_PARTY_INCLUDE_STEINBERG_VST3_BASE_FUID_H_
#define _3RD_PARTY_INCLUDE_STEINBERG_VST3_BASE_FUID_H_

#include <steinberg/vst3/base/Platform.h>
#include <steinberg/vst3/base/Types.h>
#include <steinberg/vst3/base/TUID.h>
#include <cstring>

#if SMTG_CPP11_STDLIBSUPPORT
    #include <type_traits>
#endif /* SMTG_CPP11_STDLIBSUPPORT */

namespace Steinberg
{
    /**
     * Handling 16 Byte Globally Unique Identifiers.
     *
     * Each interface declares its identifier as static member inside the interface
     * namespace (e.g. FUnknown::iid).
     */
    class FUID
    {
    public:
        typedef char8 String[33];

    public:
        SMTG_ALWAYS_INLINE FUID();
        SMTG_ALWAYS_INLINE FUID(uint32 l1, uint32 l2, uint32 l3, uint32 l4);
        SMTG_ALWAYS_INLINE FUID(const FUID & src);
        template <size_t N>
        SMTG_ALWAYS_INLINE explicit FUID(const char (&uid)[N]);
    #if SMTG_CPP11_STDLIBSUPPORT
        SMTG_ALWAYS_INLINE FUID(FUID && other);
    #endif /* SMTG_CPP11_STDLIBSUPPORT */

        virtual ~FUID() {}

        SMTG_ALWAYS_INLINE FUID & operator = (const FUID & f);

    #if SMTG_CPP11_STDLIBSUPPORT
        SMTG_ALWAYS_INLINE FUID & operator = (FUID && other);
    #endif /* SMTG_CPP11_STDLIBSUPPORT */

    public:
        /**
         * Checks if the UID data is valid.
         * The default constructor initializes the memory with zeros.
         */
        SMTG_ALWAYS_INLINE bool isValid () const;

        SMTG_ALWAYS_INLINE bool operator == (const FUID & f) const;
        SMTG_ALWAYS_INLINE bool operator < (const FUID & f) const;
        SMTG_ALWAYS_INLINE bool operator != (const FUID & f) const;

        SMTG_ALWAYS_INLINE uint32 getLong1() const;
        SMTG_ALWAYS_INLINE uint32 getLong2() const;
        SMTG_ALWAYS_INLINE uint32 getLong3() const;
        SMTG_ALWAYS_INLINE uint32 getLong4() const;

        SMTG_ALWAYS_INLINE FUID & from4Int(uint32 d1, uint32 d2, uint32 d3, uint32 d4);
        SMTG_ALWAYS_INLINE void to4Int(uint32 & d1, uint32 & d2, uint32 & d3, uint32 & d4) const;

        SMTG_ALWAYS_INLINE void toTUID(TUID result) const;
        SMTG_ALWAYS_INLINE operator const TUID & () const;
        SMTG_ALWAYS_INLINE const TUID & toTUID() const;

        SMTG_ALWAYS_INLINE static FUID fromTUID(const TUID uid);

    protected:
        TUID data;
    };

    //-------------------------------------------------------------------------

    inline FUID::FUID()
    {
        memset(data, 0, sizeof(TUID));
    }

    inline FUID::FUID(uint32 l1, uint32 l2, uint32 l3, uint32 l4)
    {
        from4Int(l1, l2, l3, l4);
    }

    inline FUID::FUID(const FUID & src)
    {
        memcpy(data, src.data, sizeof(TUID));
    }

#if SMTG_CPP11_STDLIBSUPPORT
    inline FUID::FUID(FUID && other)
    {
        memcpy(data, other.data, sizeof (TUID));
    }

    inline FUID& FUID::operator=(FUID && other)
    {
        memcpy(data, other.data, sizeof(TUID));
        return *this;
    }
#endif

    inline bool FUID::isValid() const
    {
        uint32_t n = 0;
        for (uint32_t i=0; i < sizeof(TUID); ++i)
            n += uint32_t(data[i]);
        return n != 0;
    }

    inline FUID & FUID::operator = (const FUID & f)
    {
        memcpy(data, f.data, sizeof(TUID));
        return *this;
    }

    inline bool FUID::operator == (const FUID & f) const
    {
        return iidEqual(data, f.data);
    }

    inline bool FUID::operator < (const FUID & f) const
    {
        return memcmp (data, f.data, sizeof (TUID)) < 0;
    }

    inline bool FUID::operator != (const FUID & f) const
    {
        return !::Steinberg::iidEqual (data, f.data);
    }

    inline uint32 FUID::getLong1() const
    {
    #if COM_COMPATIBLE
        return makeLong(data[3], data[2], data[1], data[0]);
    #else
        return makeLong(data[0], data[1], data[2], data[3]);
    #endif /* COM_COMPATIBLE */
    }

    inline uint32 FUID::getLong2() const
    {
    #if COM_COMPATIBLE
        return makeLong(data[5], data[4], data[7], data[6]);
    #else
        return makeLong(data[4], data[5], data[6], data[7]);
    #endif /* COM_COMPATIBLE */
    }

    inline uint32 FUID::getLong3() const
    {
    #if COM_COMPATIBLE
        return makeLong(data[8], data[9], data[10], data[11]);
    #else
        return makeLong(data[8], data[9], data[10], data[11]);
    #endif /* COM_COMPATIBLE */
    }

    inline uint32 FUID::getLong4() const
    {
    #if COM_COMPATIBLE
        return makeLong(data[12], data[13], data[14], data[15]);
    #else
        return makeLong(data[12], data[13], data[14], data[15]);
    #endif /* COM_COMPATIBLE */
    }

    template <size_t N>
    SMTG_ALWAYS_INLINE FUID::FUID(const char (&uid)[N])
    {
#if SMTG_CPP11_STDLIBSUPPORT
        static_assert (N == sizeof (TUID), "only TUID allowed");
#endif /* SMTG_CPP11_STDLIBSUPPORT */
        memcpy (data, uid, sizeof (TUID));
    }

    SMTG_ALWAYS_INLINE FUID & FUID::from4Int(uint32 l1, uint32 l2, uint32 l3, uint32 l4)
    {
    #if COM_COMPATIBLE
        data [0]  = (char)((l1 & 0x000000FF)      );
        data [1]  = (char)((l1 & 0x0000FF00) >>  8);
        data [2]  = (char)((l1 & 0x00FF0000) >> 16);
        data [3]  = (char)((l1 & 0xFF000000) >> 24);
        data [4]  = (char)((l2 & 0x00FF0000) >> 16);
        data [5]  = (char)((l2 & 0xFF000000) >> 24);
        data [6]  = (char)((l2 & 0x000000FF)      );
        data [7]  = (char)((l2 & 0x0000FF00) >>  8);
        data [8]  = (char)((l3 & 0xFF000000) >> 24);
        data [9]  = (char)((l3 & 0x00FF0000) >> 16);
        data [10] = (char)((l3 & 0x0000FF00) >>  8);
        data [11] = (char)((l3 & 0x000000FF)      );
        data [12] = (char)((l4 & 0xFF000000) >> 24);
        data [13] = (char)((l4 & 0x00FF0000) >> 16);
        data [14] = (char)((l4 & 0x0000FF00) >>  8);
        data [15] = (char)((l4 & 0x000000FF)      );
    #else
        data [0]  = (char)((l1 & 0xFF000000) >> 24);
        data [1]  = (char)((l1 & 0x00FF0000) >> 16);
        data [2]  = (char)((l1 & 0x0000FF00) >>  8);
        data [3]  = (char)((l1 & 0x000000FF)      );
        data [4]  = (char)((l2 & 0xFF000000) >> 24);
        data [5]  = (char)((l2 & 0x00FF0000) >> 16);
        data [6]  = (char)((l2 & 0x0000FF00) >>  8);
        data [7]  = (char)((l2 & 0x000000FF)      );
        data [8]  = (char)((l3 & 0xFF000000) >> 24);
        data [9]  = (char)((l3 & 0x00FF0000) >> 16);
        data [10] = (char)((l3 & 0x0000FF00) >>  8);
        data [11] = (char)((l3 & 0x000000FF)      );
        data [12] = (char)((l4 & 0xFF000000) >> 24);
        data [13] = (char)((l4 & 0x00FF0000) >> 16);
        data [14] = (char)((l4 & 0x0000FF00) >>  8);
        data [15] = (char)((l4 & 0x000000FF)      );
    #endif

        return *this;
    }

    SMTG_ALWAYS_INLINE void FUID::to4Int(uint32 & d1, uint32 & d2, uint32 & d3, uint32 & d4) const
    {
        d1 = getLong1();
        d2 = getLong2();
        d3 = getLong3();
        d4 = getLong4();
    }

    SMTG_ALWAYS_INLINE void FUID::toTUID(TUID result) const
    {
        memcpy (result, data, sizeof (TUID));
    }

    SMTG_ALWAYS_INLINE FUID::operator const TUID & () const
    {
        return data;
    }

    SMTG_ALWAYS_INLINE const TUID & FUID::toTUID() const
    {
        return data;
    }

    SMTG_ALWAYS_INLINE FUID FUID::fromTUID(const TUID uid)
    {
        FUID res;
        if (uid)
            memcpy (res.data, uid, sizeof(TUID));
        return res;
    }

} /* namespace Steinberg */


#endif /* _3RD_PARTY_INCLUDE_STEINBERG_VST3_BASE_FUID_H_ */
