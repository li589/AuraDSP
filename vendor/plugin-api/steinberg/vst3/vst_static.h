/*
 * Copyright 2025, Steinberg Media Technologies GmbH, All Rights Reserved
 * Copyright 2025 Linux Studio Plugins Project <lsp.plugin@gmail.com>
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

#ifndef _3RD_PARTY_STEINBERG_VST3_VST_STATIC_H_
#define _3RD_PARTY_STEINBERG_VST3_VST_STATIC_H_

#include <steinberg/vst3/vst.h>

namespace Steinberg
{
    namespace Vst
    {
        // VST 3.0
        DEF_CLASS_IID(IComponent, 0xE831FF31, 0xF2D54301, 0x928EBBEE, 0x25697802)
        DEF_CLASS_IID(IAudioProcessor, 0x42043F99, 0xB7DA453C, 0xA569E79D, 0x9AAEC33D)
        DEF_CLASS_IID(IUnitData, 0x6C389611, 0xD391455D, 0xB870B833, 0x94A0EFDD)
        DEF_CLASS_IID(IProgramListData, 0x8683B01F, 0x7B354F70, 0xA2651DEC, 0x353AF4FF)

        DEF_CLASS_IID(IEditController, 0xDCD7BBE3, 0x7742448D, 0xA874AACC, 0x979C759E)
        DEF_CLASS_IID(IUnitInfo, 0x3D4BD6B5, 0x913A4FD2, 0xA886E768, 0xA5EB92C1)

        DEF_CLASS_IID(IConnectionPoint, 0x70A4156F, 0x6E6E4026, 0x989148BF, 0xAA60D8D1)

        DEF_CLASS_IID(IComponentHandler, 0x93A0BEA3, 0x0BD045DB, 0x8E890B0C, 0xC1E46AC6)
        DEF_CLASS_IID(IUnitHandler, 0x4B5147F8, 0x4654486B, 0x8DAB30BA, 0x163A3C56)

        DEF_CLASS_IID(IParamValueQueue, 0x01263A18, 0xED074F6F, 0x98C9D356, 0x4686F9BA)
        DEF_CLASS_IID(IParameterChanges, 0xA4779663, 0x0BB64A56, 0xB44384A8, 0x466FEB9D)

        DEF_CLASS_IID(IEventList, 0x3A2C4214, 0x346349FE, 0xB2C4F397, 0xB9695A44)
        DEF_CLASS_IID(IMessage, 0x936F033B, 0xC6C047DB, 0xBB0882F8, 0x13C1E613)

        DEF_CLASS_IID(IHostApplication, 0x58E595CC, 0xDB2D4969, 0x8B6AAF8C, 0x36A664E5)
        DEF_CLASS_IID(IAttributeList, 0x1E5F0AEB, 0xCC7F4533, 0xA2544011, 0x38AD5EE4)

        // VST 3.0.1
        DEF_CLASS_IID(IMidiMapping, 0xDF0FF9F7, 0x49B74669, 0xB63AB732, 0x7ADBF5E5)

        // VST 3.0.2
        DEF_CLASS_IID(IParameterFinder, 0x0F618302, 0x215D4587, 0xA512073C, 0x77B9D383)

        // VST 3.1
        DEF_CLASS_IID(IComponentHandler2, 0xF040B4B3, 0xA36045EC, 0xABCDC045, 0xB4D5A2CC)
        DEF_CLASS_IID(IEditController2, 0x7F4EFE59, 0xF3204967, 0xAC27A3AE, 0xAFB63038)
        DEF_CLASS_IID(IAudioPresentationLatency, 0x309ECE78, 0xEB7D4fae, 0x8B2225D9, 0x09FD08B6)
        DEF_CLASS_IID(IVst3ToVst2Wrapper, 0x29633AEC, 0x1D1C47E2, 0xBB85B97B, 0xD36EAC61)
        DEF_CLASS_IID(IVst3ToAUWrapper, 0xA3B8C6C5, 0xC0954688, 0xB0916F0B, 0xB697AA44)

        // VST 3.5
        DEF_CLASS_IID(INoteExpressionController, 0xB7F8F859, 0x41234872, 0x91169581, 0x4F3721A3)
        DEF_CLASS_IID(IKeyswitchController, 0x1F2F76D3, 0xBFFB4B96, 0xB99527A5, 0x5EBCCEF4)
        DEF_CLASS_IID(IContextMenuTarget, 0x3CDF2E75, 0x85D34144, 0xBF86D36B, 0xD7C4894D)
        DEF_CLASS_IID(IContextMenu, 0x2E93C863, 0x0C9C4588, 0x97DBECF5, 0xAD17817D)
        DEF_CLASS_IID(IComponentHandler3, 0x69F11617, 0xD26B400D, 0xA4B6B964, 0x7B6EBBAB)
        DEF_CLASS_IID(IEditControllerHostEditing, 0xC1271208, 0x70594098, 0xB9DD34B3, 0x6BB0195E)
        DEF_CLASS_IID(IXmlRepresentationController, 0xA81A0471, 0x48C34DC4, 0xAC30C9E1, 0x3C8393D5)

        // VST 3.6
        DEF_CLASS_IID(IInterAppAudioHost, 0x0CE5743D, 0x68DF415E, 0xAE285BD4, 0xE2CDC8FD)
        DEF_CLASS_IID(IInterAppAudioConnectionNotification, 0x6020C72D, 0x5FC24AA1, 0xB0950DB5, 0xD7D6D5CF)
        DEF_CLASS_IID(IInterAppAudioPresetManager, 0xADE6FCC4, 0x46C94E1D, 0xB3B49A80, 0xC93FEFDD)
        DEF_CLASS_IID(IStreamAttributes, 0xD6CE2FFC, 0xEFAF4B8C, 0x9E74F1BB, 0x12DA44B4)

        // VST 3.6.5
        DEF_CLASS_IID(ChannelContext::IInfoListener, 0x0F194781, 0x8D984ADA, 0xBBA0C1EF, 0xC011D8D0)
        DEF_CLASS_IID(IPrefetchableSupport, 0x8AE54FDA, 0xE93046B9, 0xA28555BC, 0xDC98E21E)
        DEF_CLASS_IID(IUnitHandler2, 0xF89F8CDF, 0x699E4BA5, 0x96AAC9A4, 0x81452B01)
        DEF_CLASS_IID(IAutomationState, 0xB4E8287F, 0x1BB346AA, 0x83A46667, 0x68937BAB)

        // VST 3.6.8
        DEF_CLASS_IID(IComponentHandlerBusActivation, 0x067D02C1, 0x5B4E274D, 0xA92D90FD, 0x6EAF7240)
        DEF_CLASS_IID(IVst3ToAAXWrapper, 0x6D319DC6, 0x60C56242, 0xB32C951B, 0x93BEF4C6)

        // VST 3.6.11
        DEF_CLASS_IID(INoteExpressionPhysicalUIMapping, 0xB03078FF, 0x94D24AC8, 0x90CCD303, 0xD4133324)

        // VST 3.6.12
        DEF_CLASS_IID(IMidiLearn, 0x6B2449CC, 0x419740B5, 0xAB3C79DA, 0xC5FE5C86)
        DEF_CLASS_IID(IPlugInterfaceSupport, 0x4FB58B9E, 0x9EAA4E0F, 0xAB361C1C, 0xCCB56FEA)
        DEF_CLASS_IID(IVst3WrapperMPESupport, 0x44149067, 0x42CF4BF9, 0x8800B750, 0xF7359FE3)

        // VST 3.6.13
        DEF_CLASS_IID(ITestPlugProvider, 0x86BE70EE, 0x4E99430F, 0x978F1E6E, 0xD68FB5BA)

        // VST 3.7
        DEF_CLASS_IID(IParameterFunctionName, 0x6D21E1DC, 0x91199D4B, 0xA2A02FEF, 0x6C1AE55C)
        DEF_CLASS_IID(IProcessContextRequirements, 0x2A654303, 0xEF764E3D, 0x95B5FE83, 0x730EF6D0)
        DEF_CLASS_IID(IProgress, 0x00C9DC5B, 0x9D904254, 0x91A388C8, 0xB4E91B69)
        DEF_CLASS_IID(ITestPlugProvider2, 0xC7C75364, 0x7B8343AC, 0xA4495B0A, 0x3E5A46C7)

        // VST 3.7.9
        DEF_CLASS_IID(IComponentHandlerSystemTime, 0xF9E53056, 0xD1554CD5, 0xB7695E1B, 0x7B0F7745)
        DEF_CLASS_IID(IDataExchangeHandler, 0x36D551BD, 0x6FF54F08, 0xB48E830D, 0x8BD5A03B)
        DEF_CLASS_IID(IDataExchangeReceiver, 0x45A759DC, 0x84FA4907, 0xABCB6175, 0x2FC786B6)

        // VST 3.7.11
        DEF_CLASS_IID(IRemapParamID, 0x2B88021E, 0x6286B646, 0xB49DF76A, 0x5663061C)

        // VST 3.8.0
        DEF_CLASS_IID(IMidiMapping2, 0x6DE14B88, 0x03F94F09, 0xA2552F0F, 0x9326593E)
        DEF_CLASS_IID(IMidiLearn2, 0xF07E498A, 0x78864327, 0x8B431CED, 0xA3C553FC)

    } /* namespace Vst */
} /* namespace Steinberg */



#endif /* _3RD_PARTY_STEINBERG_VST3_VST_STATIC_H_ */
