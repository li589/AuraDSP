/*++

Module Name:

    AuraPoolCompat.h

Abstract:

    Cross-track compatibility shim for the Windows 10 2004+ "flag based" pool
    allocation API.

    AuraVAIO is built twice, by two toolchains with very different targets:

        modern : WDK 28000  + VS2026, TargetVersion=Windows10  (NTDDI 0x0A000012)
        legacy : EWDK 19041 + VS2019, TargetVersion=Windows7   (NTDDI 0x06010000)

    wdm.h gates the whole flag API on NTDDI_WIN10_VB (0x0A000008) -- meaning
    ExAllocatePool2(), ExAllocatePool3() *and* the POOL_FLAGS typedef.  The EWDK
    19041 header is subtly asymmetric about it: the POOL_FLAG_* *constants* sit
    in an earlier "#if (NTDDI_VERSION >= NTDDI_WS03SP1)" block and therefore stay
    visible on a Win7 target, while the POOL_FLAGS *typedef* disappears with the
    functions.  A naive port therefore fails with "C2065: 'POOL_FLAGS':
    identifier not found" on every signature that mentions it.

    We want ONE source tree and ONE code path, so this header answers the single
    question the rest of the driver needs to ask:

        AURA_POOL_HAS_FLAG_API  --  is the native flag API available?

    When it is not, POOL_FLAGS is spelled out with its exact modern underlying
    type (ULONG64) so every signature keeps its modern shape and nothing else in
    the driver needs to know which track it is being compiled for.
    AuraAllocatePool() in NewDelete.h is the one and only place that maps those
    flags back onto the legacy POOL_TYPE selector.

--*/

#ifndef _AURA_POOL_COMPAT_H_
#define _AURA_POOL_COMPAT_H_

#include <ntddk.h>

//
// Present only when the headers know about the NTDDI_WIN10_VB threshold *and*
// we actually target it.  Written with a positive test so that a hypothetical
// older header set (which never defines NTDDI_WIN10_VB at all) correctly falls
// into the legacy branch instead of silently assuming the API exists.
//
#if defined(NTDDI_WIN10_VB) && (NTDDI_VERSION >= NTDDI_WIN10_VB)
#define AURA_POOL_HAS_FLAG_API  1
#else
#define AURA_POOL_HAS_FLAG_API  0
#endif

#if !AURA_POOL_HAS_FLAG_API

//
// Downlevel target (Win7 SP1 / Win8 / Win8.1, via the EWDK 19041 headers).
//
// Reproduce the modern typedef exactly.  A repeated *identical* typedef is
// legal C++, but we only ever emit it when the platform has not already done
// so, so there is no chance of a conflicting definition.
//
typedef ULONG64 POOL_FLAGS;

//
// The constants are in fact visible here (see the header comment), but pin the
// two we use so this file is self-contained even if a future header revision
// relocates them behind the same gate as the typedef.  Values are verbatim from
// the modern wdm.h.
//
#ifndef POOL_FLAG_PAGED
#define POOL_FLAG_PAGED        0x0000000000000100UI64  // Paged pool
#endif

#ifndef POOL_FLAG_NON_PAGED
#define POOL_FLAG_NON_PAGED    0x0000000000000040UI64  // Non paged pool NX
#endif

#endif // !AURA_POOL_HAS_FLAG_API

#endif // _AURA_POOL_COMPAT_H_
