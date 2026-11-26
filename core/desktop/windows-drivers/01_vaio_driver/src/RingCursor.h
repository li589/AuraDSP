#pragma once

#include "../../common/AuraVaioIpc.h"

// The caller must hold g_RingLock so both read counters are anchored to the
// same write-side snapshot. This helper deliberately does not lock internally.
inline void AuraRingAnchorReadCursor(AURA_VAIO_SHARED_HEADER* header)
{
    header->ReadOffset = header->WriteOffset;
    header->TotalBytesRead = header->TotalBytesWritten;
}
