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

#ifndef _3RD_PARTY_STEINBERG_VST3_VST_IPARAMETERFUNCTIONNAME_H_
#define _3RD_PARTY_STEINBERG_VST3_VST_IPARAMETERFUNCTIONNAME_H_

#include <steinberg/vst3/base/FUnknown.h>
#include <steinberg/vst3/vst/FunctionNameType.h>

namespace Steinberg
{
    namespace Vst
    {
        /**
         * Edit controller component interface extension: Vst::IParameterFunctionName
         *
         * This interface allows the host to get a parameter associated to a specific meaning (a functionName)
         * for a given unit. The host can use this information, for example, for drawing a Gain Reduction meter
         * in its own UI. In order to get the plain value of this parameter, the host should use the
         * IEditController::normalizedParamToPlain. The host can automatically map parameters to dedicated UI
         * controls, such as the wet-dry mix knob or Randomize button.
         *
         * @example
         *
         * //------------------------------------------------------------------------
         * // here an example of how a VST3 plug-in could support this IParameterFunctionName interface.
         * // we need to define somewhere the iids:
         *
         * in MyController class declaration
         *
         * class MyController: public Vst::EditController, public Vst::IParameterFunctionName
         * {
         *     // ...
         *     tresult PLUGIN_API getParameterIDFromFunctionName(UnitID unitID, FIDString functionName,
         *                                                       Vst::ParamID& paramID) override;
         *     // ...
         *     OBJ_METHODS (MyController, Vst::EditController)
         *     DEFINE_INTERFACES
         *         // ...
         *         DEF_INTERFACE (Vst::IParameterFunctionName)
         *     END_DEFINE_INTERFACES (Vst::EditController)
         *     DELEGATE_REFCOUNT (Vst::EditController)
         *
         *     // ...
         * }
         *
         * #include "ivstparameterfunctionname.h"
         * namespace Steinberg {
         *     namespace Vst {
         *         DEF_CLASS_IID (IParameterFunctionName)
         *     }
         * }
         *
         * //------------------------------------------------------------------------
         * tresult PLUGIN_API MyController::getParameterIDFromFunctionName(UnitID unitID, FIDString
         *                                                                 functionName, Vst::ParamID & paramID)
         * {
         *     using namespace Vst;
         *
         *     paramID = kNoParamId;
         *     if (unitID == kRootUnitId && FIDStringsEqual(functionName, kCompGainReduction))
         *         paramID = kMyGainReductionId;
         *     return (paramID != kNoParamId) ? kResultOk : kResultFalse;
         * }
         *
         * //--- a host implementation example: --------------------
         * // ...
         * FUnknownPtr<Vst::IParameterFunctionName> functionName (mEditController->getIEditController ());
         * if (functionName)
         * {
         *     Vst::ParamID paramID;
         *     if (functionName->getParameterIDFromFunctionName(kRootUnitId,
         *                                                      Vst::FunctionNameType::kCompGainReduction, paramID) == kResultTrue)
         *     {
         *         // paramID could be cached for performance issue
         *         ParamValue norm = mEditController->getIEditController ()->getParamNormalized (paramID);
         *         ParamValue plain = mEditController->getIEditController ()->normalizedParamToPlain (paramID, norm);
         *         // plain is something like -6 (-6dB)
         *     }
         * }
         */
        #include <steinberg/vst3/base/WarningsPush.h>
        class IParameterFunctionName: public FUnknown
        {
            public:
                /**
                 * Gets for the given unitID the associated paramID to a function Name.
                 * Returns kResultFalse when no found parameter (paramID is set to kNoParamId in this case).
                 */
                virtual tresult PLUGIN_API getParameterIDFromFunctionName(UnitID unitID, FIDString functionName, ParamID & paramID) = 0;

            public:
                static const FUID iid;
        };
        #include <steinberg/vst3/base/WarningsPop.h>

    } /* namespace Vst */
} /* namespace Steinberg */


#endif /* _3RD_PARTY_STEINBERG_VST3_VST_IPARAMETERFUNCTIONNAME_H_ */
