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

#ifndef _3RD_PARTY_STEINBERG_VST3_VST_IPARAMVALUEQUEUE_H_
#define _3RD_PARTY_STEINBERG_VST3_VST_IPARAMVALUEQUEUE_H_

#include <steinberg/vst3/base/FUnknown.h>
#include <steinberg/vst3/vst/Types.h>

namespace Steinberg
{
    namespace Vst
    {
        /**
         * Queue of changes for a specific parameter: Vst::IParamValueQueue
         *
         * The change queue can be interpreted as segment of an automation curve. For each
         * processing block, a segment with the size of the block is transmitted to the processor.
         * The curve is expressed as sampling points of a linear approximation of
         * the original automation curve. If the original already is a linear curve, it can
         * be transmitted precisely. A non-linear curve has to be converted to a linear
         * approximation by the host. Every point of the value queue defines a linear
         * section of the curve as a straight line from the previous point of a block to
         * the new one. So the plug-in can calculate the value of the curve for any sample
         * position in the block.
         *
         * Implicit Points:
         * In each processing block, the section of the curve for each parameter is transmitted.
         * In order to reduce the amount of points, the point at block position 0 can be omitted.
         *   - If the curve has a slope of 0 over a period of multiple blocks, only one point is
         *     transmitted for the block where the constant curve section starts. The queue for the following
         *     blocks will be empty as long as the curve slope is 0.
         *   - If the curve has a constant slope other than 0 over the period of several blocks, only
         *     the value for the last sample of the block is transmitted. In this case, the last valid point
         *     is at block position -1. The processor can calculate the value for each sample in the block
         *     by using a linear interpolation:
         *
         *       double x1 = -1; // position of last point related to current buffer
         *       double y1 = currentParameterValue; // last transmitted value
         *
         *       int32 pointTime = 0;
         *       ParamValue pointValue = 0;
         *       IParamValueQueue::getPoint (0, pointTime, pointValue);
         *
         *       double x2 = pointTime;
         *       double y2 = pointValue;
         *       double slope = (y2 - y1) / (x2 - x1);
         *       double offset = y1 - (slope * x1);
         *       double curveValue = (slope * bufferTime) + offset; // bufferTime is any position in buffer
         *
         * Jumps:  A jump in the automation curve has to be transmitted as two points: one with the
         * old value and one with the new value at the next sample position.
         *
         * @see @ref IParameterChanges, @ref ProcessData
         */
        #include <steinberg/vst3/base/WarningsPush.h>
        class IParamValueQueue : public FUnknown
        {
            public:
                /**
                 * Returns its associated ID.
                 */
                virtual ParamID PLUGIN_API getParameterId () = 0;

                /**
                 * Returns count of points in the queue.
                 */
                virtual int32 PLUGIN_API getPointCount () = 0;

                /**
                 * Gets the value and offset at a given index.
                 */
                virtual tresult PLUGIN_API getPoint (int32 index, int32 & sampleOffset /*out*/, ParamValue & value /*out*/) = 0;

                /**
                 * Adds a new value at the end of the queue, its index is returned.
                 */
                virtual tresult PLUGIN_API addPoint (int32 sampleOffset, ParamValue value, int32 & index /*out*/) = 0;

                static const FUID iid;
        };
        #include <steinberg/vst3/base/WarningsPop.h>

    } /* namespace Vst */
} /* namespace Steinberg */

#endif /* _3RD_PARTY_STEINBERG_VST3_VST_IPARAMVALUEQUEUE_H_ */
