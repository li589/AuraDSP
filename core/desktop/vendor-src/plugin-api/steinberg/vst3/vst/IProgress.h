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

#ifndef _3RD_PARTY_STEINBERG_VST3_VST_IPROGRESS_H_
#define _3RD_PARTY_STEINBERG_VST3_VST_IPROGRESS_H_

#include <steinberg/vst3/base/FUnknown.h>
#include <steinberg/vst3/vst/Types.h>

namespace Steinberg
{
    namespace Vst
    {
        /**
         * Extended host callback interface for an edit controller
         *
         * Allows the plug-in to request the host to create a progress for some specific tasks which take
         * some time. The host can visualize the progress as read-only UI elements. For example,
         * after loading a project where a plug-in needs to load extra
         * data (e.g. samples) in a background thread, this enables the host to get and visualize the current status of the loading
         * progress and to inform the user when the loading is finished.
         *
         * @note During the progress, the host can unload the plug-in at any time. Make sure that the plug-in
         * supports this use case.
         *
         * @example
         *   //--------------------------------------
         *   // we are in the editcontroller:
         *   // as member: IProgress::ID mProgressID;
         *
         *   FUnknownPtr<IProgress> progress (componentHandler);
         *   if (progress)
         *       progress->start (IProgress::ProgressType::UIBackgroundTask, STR ("Load Samples..."), mProgressID);
         *   // ...
         *   myProgressValue += incProgressStep;
         *   FUnknownPtr<IProgress> progress (componentHandler);
         *   if (progress)
         *       progress->update (mProgressID, myProgressValue);
         *   // ...
         *   FUnknownPtr<IProgress> progress (componentHandler);
         *   if (progress)
         *       progress->finish (mProgressID);
         *
         * @see @ref IComponentHandler
         */
        #include <steinberg/vst3/base/WarningsPush.h>
        class IProgress: public FUnknown
        {
            public:
                enum ProgressType: uint32
                {
                    /**
                     * plug-in state is restored async (in a background Thread)
                     */
                    AsyncStateRestoration = 0,

                    /**
                     * a plug-in task triggered by a UI action
                     */
                    UIBackgroundTask
                };

                typedef uint64 ID;

            public:
                /**
                 * Start a new progress of a given type and optional Description. outID is as ID created by the
                 * host to identify this newly created progress (for update and finish method)
                 */
                virtual tresult PLUGIN_API start(ProgressType type, const tchar *optionalDescription, ID & outID) = 0;

                /**
                 * Update the progress value (normValue between [0, 1]) associated to the given id
                 */
                virtual tresult PLUGIN_API update(ID id, ParamValue normValue) = 0;

                /**
                 * Finish the progress associated to the given id
                 */
                virtual tresult PLUGIN_API finish(ID id) = 0;

            public:
                static const FUID iid;
        };
        #include <steinberg/vst3/base/WarningsPop.h>

    } /* namespace Vst */
} /* namespace Steinberg */

#endif /* _3RD_PARTY_STEINBERG_VST3_VST_IPROGRESS_H_ */
