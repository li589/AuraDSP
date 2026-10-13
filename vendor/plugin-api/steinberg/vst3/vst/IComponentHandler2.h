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

#ifndef _3RD_PARTY_STEINBERG_VST3_VST_ICOMPONENTHANDLER2_H_
#define _3RD_PARTY_STEINBERG_VST3_VST_ICOMPONENTHANDLER2_H_

#include <steinberg/vst3/base/FUnknown.h>
#include <steinberg/vst3/vst/Types.h>

namespace Steinberg
{
    namespace Vst
    {
        /**
         * Extended host callback interface for an edit controller
         *
         * One part handles:
         *   - Setting dirty state of the plug-in
         *   - Requesting the host to open the editor
         *
         * The other part handles parameter group editing from the plug-in UI. It wraps a set of
         * @ref IComponentHandler::beginEdit / @ref Steinberg::Vst::IComponentHandler::performEdit /
         * @ref Steinberg::Vst::IComponentHandler::endEdit functions (see @ref IComponentHandler)
         * which should use the same timestamp in the host when writing automation. This allows for
         * better synchronizing of multiple parameter changes at once.
         *
         * @example of different use cases
         *   //--------------------------------------
         *   // we are in the editcontroller...
         *   // in case of multiple switch buttons (with associated ParamID 1 and 3)
         *   // on mouse down :
         *   hostHandler2->startGroupEdit();
         *   hostHandler->beginEdit(1);
         *   hostHandler->beginEdit(3);
         *   hostHandler->performEdit(1, 1.0);
         *   hostHandler->performEdit(3, 0.0); // the opposite of paramID 1 for example
         *   ....
         *   // on mouse up :
         *   hostHandler->endEdit(1);
         *   hostHandler->endEdit(3);
         *   hostHandler2->finishGroupEdit();
         *   ....
         *   ....
         *
         *   //--------------------------------------
         *   // in case of multiple faders (with associated ParamID 1 and 3)
         *   // on mouse down :
         *   hostHandler2->startGroupEdit();
         *   hostHandler->beginEdit(1);
         *   hostHandler->beginEdit(3);
         *   hostHandler2->finishGroupEdit();
         *   ....
         *   // on mouse move :
         *   hostHandler2->startGroupEdit ();
         *   hostHandler->performEdit (1, x); // x the wanted value
         *   hostHandler->performEdit (3, x);
         *   hostHandler2->finishGroupEdit ();
         *   ....
         *   // on mouse up :
         *   hostHandler2->startGroupEdit ();
         *   hostHandler->endEdit (1);
         *   hostHandler->endEdit (3);
         *   hostHandler2->finishGroupEdit ();
         *
         *   @see @ref IComponentHandler, @ref IEditController
         */
        #include <steinberg/vst3/base/WarningsPush.h>
        class IComponentHandler2: public FUnknown
        {
            public:
                /**
                 * Tells host that the plug-in is dirty (something besides parameters has changed since last save),
                 * if true the host should apply a save before quitting.
                 */
                virtual tresult PLUGIN_API setDirty(TBool state) = 0;

                /**
                 * Tells host that it should open the plug-in editor the next time it's possible.
                 * You should use this instead of showing an alert and blocking the program flow (especially on loading projects).
                 */
                virtual tresult PLUGIN_API requestOpenEditor(FIDString name = ViewType::kEditor) = 0;

                /**
                 * Starts the group editing (call before a \ref IComponentHandler::beginEdit),
                 * the host will keep the current timestamp at this call and will use it for all
                 * @ref IComponentHandler::beginEdit / @ref IComponentHandler::performEdit /
                 * @ref IComponentHandler::endEdit calls until a @ref finishGroupEdit().
                 */
                virtual tresult PLUGIN_API startGroupEdit() = 0;

                /**
                 * Finishes the group editing started by a @ref startGroupEdit (call after a @ref IComponentHandler::endEdit).
                 */
                virtual tresult PLUGIN_API finishGroupEdit() = 0;

            public:
                static const FUID iid;
        };
        #include <steinberg/vst3/base/WarningsPop.h>

    } /* namespace Vst */
} /* namespace Steinberg */

#endif /* _3RD_PARTY_STEINBERG_VST3_VST_ICOMPONENTHANDLER2_H_ */
