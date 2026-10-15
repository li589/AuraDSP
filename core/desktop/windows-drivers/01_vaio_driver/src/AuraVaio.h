/*++

Module Name:

    AuraVaio.h

Abstract:

    Shared definitions for the AuraVAIO virtual audio driver.

    SPEC-WIN-DRIVER-001 §3.1 / Phase 4 ("实现模式 1：AuraVAIO 虚拟声卡驱动").

    AuraVAIO is a *virtual* (hardware-less) PortCls/WaveRT audio adapter.  It
    exposes exactly one render endpoint backed by a WaveRT ring buffer plus a
    synthetic ("virtual") position clock.  Per the §3.2 contract this driver
    contains NO DSP whatsoever: it only moves bytes and reports time.  The DSP
    lives in engine/ behind auradsp_engine.h and is reached from user mode.

    Milestone note: this revision implements the *minimal enumerable endpoint*
    (render only, zero topology nodes, no property set, no event notification).
    Capture, KSPROPSETID_Audio (volume/mute/peak meter), event-driven
    notification and the 7.1 format matrix are follow-up increments.

--*/

#ifndef _AURA_VAIO_H_
#define _AURA_VAIO_H_

#include <ntddk.h>
#include <ntstrsafe.h>
#include <wdf.h>
#include <portcls.h>
#include <ks.h>
#include <ksmedia.h>

// Must precede anything that names POOL_FLAGS: see the header for why the
// Win7 target needs the typedef spelled out for it.
#include "AuraPoolCompat.h"
#include "NewDelete.h"

//=============================================================================
// Identity
//=============================================================================

// Pool tag 'AVao' (MSVC packs 4-char constants little-endian).
#define AURA_POOLTAG    ((ULONG)('A' | ('V' << 8) | ('a' << 16) | ('o' << 24)))

//
// Subdevice names.  These MUST match the KSNAME_* values in
// AuraVaioDriver.inf [Strings]: PcRegisterSubdevice() appends the name to the
// device interface reference string and the INF's AddInterface directives look
// the very same string up.
//
#define AURA_KSNAME_WAVE        L"Wave"
#define AURA_KSNAME_TOPOLOGY    L"Topology"

//=============================================================================
// Debug tracing
//=============================================================================

#if defined(_DEBUG)
#define AURA_TRACE(...)      DbgPrint("AURA-VAIO: " __VA_ARGS__)
#else
#define AURA_TRACE(...)      ((void)0)
#endif

//=============================================================================
// KS pin / node numbering
//
// Minimal render-only topology:
//   Wave filter     : pin0 = host render sink (stream pin), pin1 = bridge
//   Topology filter : pin0 = bridge, pin1 = speaker ("physical") output
//   Neither filter declares nodes yet (see the milestone note above).
//=============================================================================

enum
{
    KSPIN_WAVE_RENDER_SINK  = 0,    // host -> adapter  (the WaveRT stream pin)
    KSPIN_WAVE_BRIDGE       = 1,    // adapter -> topology
    KSPIN_WAVE_PIN_COUNT
};

enum
{
    KSPIN_TOPO_BRIDGE       = 0,    // topology <- adapter
    KSPIN_TOPO_SPEAKER      = 1,    // the endpoint-facing ("physical") pin
    KSPIN_TOPO_PIN_COUNT
};

//=============================================================================
// Default stream format (the only format this increment advertises)
//=============================================================================

#define AURA_DEFAULT_CHANNELS           2           // stereo
#define AURA_DEFAULT_BITS_PER_SAMPLE    32          // IEEE float
#define AURA_DEFAULT_VALID_BITS         32
#define AURA_DEFAULT_SAMPLE_RATE        48000
#define AURA_DEFAULT_CHANNEL_MASK       KSAUDIO_SPEAKER_STEREO

//=============================================================================
// The PortCls adapter FDO device extension.
//
// PortCls allocates this layout for the adapter FDO; the leading fields are
// reserved for the class driver and the trailing slots are ours.  We stash the
// adapter-common object in m_pCommon so that the PnP remove path can release
// it.  The layout mirrors the WDK audio samples (byte offsets for 32-/64-bit).
//=============================================================================

// Declared 'class' (not 'struct') to match the real definition in
// AdapterCommon.h; a mismatch trips C4099, which /WX promotes to an error.
class CAdapterCommon;

typedef struct _PortClassDeviceContext
{
    ULONG_PTR           m_pulReserved1[2];                  // 0-7    0-15   reserved by PortCls
    PDEVICE_OBJECT      m_DoNotUsePhysicalDeviceObject;     // 8-11   16-23  reserved (our PDO)
    PVOID               m_pvReserved2;                      // 12-15  24-31  reserved (StartDevice)
    PVOID               m_pvReserved3;                      // 16-19  32-39  reserved ("Out Memory")
    CAdapterCommon     *m_pCommon;                          // 20-23  40-47  ours
    PVOID               m_pvUnused1;                        // 24-27  48-55  unused
    PVOID               m_pvUnused2;                        // 28-31  56-63  unused
} PortClassDeviceContext;

//=============================================================================
// Reference counting.
//
// Every AuraVAIO object derives from exactly ONE PortCls interface chain and
// therefore owns exactly one IUnknown subobject, so QueryInterface is
// implemented per class (no ambiguity, no aggregation).  We deliberately avoid
// the WDK's CUnknown/stdunk helper: the outer-unknown aggregation machinery is
// unnecessary here (nothing aggregates us) and its NULL-outer semantics are
// opaque.  Each user of this macro declares "LONG m_lRefCount;" itself.
//=============================================================================

#define AURA_REFCOUNT_BOILERPLATE                                       \
    STDMETHODIMP_(ULONG) AddRef()                                       \
    {                                                                   \
        return (ULONG)InterlockedIncrement(&m_lRefCount);                \
    }                                                                   \
    STDMETHODIMP_(ULONG) Release()                                      \
    {                                                                   \
        LONG _l = InterlockedDecrement(&m_lRefCount);                    \
        if (_l == 0)                                                    \
        {                                                               \
            delete this;                                                \
            return 0UL;                                                 \
        }                                                               \
        return (ULONG)_l;                                               \
    }

#define AURA_SAFE_RELEASE(p)                                            \
    do                                                                  \
    {                                                                   \
        if ((p) != NULL)                                                \
        {                                                               \
            (p)->Release();                                             \
            (p) = NULL;                                                 \
        }                                                               \
    } while (0)

#endif // _AURA_VAIO_H_
