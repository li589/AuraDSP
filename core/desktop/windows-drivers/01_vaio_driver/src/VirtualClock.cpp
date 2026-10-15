/*++

Module Name:

    VirtualClock.cpp

Abstract:

    See VirtualClock.h.

--*/

#include "VirtualClock.h"

CAuraVirtualClock::CAuraVirtualClock()
    : m_ullQpcFrequency(0)
    , m_ullLastQpc(0)
    , m_ullRemainder(0)
    , m_ullPlayOffset(0)
    , m_ullWriteOffset(0)
    , m_bRunning(FALSE)
{
}

VOID
CAuraVirtualClock::SetQpcFrequency(
    _In_ ULONGLONG Frequency
    )
{
    m_ullQpcFrequency = Frequency;
}

VOID
CAuraVirtualClock::Reset()
{
    m_ullLastQpc     = 0;
    m_ullRemainder   = 0;
    m_ullPlayOffset  = 0;
    m_ullWriteOffset = 0;
    m_bRunning       = FALSE;
}

VOID
CAuraVirtualClock::Start(
    _In_ ULONGLONG QpcNow
    )
{
    m_ullLastQpc = QpcNow;
    m_bRunning   = TRUE;
}

VOID
CAuraVirtualClock::Stop(
    _In_ ULONGLONG QpcNow
    )
{
    if (m_bRunning)
    {
        //
        // Fold in the time that elapsed up to the moment we were stopped, but
        // keep the remainder so a later Start()/Advance() stays drift-free.
        //
        if (m_ullQpcFrequency != 0 && QpcNow > m_ullLastQpc)
        {
            //
            // Nothing to add here: Advance() is the only place that converts
            // time to bytes, and the caller will have advanced just before
            // stopping.  We only re-base the timestamp.
            //
            m_ullLastQpc = QpcNow;
        }
        m_bRunning = FALSE;
    }
}

ULONG
CAuraVirtualClock::Advance(
    _In_ ULONGLONG QpcNow,
    _In_ ULONG     BytesPerSecond
    )
{
    ULONGLONG   Accum;
    ULONGLONG   BytesAdvanced;

    if (!m_bRunning || m_ullQpcFrequency == 0 || BytesPerSecond == 0)
    {
        return 0;
    }

    if (QpcNow <= m_ullLastQpc)
    {
        return 0;
    }

    //
    // bytes = delta * BytesPerSecond / Frequency.
    //
    // Accumulate in (byte * tick) units so the fractional part carries over to
    // the next call.  Worst case magnitude: a 100 s gap on a 10 MHz counter is
    // ~1e9 ticks; times a 768000 B/s stream is ~7.7e14 -- well inside 64 bits.
    //
    Accum  = m_ullRemainder + ((QpcNow - m_ullLastQpc) * (ULONGLONG)BytesPerSecond);
    m_ullLastQpc = QpcNow;

    BytesAdvanced  = Accum / m_ullQpcFrequency;
    m_ullRemainder = Accum % m_ullQpcFrequency;

    m_ullPlayOffset  += BytesAdvanced;
    m_ullWriteOffset += BytesAdvanced;

    return (ULONG)BytesAdvanced;
}
