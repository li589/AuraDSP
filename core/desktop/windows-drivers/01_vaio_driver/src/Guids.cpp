/*++

Module Name:

    Guids.cpp

Abstract:

    The single translation unit that materialises the PortCls IID/CLSID GUID
    definitions used by AuraVAIO.

    <portcls.h> only *declares* these (a plain DEFINE_GUID expands to
    "EXTERN_C const GUID name;") and portcls.lib does not export them, so
    exactly one TU must instantiate them.  We spell the definitions out here
    rather than pulling in INITGUID, which would also materialise every
    DEFINE_GUID in ks.h / ksmedia.h and needlessly bloat the binary.

    Values are verbatim from
    Windows Kits\10\Include\10.0.28000.0\km\portcls.h
    (identical in the EWDK 19041 headers).

--*/

#include "AuraVaio.h"

//
// IID_IUnknown: also declaration-only in the kernel headers (punknown.h emits
// "EXTERN_C const GUID FAR IID_IUnknown;" unless INITGUID is set), and unlike
// the user-mode world there is no uuid.lib to fall back on.  Canonical value,
// as spelled by km\punknown.h (portcls.h -> punknown.h).
//
extern "C" const GUID IID_IUnknown =
{ 0x00000000, 0x0000, 0x0000, { 0xc0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46 } };

extern "C" const GUID IID_IAdapterPowerManagement =
{ 0x793417D0L, 0x35FE, 0x11D1, { 0xAD, 0x08, 0x00, 0xA0, 0xC9, 0x0A, 0xB1, 0xB0 } };

extern "C" const GUID IID_IPortTopology =
{ 0xb4c90a30L, 0x5791, 0x11d0, { 0x86, 0xf9, 0x00, 0xa0, 0xc9, 0x11, 0xb5, 0x44 } };

extern "C" const GUID IID_IMiniportTopology =
{ 0xb4c90a31L, 0x5791, 0x11d0, { 0x86, 0xf9, 0x00, 0xa0, 0xc9, 0x11, 0xb5, 0x44 } };

extern "C" const GUID IID_IPortWaveRT =
{ 0x339ff909, 0x68a9, 0x4310, { 0xb0, 0x9b, 0x27, 0x4e, 0x96, 0xee, 0x4c, 0xbd } };

extern "C" const GUID IID_IMiniportWaveRT =
{ 0x0f9fc4d6, 0x6061, 0x4f3c, { 0xb1, 0xfc, 0x07, 0x5e, 0x35, 0xf7, 0x96, 0x0a } };

extern "C" const GUID IID_IMiniportWaveRTStream =
{ 0x000ac9ab, 0xfaab, 0x4f3d, { 0x94, 0x55, 0x6f, 0xf8, 0x30, 0x6a, 0x74, 0xa0 } };

extern "C" const GUID CLSID_PortTopology =
{ 0xb4c90a32L, 0x5791, 0x11d0, { 0x86, 0xf9, 0x00, 0xa0, 0xc9, 0x11, 0xb5, 0x44 } };

extern "C" const GUID CLSID_PortWaveRT =
{ 0xcc9be57a, 0xeb9e, 0x42b4, { 0x94, 0xfc, 0x0c, 0xad, 0x3d, 0xbc, 0xe7, 0xfa } };

