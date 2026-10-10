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

#ifndef _3RD_PARTY_STEINBERG_VST3_VST_FUNCTIONNAMETYPE_H_
#define _3RD_PARTY_STEINBERG_VST3_VST_FUNCTIONNAMETYPE_H_

#include <steinberg/vst3/vst/Types.h>

#include <steinberg/vst3/base/AlignPush.h>

namespace Steinberg
{
    namespace Vst
    {
        namespace FunctionNameType
        {
            const CString kCompGainReduction            = "Comp:GainReduction"; /**  */
            const CString kCompGainReductionMax         = "Comp:GainReductionMax";
            const CString kCompGainReductionPeakHold    = "Comp:GainReductionPeakHold";
            const CString kCompResetGainReductionMax    = "Comp:ResetGainReductionMax";

            /**
             * Useful for live situation where low latency is required:
             * - 0 means LowLatency disable,
             * - 1 means LowLatency enable
             */
            const CString kLowLatencyMode = "LowLatencyMode";

            /** Allowing to mix the original (Dry) Signal with the processed one (Wet):
             * - 0.0 means Dry Signal only,
             * 0.5 means 50% Dry Signal + 50% Wet Signal,
             * 1.0 means Wet Signal only
             */
            const CString kDryWetMix = "DryWetMix";

            /**
             * Allow to assign some randomized values to some
             * parameters in a controlled way
             */
            const CString kRandomize = "Randomize";

            /**
             * Panner Types
             */
            const CString kPanPosCenterX = "PanPosCenterX"; ///< Gravity point X-axis [0, 1]=>[L-R] (for stereo: middle between left and right)
            const CString kPanPosCenterY = "PanPosCenterY"; ///< Gravity point Y-axis [0, 1]=>[Front-Rear]
            const CString kPanPosCenterZ = "PanPosCenterZ"; ///< Gravity point Z-axis [0, 1]=>[Bottom-Top]

        } /* namespace FunctionNameType */
    } /* namespace Vst */
} /* namespace Steinberg */

#include <steinberg/vst3/base/AlignPop.h>

#endif /* _3RD_PARTY_STEINBERG_VST3_VST_FUNCTIONNAMETYPE_H_ */
