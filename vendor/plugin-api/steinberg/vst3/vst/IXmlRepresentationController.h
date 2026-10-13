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

#ifndef _3RD_PARTY_STEINBERG_VST3_VST_IXMLREPRESENTATIONCONTROLLER_H_
#define _3RD_PARTY_STEINBERG_VST3_VST_IXMLREPRESENTATIONCONTROLLER_H_

#include <steinberg/vst3/base/FUnknown.h>
#include <steinberg/vst3/base/IBStream.h>
#include <steinberg/vst3/vst/RepresentationInfo.h>

namespace Steinberg
{
    namespace Vst
    {
        /**
         * A representation based on XML is a way to export, structure, and group plug-ins parameters
         * for a specific remote (hardware or software rack (such as quick controls)).
         *
         * It allows to describe each parameter more precisely (what is the best matching to a knob,
         * different title lengths matching limited remote display,...). See an @ref Example.
         *   - A representation is composed of pages (this means that to see all exported parameters, the user
         *     has to navigate through the pages).
         *   - A page is composed of cells (for example 8 cells per page).
         *   - A cell is composed of layers (for example a cell could have a knob, a display, and a button,
         *     which means 3 layers).
         *   - A layer is associated to a plug-in parameter using the ParameterID as identifier:
         *     - it could be a knob with a display for title and/or value, this display uses the same parameterId,
         *       but it could an another one.
         *     - switch
         *     - link which allows to jump directly to a subpage (another page)
         *     - more... See Vst::LayerType
         *
         * This representation is implemented as XML text following the Document Type Definition (DTD):
         * http://dtd.steinberg.net/VST-Remote-1.1.dtd
         *
         * @example
         *
         * Here an example of what should be passed in the stream of getXmlRepresentationStream:
         *
         * <?xml version="1.0" encoding="utf-8"?>
         * <!DOCTYPE vstXML PUBLIC "-//Steinberg//DTD VST Remote 1.1//EN" "http://dtd.steinberg.net/VST-Remote-1.1.dtd">
         * <vstXML version="1.0">
         *     <plugin classID="341FC5898AAA46A7A506BC0799E882AE" name="Chorus" vendor="Steinberg Media Technologies" />
         *     <originator>My name</originator>
         *     <date>2010-12-31</date>
         *     <comment>
         *         This is an example for 4 Cells per Page for the Remote named ProductRemote
         *         from company HardwareCompany.
         *     </comment>
         *
         *     <!-- ===================================== -->
         *     <representation name="ProductRemote" vendor="HardwareCompany" version="1.0">
         *         <page name="Root">
         *             <cell>
         *                 <layer type="knob" parameterID="0">
         *                     <titleDisplay>
         *                         <name>Mix dry/wet</name>
         *                         <name>Mix</name>
         *                     </titleDisplay>
         *                 </layer>
         *             </cell>
         *             <cell>
         *                 <layer type="display"></layer>
         *             </cell>
         *             <cell>
         *                 <layer type="knob" parameterID="3">
         *                     <titleDisplay>
         *                         <name>Delay</name>
         *                         <name>Dly</name>
         *                     </titleDisplay>
         *                 </layer>
         *             </cell>
         *             <cell>
         *                 <layer type="knob" parameterID="15">
         *                     <titleDisplay>
         *                         <name>Spatial</name>
         *                         <name>Spat</name>
         *                     </titleDisplay>
         *                 </layer>
         *             </cell>
         *         </page>
         *         <page name="Page 2">
         *             <cell>
         *                 <layer type="LED" ledStyle="spread" parameterID="2">
         *                     <titleDisplay>
         *                         <name>Width +</name>
         *                         <name>Widt</name>
         *                     </titleDisplay>
         *                 </layer>
         *                 <!--this is the switch for shape A/B-->
         *                 <layer type="switch" switchStyle="pushIncLooped" parameterID="4"></layer>
         *             </cell>
         *             <cell>
         *                 <layer type="display"></layer>
         *             </cell>
         *             <cell>
         *                 <layer type="LED" ledStyle="singleDot" parameterID="17">
         *                     <titleDisplay>
         *                         <name>Sync Note +</name>
         *                         <name>Note</name>
         *                     </titleDisplay>
         *                 </layer>
         *                 <!--this is the switch for sync to tempo on /off-->
         *                 <layer type="switch" switchStyle="pushIncLooped" parameterID="16"></layer>
         *             </cell>
         *             <cell>
         *                 <layer type="knob" parameterID="1">
         *                     <titleDisplay>
         *                         <name>Rate</name>
         *                     </titleDisplay>
         *                 </layer>
         *             </cell>
         *         </page>
         *     </representation>
         * </vstXML>
         */
        #include <steinberg/vst3/base/WarningsPush.h>
        class IXmlRepresentationController: public FUnknown
        {
            public:
                /**
                 * Retrieves a stream containing a XmlRepresentation for a wanted representation info
                 */
                virtual tresult PLUGIN_API getXmlRepresentationStream(RepresentationInfo & info /*in*/, IBStream *stream /*out*/) = 0;

            public:
                static const FUID iid;
        };
        #include <steinberg/vst3/base/WarningsPop.h>

    } /* namespace Vst */
} /* namespace Steinberg */

#endif /* _3RD_PARTY_STEINBERG_VST3_VST_IXMLREPRESENTATIONCONTROLLER_H_ */
