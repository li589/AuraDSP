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

#ifndef _3RD_PARTY_STEINBERG_VST3_BASE_IPLUGINCOMPATIBILITY_H_
#define _3RD_PARTY_STEINBERG_VST3_BASE_IPLUGINCOMPATIBILITY_H_

#include <steinberg/vst3/base/FUnknown.h>
#include <steinberg/vst3/base/IBStream.h>

namespace Steinberg
{
    /**
     * moduleinfo.json
     *
     * The moduleinfo.json describes the contents of the plug-in in a JSON5 compatible format (See https://json5.org/).
     * It contains the factory info (see PFactoryInfo), the contained classes (see PClassInfo), the
     * included snapshots and a list of compatibility of the included classes.
     *
     * @example moduleinfo.json:
     * {
     *     "Name": "",
     *     "Version": "1.0",
     *     "Factory Info": {
     *         "Vendor": "Steinberg Media Technologies",
     *         "URL": "http://www.steinberg.net",
     *         "E-Mail": "mailto:info@steinberg.de",
     *         "Flags": {
     *             "Unicode": true,
     *             "Classes Discardable": false,
     *             "Component Non Discardable": false,
     *         },
     *     },
     *     "Compatibility": [
     *         {
     *             "New": "B9F9ADE1CD9C4B6DA57E61E3123535FD",
     *             "Old": [
     *                 "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", // just an example
     *                 "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB", // another example
     *             ],
     *         },
     *     ],
     *     "Classes": [
     *         {
     *             "CID": "B9F9ADE1CD9C4B6DA57E61E3123535FD",
     *             "Category": "Audio Module Class",
     *             "Name": "AGainSimple VST3",
     *             "Vendor": "Steinberg Media Technologies",
     *             "Version": "1.3.0.1",
     *             "SDKVersion": "VST 3.7.4",
     *             "Sub Categories": [
     *                 "Fx",
     *             ],
     *             "Class Flags": 0,
     *             "Cardinality": 2147483647,
     *             "Snapshots": [
     *             ],
     *         },
     *     ],
     * }
     */

    #define kPluginCompatibilityClass "Plugin Compatibility Class"

    /**
     * Optional interface to query the compatibility of the plug-ins classes.
     *
     * A plug-in can add a class with this interface to its class factory if it cannot provide a
     * moduleinfo.json file in its plug-in package/bundle where the compatibility is normally part of.
     *
     * If the module contains a moduleinfo.json the host will ignore this class.
     *
     * The class must write into the stream an UTF-8 encoded json description of the compatibility of
     * the other classes in the factory.
     *
     * It is expected that the JSON5 written starts with an array:
     *
     * [
     *     {
     *         "New": "B9F9ADE1CD9C4B6DA57E61E3123535FD",
     *         "Old": [
     *             "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", // just an example
     *             "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB", // another example
     *         ],
     *     },
     * ]
     */
    #include <steinberg/vst3/base/WarningsPush.h>
    class IPluginCompatibility: public FUnknown
    {
        public:
            /**
             * Get the compatibility stream
             * @param stream the stream the plug-in must write the UTF8 encoded JSON5 compatibility string.
             * @return kResultTrue on success
             */
            virtual tresult PLUGIN_API getCompatibilityJSON(IBStream *stream) = 0;

        public:
            static const FUID iid;
    };
    #include <steinberg/vst3/base/WarningsPop.h>

} /* namespace Steinberg */


#endif /* _3RD_PARTY_STEINBERG_VST3_BASE_IPLUGINCOMPATIBILITY_H_ */
