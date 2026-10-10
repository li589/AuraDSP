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

#ifndef _3RD_PARTY_STEINBERG_VST3_VST_IEDITCONTROLLER_H_
#define _3RD_PARTY_STEINBERG_VST3_VST_IEDITCONTROLLER_H_

#include <steinberg/vst3/base/IBStream.h>
#include <steinberg/vst3/base/IPluginBase.h>
#include <steinberg/vst3/vst/Types.h>
#include <steinberg/vst3/vst/ParameterInfo.h>
#include <steinberg/vst3/gui/IPlugView.h>
#include <steinberg/vst3/base/AlignPush.h>

/**
 * Class Category Name for Controller Component
 */
#ifndef kVstComponentControllerClass
#define kVstComponentControllerClass "Component Controller Class"
#endif

namespace Steinberg
{
    namespace Vst
    {
        /**
         * Edit controller component interface
         *
         * The controller part of an effect or instrument with parameter handling (export, definition, conversion...).
         * @see @ref IComponent::getControllerClassId, @ref IMidiMapping
         */
        #include <steinberg/vst3/base/WarningsPush.h>
        class IEditController: public IPluginBase
        {
            public:
                /**
                 * Receives the component state.
                 */
                virtual tresult PLUGIN_API setComponentState(IBStream *state) = 0;

                /**
                 * Sets the controller state.
                 */
                virtual tresult PLUGIN_API setState(IBStream *state) = 0;

                /**
                 * Gets the controller state.
                 */
                virtual tresult PLUGIN_API getState(IBStream *state) = 0;

                /**
                 * Returns the number of parameters exported.
                 */
                virtual int32 PLUGIN_API getParameterCount() = 0;

                /**
                 * Gets for a given index the parameter information.
                 */
                virtual tresult PLUGIN_API getParameterInfo(int32 paramIndex, ParameterInfo & info /*out*/) = 0;

                /**
                 * Gets for a given paramID and normalized value its associated string representation.
                 */
                virtual tresult PLUGIN_API getParamStringByValue(ParamID id, ParamValue valueNormalized /*in*/, String128 string /*out*/) = 0;

                /**
                 * Gets for a given paramID and string its normalized value.
                 */
                virtual tresult PLUGIN_API getParamValueByString(ParamID id, TChar* string /*in*/, ParamValue& valueNormalized /*out*/) = 0;

                /**
                 * Returns for a given paramID and a normalized value its plain representation
                 * (for example -6 for -6dB - see \ref vst3AutomationIntro).
                 */
                virtual ParamValue PLUGIN_API normalizedParamToPlain(ParamID id, ParamValue valueNormalized) = 0;

                /**
                 * Returns for a given paramID and a plain value its normalized value. (see @ref vst3AutomationIntro)
                 */
                virtual ParamValue PLUGIN_API plainParamToNormalized(ParamID id, ParamValue plainValue) = 0;

                /**
                 * Returns the normalized value of the parameter associated to the paramID.
                 */
                virtual ParamValue PLUGIN_API getParamNormalized(ParamID id) = 0;

                /**
                 * Sets the normalized value to the parameter associated to the paramID. The controller must never
                 * pass this value-change back to the host via the IComponentHandler. It should update the according
                 * GUI element(s) only!
                 */
                virtual tresult PLUGIN_API setParamNormalized(ParamID id, ParamValue value) = 0;

                /**
                 * Gets from host a handler which allows the Plugin-in to communicate with the host.
                 * Note: This is mandatory if the host is using the IEditController!
                 */
                virtual tresult PLUGIN_API setComponentHandler(IComponentHandler *handler) = 0;

                /**
                 * Creates the editor view of the plug-in, currently only "editor" is supported, see @ref ViewType.
                 * The life time of the editor view will never exceed the life time of this controller instance.
                 */
                virtual IPlugView* PLUGIN_API createView(FIDString name) = 0;

            public:
                static const FUID iid;
        };
        #include <steinberg/vst3/base/WarningsPop.h>

    } /* namespace Vst */
} /* namespace Steinberg */

#include <steinberg/vst3/base/AlignPop.h>

#endif /* _3RD_PARTY_STEINBERG_VST3_VST_IEDITCONTROLLER_H_ */
