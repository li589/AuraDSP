/*++

Module Name:

    VirtualClock.h

Abstract:

    The AuraVAIO "virtual clock".

    A virtual sound card has no DMA engine, so there is nothing to report a
    byte position.  Instead we synthesise the device cursor from the system
    performance counter: at the stream's nominal byte rate, elapsed time is
    converted into elapsed bytes.  Both the play cursor (what the device has
    consumed) and the write cursor are advanced by the same amount, which
    models an ideal device that never underruns or overruns.

    The conversion keeps a fractional remainder so the position does not drift
    against wall-clock time over long playback.

--*/

#ifndef _AURA_VIRTUAL_CLOCK_H_
#define _AURA_VIRTUAL_CLOCK_H_

#include "AuraVaio.h"

class CAuraVirtualClock
{
private:
    ULONGLONG   m_ullQpcFrequency;      // QPC ticks per second
    ULONGLONG   m_ullLastQpc;           // QPC at the last Advance()
    ULONGLONG   m_ullRemainder;         // sub-byte carry, in (byte * frequency) units
    ULONGLONG   m_ullPlayOffset;        // bytes the "device" has consumed
    ULONGLONG   m_ullWriteOffset;       // bytes the host has committed
    BOOLEAN     m_bRunning;

public:
    CAuraVirtualClock();

    VOID        SetQpcFrequency(_In_ ULONGLONG Frequency);
    VOID        Reset();
    VOID        Start(_In_ ULONGLONG QpcNow);
    VOID        Stop(_In_ ULONGLONG QpcNow);

    //
    // Advances both cursors to reflect the time elapsed up to QpcNow and
    // returns the number of bytes gained.
    //
    ULONG       Advance(_In_ ULONGLONG QpcNow, _In_ ULONG BytesPerSecond);

    ULONGLONG   PlayOffset() const  { return m_ullPlayOffset; }
    ULONGLONG   WriteOffset() const { return m_ullWriteOffset; }
    BOOLEAN     IsRunning() const   { return m_bRunning; }
};

#endif // _AURA_VIRTUAL_CLOCK_H_
