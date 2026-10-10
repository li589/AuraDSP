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

#ifndef _3RD_PARTY_STEINBERG_VST3_VST_ISTREAMATTRIBUTES_H_
#define _3RD_PARTY_STEINBERG_VST3_VST_ISTREAMATTRIBUTES_H_

#include <steinberg/vst3/base/Types.h>
#include <steinberg/vst3/base/FUnknown.h>
#include <steinberg/vst3/vst/Types.h>
#include <steinberg/vst3/vst/IAttributeList.h>

namespace Steinberg
{
    namespace Vst
    {
        /**
         * Meta attributes of a stream: Vst::IStreamAttributes
         *
         * Interface to access preset meta information from stream, used, for example,
         * in setState in order to inform the plug-in about the current context in which
         * the preset loading occurs (Project context or Preset load (see \ref StateType))
         * or used to get the full file path of the loaded preset (if available).
         *
         * @example
         *   //------------------------------------------------------------------------
         *   #include "pluginterfaces/base/ustring.h"
         *   #include "pluginterfaces/vst/vstpresetkeys.h"
         *   ...
         *
         *   tresult PLUGIN_API MyPlugin::setState (IBStream* state)
         *   {
         *       FUnknownPtr<IStreamAttributes> stream (state);
         *       if (stream)
         *       {
         *           IAttributeList* list = stream->getAttributes ();
         *           if (list)
         *           {
         *               // get the current type (project/Default..) of this state
         *               String128 string;
         *               if (list->getString (PresetAttributes::kStateType, string, 128 * sizeof (TChar)) == kResultTrue)
         *               {
         *                   UString128 tmp (string);
         *                   char ascii[128];
         *                   tmp.toAscii (ascii, 128);
         *                   if (strncmp (ascii, StateType::kProject, strlen (StateType::kProject)) == 0)
         *                   {
         *                       // we are in project loading context...
         *                   }
         *               }
         *
         *               // get the full file path of this state
         *               TChar fullPath[1024];
         *               if (list->getString (PresetAttributes::kFilePathStringType, fullPath, 1024 * sizeof (TChar)) == kResultTrue)
         *               {
         *                   // here we have the full path ...
         *               }
         *           }
         *       }
         *
         *       //...read the state here.....
         *       return kResultTrue;
         *   }
         */
        #include <steinberg/vst3/base/WarningsPush.h>
        class IStreamAttributes: public FUnknown
        {
            public:
                /**
                 * Gets filename (without file extension) of the stream.
                 */
                virtual tresult PLUGIN_API getFileName (String128 name) = 0;

                /**
                 * Gets meta information list.
                 */
                virtual IAttributeList* PLUGIN_API getAttributes () = 0;

            public:
                static const FUID iid;
        };
        #include <steinberg/vst3/base/WarningsPop.h>

    } /* namespace Vst */
} /* namespace Steinberg */


#endif /* _3RD_PARTY_STEINBERG_VST3_VST_ISTREAMATTRIBUTES_H_ */
