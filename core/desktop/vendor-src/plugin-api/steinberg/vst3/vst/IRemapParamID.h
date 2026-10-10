/*
 * Copyright 2024, Steinberg Media Technologies GmbH, All Rights Reserved
 * Copyright 2024 Linux Studio Plugins Project <lsp.plugin@gmail.com>
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

#ifndef _3RD_PARTY_STEINBERG_VST3_VST_IREMAPPARAMID_H_
#define _3RD_PARTY_STEINBERG_VST3_VST_IREMAPPARAMID_H_

#include <steinberg/vst3/base/FUnknown.h>
#include <steinberg/vst3/vst/ParameterInfo.h>
#include <steinberg/vst3/base/AlignPush.h>

namespace Steinberg
{
    namespace Vst
    {
        /**
         * Extended IEditController interface for a component (SDK 3.7.11)
         *
         * When replacing one plug-in with another, the host can ask the new plug-in for remapping paramIDs to new ones.
         *
         * @see Moduleinfo
         * @see @ref IPluginCompatibility
         * @see IEditController
         */
        #include <steinberg/vst3/base/WarningsPush.h>
        class IRemapParamID : public FUnknown
        {
            public:
                /**
                 * Retrieve the appropriate paramID for a specific plug-in UID and paramID (or index for VST 2
                 * plug-ins).
                 * The retrieved paramID should match the one it replaces, maintaining the same
                 * behavior during automation playback. Called in UI-Thread context.
                 * @param[in] pluginToReplaceUID - TUID of plug-in (processor) that will be replaced
                 * @param[in] oldParamID - paramID (or index for VST 2 plug-ins) to be replaced
                 * @param[out] newParamID - contains the associated paramID to be used
                 *
                 * @return kResultTrue if a compatible parameter is available (newParamID has the appropriate
                 * value, it could be the same than oldParamID), or kResultFalse if no compatible parameter is
                 * available (newParamID is undefined)
                 */
                virtual tresult PLUGIN_API getCompatibleParamID(
                    const TUID pluginToReplaceUID /*in*/,
                    ParamID oldParamID /*in*/,
                    ParamID & newParamID /*out*/) = 0;
            public:
                static const FUID iid;
        };
        #include <steinberg/vst3/base/WarningsPop.h>

    } // namespace Vst
} // namespace Steinberg

#include <steinberg/vst3/base/AlignPop.h>

#endif /* _3RD_PARTY_STEINBERG_VST3_VST_IREMAPPARAMID_H_ */

