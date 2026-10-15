/*++

Module Name:

    NewDelete.cpp

Abstract:

    Kernel-mode tag-aware operator new / delete.

    Kept in a single translation unit (rather than inline in a header) to avoid
    MSVC warning C4595 and to keep the allocation tag uniform.

--*/

#include "AuraVaio.h"

PVOID
operator new(
    _In_ size_t     Size,
    _In_ POOL_FLAGS PoolFlags,
    _In_ ULONG      Tag
    )
{
    return AuraAllocatePool(PoolFlags, Size, Tag);
}

PVOID
operator new(
    _In_ size_t     Size,
    _In_ POOL_FLAGS PoolFlags
    )
{
    return AuraAllocatePool(PoolFlags, Size, AURA_POOLTAG);
}

VOID
__cdecl
operator delete(
    _In_opt_ PVOID  Pointer,
    _In_     ULONG  Tag
    )
{
    if (Pointer != NULL)
    {
        ExFreePoolWithTag(Pointer, Tag);
    }
}

VOID
__cdecl
operator delete(
    _In_opt_ PVOID  Pointer,
    _In_     size_t Size
    )
{
    UNREFERENCED_PARAMETER(Size);

    if (Pointer != NULL)
    {
        ExFreePoolWithTag(Pointer, AURA_POOLTAG);
    }
}

VOID
__cdecl
operator delete(
    _In_opt_ PVOID  Pointer
    )
{
    if (Pointer != NULL)
    {
        ExFreePoolWithTag(Pointer, AURA_POOLTAG);
    }
}

VOID
__cdecl
operator delete[](
    _In_opt_ PVOID  Pointer
    )
{
    if (Pointer != NULL)
    {
        ExFreePoolWithTag(Pointer, AURA_POOLTAG);
    }
}

VOID
__cdecl
operator delete[](
    _In_opt_ PVOID  Pointer,
    _In_     size_t Size
    )
{
    UNREFERENCED_PARAMETER(Size);

    if (Pointer != NULL)
    {
        ExFreePoolWithTag(Pointer, AURA_POOLTAG);
    }
}
