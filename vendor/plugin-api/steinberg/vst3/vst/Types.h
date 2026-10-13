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

#ifndef _3RD_PARTY_STEINBERG_VST3_VST_TYPES_H_
#define _3RD_PARTY_STEINBERG_VST3_VST_TYPES_H_

#include <steinberg/vst3/version.h>
#include <steinberg/vst3/base/Types.h>

namespace Steinberg
{
    namespace Vst
    {
    //------------------------------------------------------------------------
    /** VST 3 SDK Version */
    #ifndef kVstVersionString
        /**
         * SDK version for PClassInfo2
         */
        #define kVstVersionString   VST3_SDK_VERSION
    #endif

    #define kVstVersionMajor    VST3_VERSION_MAJOR
    #define kVstVersionMinor    VST3_VERSION_MINOR
    #define kVstVersionSub      VST3_VERSION_MICRO

    #define VST_VERSION         ((kVstVersionMajor << 16) | (kVstVersionMinor << 8) | kVstVersionSub)

    // Versions History which allows to write such code:
    // #if VST_VERSION >= VST_3_6_5_VERSION
    #define VST_3_8_0_VERSION   0x030800
    #define VST_3_7_14_VERSION  0x03070E
    #define VST_3_7_13_VERSION  0x03070D
    #define VST_3_7_12_VERSION  0x03070C
    #define VST_3_7_11_VERSION  0x03070B
    #define VST_3_7_10_VERSION  0x03070A
    #define VST_3_7_9_VERSION   0x030709
    #define VST_3_7_8_VERSION   0x030708
    #define VST_3_7_7_VERSION   0x030707
    #define VST_3_7_6_VERSION   0x030706
    #define VST_3_7_5_VERSION   0x030705
    #define VST_3_7_4_VERSION   0x030704
    #define VST_3_7_3_VERSION   0x030703
    #define VST_3_7_2_VERSION   0x030702
    #define VST_3_7_1_VERSION   0x030701
    #define VST_3_7_0_VERSION   0x030700
    #define VST_3_6_14_VERSION  0x03060E
    #define VST_3_6_13_VERSION  0x03060D
    #define VST_3_6_12_VERSION  0x03060C
    #define VST_3_6_11_VERSION  0x03060B
    #define VST_3_6_10_VERSION  0x03060A
    #define VST_3_6_9_VERSION   0x030609
    #define VST_3_6_8_VERSION   0x030608
    #define VST_3_6_7_VERSION   0x030607
    #define VST_3_6_6_VERSION   0x030606
    #define VST_3_6_5_VERSION   0x030605
    #define VST_3_6_0_VERSION   0x030600
    #define VST_3_5_0_VERSION   0x030500
    #define VST_3_1_0_VERSION   0x030100
    #define VST_3_0_0_VERSION   0x030000

        /** VST3 Data Types */
        typedef char16 TChar;           ///< UTF-16 character
        typedef TChar String128[128];   ///< 128 character UTF-16 string
        typedef const char8* CString;   ///< C-String

        typedef int32 MediaType;        ///< media type (audio/event)
        typedef int32 BusDirection;     ///< bus direction (in/out)
        typedef int32 BusType;          ///< bus type (main/aux)
        typedef int32 IoMode;           ///< I/O mode (see @ref vst3IoMode)
        typedef int32 UnitID;           ///< unit identifier
        typedef double ParamValue;      ///< parameter value type
        typedef uint32 ParamID;         ///< parameter identifier: value in range [0, 0x7FFFFFFF].
                                        ///  The range [0x80000000, 0xFFFFFFFF], is reserved for host application.
        typedef int32 ProgramListID;    ///< program list identifier
        typedef int16 CtrlNumber;       ///< MIDI controller number (see \ref ControllerNumbers for allowed values)

        typedef double TQuarterNotes;   ///< time expressed in quarter notes
        typedef int64 TSamples;         ///< time expressed in audio samples

        typedef uint32 ColorSpec;       ///< color defining by 4 component ARGB value (Alpha/Red/Green/Blue)

        static SMTG_CONSTEXPR const ParamID kNoParamId = 0xffffffff;   ///< default for uninitialized parameter ID
        static SMTG_CONSTEXPR const ParamID kMinParamId = 0;           ///< value min for a parameter ID
        static SMTG_CONSTEXPR const ParamID kMaxParamId = 0x7fffffff;  ///< value max for a parameter ID

        typedef float Sample32;             ///< 32-bit precision audio sample
        typedef double Sample64;            ///< 64-bit precision audio sample
        typedef double SampleRate;          ///< sample rate

        typedef uint64 SpeakerArrangement;  ///< Bitset of speakers
        typedef uint64 Speaker;             ///< Bit for one speaker

        static SMTG_CONSTEXPR const FIDString SDKVersionString = kVstVersionString;

        static SMTG_CONSTEXPR const uint32 SDKVersionMajor = kVstVersionMajor;
        static SMTG_CONSTEXPR const uint32 SDKVersionMinor = kVstVersionMinor;
        static SMTG_CONSTEXPR const uint32 SDKVersionSub   = kVstVersionSub;

        static SMTG_CONSTEXPR const uint32 SDKVersion =
            ((SDKVersionMajor << 16) | (SDKVersionMinor << 8) | SDKVersionSub);

        // Versions History which allows to write such code:
        // if constexpr (SDKVersion >= SDKVersion_3_8_0) { ... }
        static SMTG_CONSTEXPR const uint32 SDKVersion_3_8_0     = VST_3_8_0_VERSION;
        static SMTG_CONSTEXPR const uint32 SDKVersion_3_7_14    = VST_3_7_14_VERSION;
        static SMTG_CONSTEXPR const uint32 SDKVersion_3_7_13    = VST_3_7_13_VERSION;
        static SMTG_CONSTEXPR const uint32 SDKVersion_3_7_12    = VST_3_7_12_VERSION;
        static SMTG_CONSTEXPR const uint32 SDKVersion_3_7_11    = VST_3_7_11_VERSION;
        static SMTG_CONSTEXPR const uint32 SDKVersion_3_7_10    = VST_3_7_10_VERSION;
        static SMTG_CONSTEXPR const uint32 SDKVersion_3_7_9     = VST_3_7_9_VERSION;
        static SMTG_CONSTEXPR const uint32 SDKVersion_3_7_8     = VST_3_7_8_VERSION;
        static SMTG_CONSTEXPR const uint32 SDKVersion_3_7_7     = VST_3_7_7_VERSION;
        static SMTG_CONSTEXPR const uint32 SDKVersion_3_7_6     = VST_3_7_6_VERSION;
        static SMTG_CONSTEXPR const uint32 SDKVersion_3_7_5     = VST_3_7_5_VERSION;
        static SMTG_CONSTEXPR const uint32 SDKVersion_3_7_4     = VST_3_7_4_VERSION;
        static SMTG_CONSTEXPR const uint32 SDKVersion_3_7_3     = VST_3_7_3_VERSION;
        static SMTG_CONSTEXPR const uint32 SDKVersion_3_7_2     = VST_3_7_2_VERSION;
        static SMTG_CONSTEXPR const uint32 SDKVersion_3_7_1     = VST_3_7_1_VERSION;
        static SMTG_CONSTEXPR const uint32 SDKVersion_3_7_0     = VST_3_7_0_VERSION;
        static SMTG_CONSTEXPR const uint32 SDKVersion_3_6_14    = VST_3_6_14_VERSION;
        static SMTG_CONSTEXPR const uint32 SDKVersion_3_6_13    = VST_3_6_13_VERSION;
        static SMTG_CONSTEXPR const uint32 SDKVersion_3_6_12    = VST_3_6_12_VERSION;
        static SMTG_CONSTEXPR const uint32 SDKVersion_3_6_11    = VST_3_6_11_VERSION;
        static SMTG_CONSTEXPR const uint32 SDKVersion_3_6_10    = VST_3_6_10_VERSION;
        static SMTG_CONSTEXPR const uint32 SDKVersion_3_6_9     = VST_3_6_9_VERSION;
        static SMTG_CONSTEXPR const uint32 SDKVersion_3_6_8     = VST_3_6_8_VERSION;
        static SMTG_CONSTEXPR const uint32 SDKVersion_3_6_7     = VST_3_6_7_VERSION;
        static SMTG_CONSTEXPR const uint32 SDKVersion_3_6_6     = VST_3_6_6_VERSION;
        static SMTG_CONSTEXPR const uint32 SDKVersion_3_6_5     = VST_3_6_5_VERSION;
        static SMTG_CONSTEXPR const uint32 SDKVersion_3_6_0     = VST_3_6_0_VERSION;
        static SMTG_CONSTEXPR const uint32 SDKVersion_3_5_0     = VST_3_5_0_VERSION;
        static SMTG_CONSTEXPR const uint32 SDKVersion_3_1_0     = VST_3_1_0_VERSION;
        static SMTG_CONSTEXPR const uint32 SDKVersion_3_0_0     = VST_3_0_0_VERSION;

    } /* namespace Vst */
} /* namespace Steinberg */



#endif /* _3RD_PARTY_STEINBERG_VST3_VST_TYPES_H_ */
