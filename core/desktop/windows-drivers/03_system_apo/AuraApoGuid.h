// AuraApoGuid.h — 自研 APO 的 CLSID（现生成的专属 GUID，永不复用 EAPO/ViPER 的）。
#pragma once

#include <guiddef.h>

// {415AD8ED-7A45-4F4F-AC69-043830EBC174} — AuraAPO EFX（后混，主力，v1 注册此键）
DEFINE_GUID(CLSID_AuraApoEfx,
    0x415ad8ed, 0x7a45, 0x4f4f, 0xac, 0x69, 0x04, 0x38, 0x30, 0xeb, 0xc1, 0x74);

// {D3503543-BB05-4D70-BFC3-AE7102A4BDCB} — 预留 Pre-Mix（v1 不注册，占位防重）
DEFINE_GUID(CLSID_AuraApoPreMix,
    0xd3503543, 0xbb05, 0x4d70, 0xbf, 0xc3, 0xae, 0x71, 0x02, 0xa4, 0xbd, 0xcb);
