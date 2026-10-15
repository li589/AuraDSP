/*++

Module Name:

    NewDelete.h

Abstract:

    Kernel-mode tag-aware placement new / delete.

--*/

#pragma once

#include <ntddk.h>

#include "AuraPoolCompat.h"

//
// Small helper so the same source compiles for the Win7 downlevel target
// (EWDK 19041 / NTDDI_WIN7) and the modern target (WDK 28000 / Win10):
// ExAllocatePool2() is only *implemented* from Windows 10 2004 onward, so for
// older targets we fall back to the classic ExAllocatePoolWithTag().
//
// This is the only place in the driver that knows about the split -- everything
// else just passes POOL_FLAGS values around.
//
__forceinline
PVOID
AuraAllocatePool(
    _In_ POOL_FLAGS Flags,
    _In_ SIZE_T     NumberOfBytes,
    _In_ ULONG      Tag
    )
{
#if AURA_POOL_HAS_FLAG_API

    return ExAllocatePool2(Flags, NumberOfBytes, Tag);

#else

    PVOID p;

    #pragma warning(push)
    #pragma warning(disable: 4996)   // ExAllocatePoolWithTag is deprecated on the modern target
    //
    // NonPagedPool (not NonPagedPoolNx) is deliberate: the NX pool type only
    // exists from Windows 8 on, and this branch is the Win7-class one.
    //
    p = ExAllocatePoolWithTag(
            ((Flags & POOL_FLAG_PAGED) != 0) ? PagedPool : NonPagedPool,
            NumberOfBytes,
            Tag);
    #pragma warning(pop)

    //
    // ExAllocatePool2() zero-fills unless POOL_FLAG_UNINITIALIZED is set;
    // ExAllocatePoolWithTag() never does.  Do it by hand so object construction
    // behaves identically on both tracks instead of quietly differing.
    //
    if (p != NULL)
    {
        RtlZeroMemory(p, NumberOfBytes);
    }

    return p;

#endif
}

//
// Tag-aware placement new.  ExAllocatePool2() with default flags zero-fills the
// allocation, which is what every AuraVAIO object wants.
//
PVOID
operator new(
    _In_ size_t     Size,
    _In_ POOL_FLAGS PoolFlags,
    _In_ ULONG      Tag
    );

PVOID
operator new(
    _In_ size_t     Size,
    _In_ POOL_FLAGS PoolFlags
    );

VOID
__cdecl
operator delete(
    _In_opt_ PVOID  Pointer,
    _In_     ULONG  Tag
    );

VOID
__cdecl
operator delete(
    _In_opt_ PVOID  Pointer,
    _In_     size_t Size
    );

VOID
__cdecl
operator delete(
    _In_opt_ PVOID  Pointer
    );

VOID
__cdecl
operator delete[](
    _In_opt_ PVOID  Pointer
    );

VOID
__cdecl
operator delete[](
    _In_opt_ PVOID  Pointer,
    _In_     size_t Size
    );
