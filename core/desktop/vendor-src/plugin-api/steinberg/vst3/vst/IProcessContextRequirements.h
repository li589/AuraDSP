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

#ifndef _3RD_PARTY_STEINBERG_VST3_VST_IPROCESSCONTEXTREQUIREMENTS_H_
#define _3RD_PARTY_STEINBERG_VST3_VST_IPROCESSCONTEXTREQUIREMENTS_H_

#include <steinberg/vst3/base/Types.h>
#include <steinberg/vst3/base/FUnknown.h>

//------------------------------------------------------------------------
namespace Steinberg
{
    namespace Vst
    {
        /**
         * Extended IAudioProcessor interface for a component.
         *
         * To get accurate process context information (Vst::ProcessContext), it is now required to implement
         * this interface and return the desired bit mask of flags which your audio effect needs. If you do not
         * implement this interface, you may not get any information at all of the process function.
         *
         * The host asks for this information once between initialize and setActive. It cannot be changed afterwards.
         * This gives the host the opportunity to better optimize the audio process graph when it knows which plug-ins
         * need which information.
         *
         * Plug-Ins built with an earlier SDK version (< 3.7) will still get the old information, but the information
         * may not be as accurate as when using this interface.
         */
        #include <steinberg/vst3/base/WarningsPush.h>
        class IProcessContextRequirements: public FUnknown
        {
            public:
                enum Flags
                {
                    /**
                     * kSystemTimeValid
                     */
                    kNeedSystemTime             = 1 <<  0,

                    /**
                     * kContTimeValid
                     */
                    kNeedContinousTimeSamples   = 1 <<  1,

                    /**
                     * kProjectTimeMusicValid
                     */
                    kNeedProjectTimeMusic       = 1 <<  2,

                    /**
                     * kBarPositionValid
                     */
                    kNeedBarPositionMusic       = 1 <<  3,

                    /**
                     * kCycleValid
                     */
                    kNeedCycleMusic             = 1 <<  4,

                    /**
                     * kClockValid
                     */
                    kNeedSamplesToNextClock     = 1 <<  5,

                    /**
                     * kTempoValid
                     */
                    kNeedTempo                  = 1 <<  6,

                    /**
                     * kTimeSigValid
                     */
                    kNeedTimeSignature          = 1 <<  7,

                    /**
                     * kChordValid
                     */
                    kNeedChord                  = 1 <<  8,

                    /**
                     * kSmpteValid
                     */
                    kNeedFrameRate              = 1 <<  9,

                    /**
                     * kPlaying, kCycleActive, kRecording
                     */
                    kNeedTransportState         = 1 << 10,
                };

            public:
                virtual uint32 PLUGIN_API getProcessContextRequirements() = 0;

            public:
                static const FUID iid;
        };
        #include <steinberg/vst3/base/WarningsPop.h>

    } /* namespace Vst */
} /* namespace Steinberg */

#endif /* _3RD_PARTY_STEINBERG_VST3_VST_IPROCESSCONTEXTREQUIREMENTS_H_ */
