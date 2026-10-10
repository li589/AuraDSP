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

#ifndef _3RD_PARTY_STEINBERG_VST3_VST_REPRESENTATIONINFO_H_
#define _3RD_PARTY_STEINBERG_VST3_VST_REPRESENTATIONINFO_H_

#include <steinberg/vst3/base/AlignPush.h>

namespace Steinberg
{
    namespace Vst
    {
        /**
         * RepresentationInfo is the structure describing a representation
         * This structure is used in the function \see IXmlRepresentationController::getXmlRepresentationStream.
         * @see IXmlRepresentationController
         */
        struct RepresentationInfo
        {
            enum
            {
                kNameSize = 64
            };
            char8 vendor[kNameSize];    ///< Vendor name of the associated representation (remote) (eg. "Yamaha").
            char8 name[kNameSize];      ///< Representation (remote) Name (eg. "O2").
            char8 version[kNameSize];   ///< Version of this "Remote" (eg. "1.0").
            char8 host[kNameSize];      ///< Optional: used if the representation is for a given host only (eg. "Nuendo").
        };

        /**
         * Defines for XML representation Tags and Attributes
         */
        #define ROOTXML_TAG         "vstXML"

        #define COMMENT_TAG         "comment"
        #define CELL_TAG            "cell"
        #define CELLGROUP_TAG       "cellGroup"
        #define CELLGROUPTEMPLATE_TAG   "cellGroupTemplate"
        #define CURVE_TAG           "curve"
        #define CURVETEMPLATE_TAG   "curveTemplate"
        #define DATE_TAG            "date"
        #define LAYER_TAG           "layer"
        #define NAME_TAG            "name"
        #define ORIGINATOR_TAG      "originator"
        #define PAGE_TAG            "page"
        #define PAGETEMPLATE_TAG    "pageTemplate"
        #define PLUGIN_TAG          "plugin"
        #define VALUE_TAG           "value"
        #define VALUEDISPLAY_TAG    "valueDisplay"
        #define VALUELIST_TAG       "valueList"
        #define REPRESENTATION_TAG  "representation"
        #define SEGMENT_TAG         "segment"
        #define SEGMENTLIST_TAG     "segmentList"
        #define TITLEDISPLAY_TAG    "titleDisplay"

        #define ATTR_CATEGORY       "category"
        #define ATTR_CLASSID        "classID"
        #define ATTR_ENDPOINT       "endPoint"
        #define ATTR_INDEX          "index"
        #define ATTR_FLAGS          "flags"
        #define ATTR_FUNCTION       "function"
        #define ATTR_HOST           "host"
        #define ATTR_LEDSTYLE       "ledStyle"
        #define ATTR_LENGTH         "length"
        #define ATTR_LINKEDTO       "linkedTo"
        #define ATTR_NAME           "name"
        #define ATTR_ORDER          "order"
        #define ATTR_PAGE           "page"
        #define ATTR_PARAMID        "parameterID"
        #define ATTR_STARTPOINT     "startPoint"
        #define ATTR_STYLE          "style"
        #define ATTR_SWITCHSTYLE    "switchStyle"
        #define ATTR_TEMPLATE       "template"
        #define ATTR_TURNSPERFULLRANGE  "turnsPerFullRange"
        #define ATTR_TYPE           "type"
        #define ATTR_UNITID         "unitID"
        #define ATTR_VARIABLES      "variables"
        #define ATTR_VENDOR         "vendor"
        #define ATTR_VERSION        "version"

        /**
         * Defines some predefined Representation Remote Names
         */
        #define GENERIC                 "Generic"
        #define GENERIC_4_CELLS         "Generic 4 Cells"
        #define GENERIC_8_CELLS         "Generic 8 Cells"
        #define GENERIC_12_CELLS        "Generic 12 Cells"
        #define GENERIC_24_CELLS        "Generic 24 Cells"
        #define GENERIC_N_CELLS         "Generic %d Cells"
        #define QUICK_CONTROL_8_CELLS   "Quick Controls 8 Cells"

        /**
         * Layer Types used in a VST XML Representation
         */
        namespace LayerType
        {
            enum
            {
                kKnob = 0,      ///< a knob (encoder or not)
                kPressedKnob,   ///< a knob which is used by pressing and turning
                kSwitchKnob,    ///< knob could be pressed to simulate a switch
                kSwitch,        ///< a "on/off" button
                kLED,           ///< LED like VU-meter or display around a knob
                kLink,          ///< indicates that this layer is a folder linked to an another INode (page)
                kDisplay,       ///< only for text display (not really a control)
                kFader,         ///< a fader
                kEndOfLayerType
            };

            /**
             * FIDString variant of the LayerType
             */
            static const FIDString layerTypeFIDString[] =
            {
                "knob",
                "pressedKnob",
                "switchKnob",
                "switch",
                "LED",
                "link",
                "display",
                "fader",
                NULL
            };
        };

        /**
         * Curve Types used in a VST XML Representation
         */
        namespace CurveType
        {
            const CString kSegment      = "segment";
            const CString kValueList    = "valueList";
        };

        /**
         * Attributes used to defined a Layer in a VST XML Representation
         */
        namespace Attributes
        {
            const CString kStyle        = ATTR_STYLE;           ///< string attribute : See AttributesStyle for available string value
            const CString kLEDStyle     = ATTR_LEDSTYLE;        ///< string attribute : See AttributesStyle for available string value
            const CString kSwitchStyle  = ATTR_SWITCHSTYLE;     ///< string attribute : See AttributesStyle for available string value
            const CString kKnobTurnsPerFullRange = ATTR_TURNSPERFULLRANGE;  ///< float attribute
            const CString kFunction     = ATTR_FUNCTION;        ///< string attribute : See AttributesFunction for available string value
            const CString kFlags        = ATTR_FLAGS;           ///< string attribute : See AttributesFlags for available string value
        };

        /**
         * Attributes Function used to defined the function of a Layer in a VST XML Representation
         */
        namespace AttributesFunction
        {
            /// Global Style
            const CString kPanPosCenterXFunc        = "PanPosCenterX";      ///< Gravity point X-axis (L-R) (for stereo: middle between left and right)
            const CString kPanPosCenterYFunc        = "PanPosCenterY";      ///< Gravity point Y-axis (Front-Rear)
            const CString kPanPosFrontLeftXFunc     = "PanPosFrontLeftX";   ///< Left channel Position in X-axis
            const CString kPanPosFrontLeftYFunc     = "PanPosFrontLeftY";   ///< Left channel Position in Y-axis
            const CString kPanPosFrontRightXFunc    = "PanPosFrontRightX";  ///< Right channel Position in X-axis
            const CString kPanPosFrontRightYFunc    = "PanPosFrontRightY";  ///< Right channel Position in Y-axis
            const CString kPanRotationFunc          = "PanRotation";        ///< Rotation around the Center (gravity point)
            const CString kPanLawFunc               = "PanLaw";             ///< Panning Law
            const CString kPanMirrorModeFunc        = "PanMirrorMode";      ///< Panning Mirror Mode
            const CString kPanLfeGainFunc           = "PanLfeGain";         ///< Panning LFE Gain
            const CString kGainReductionFunc        = "GainReduction";      ///< Gain Reduction for compressor
            const CString kSoloFunc                 = "Solo";               ///< Solo
            const CString kMuteFunc                 = "Mute";               ///< Mute
            const CString kVolumeFunc               = "Volume";             ///< Volume
        };

        /**
         * Attributes Style associated a specific Layer Type in a VST XML Representation
         */
        namespace AttributesStyle
        {
            /// Global Style
            const CString kInverseStyle         = "inverse";    ///< the associated layer should use the inverse value of parameter (1 - x).

            /// LED Style
            const CString kLEDWrapLeftStyle     = "wrapLeft";   ///< |======>----- (the default one if not specified)
            const CString kLEDWrapRightStyle    = "wrapRight";  ///< -------<====|
            const CString kLEDSpreadStyle       = "spread";     ///< ---<==|==>---
            const CString kLEDBoostCutStyle     = "boostCut";   ///< ------|===>--
            const CString kLEDSingleDotStyle    = "singleDot";  ///< --------|----

            /// Switch Style
            const CString kSwitchPushStyle      = "push";       ///< Apply only when pressed, unpressed will reset the value to min.
            const CString kSwitchPushIncLoopedStyle = "pushIncLooped";  ///< Push will increment the value. When the max is reached it will restart with min.
                                                                        ///< The default one if not specified (with 2 states values it is a OnOff switch).
            const CString kSwitchPushDecLoopedStyle = "pushDecLooped";  ///< Push will decrement the value. When the min is reached it will restart with max.
            const CString kSwitchPushIncStyle   = "pushInc";    ///< Increment after each press (delta depends of the curve).
            const CString kSwitchPushDecStyle   = "pushDec";    ///< Decrement after each press (delta depends of the curve).
            const CString kSwitchLatchStyle     = "latch";      ///< Each push-release will change the value between min and max.
                                                                ///< A timeout between push and release could be used to simulate a push style (if timeout is reached).
        };

        /**
         * Attributes Flags defining a Layer in a VST XML Representation
         */
        namespace AttributesFlags
        {
            const CString kHideableFlag         = "hideable";   ///< the associated layer marked as hideable allows a remote to hide or make it not usable a parameter when the associated value is inactive
        };

    } /* namespace Vst */
} /* namespace Steinberg */

#include <steinberg/vst3/base/AlignPop.h>


#endif /* _3RD_PARTY_STEINBERG_VST3_VST_REPRESENTATIONINFO_H_ */
