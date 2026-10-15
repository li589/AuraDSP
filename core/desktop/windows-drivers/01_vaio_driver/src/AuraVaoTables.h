/*++

Module Name:

    AuraVaoTables.h

Abstract:

    KS filter / pin / node / connection descriptors for the AuraVAIO render
    endpoint.

    Minimal render-only topology (see the milestone note in AuraVaio.h):

        Wave filter                          Topology filter
        -----------                          ---------------
        pin0  Render sink  (DATAFLOW_IN)     pin0  Bridge    (DATAFLOW_IN)
          |                                    |
          |  (internal connection)              |  (internal connection)
          v                                    v
        pin1  Bridge       (DATAFLOW_OUT)    pin1  Speaker   (DATAFLOW_OUT)
                     \                      /
                      `-- PcRegisterPhysicalConnection --'

    Neither filter declares nodes yet, so no automation table beyond the empty
    placeholder is required.  KSPROPSETID_Audio (volume / mute / peak meter)
    and the 7.1 format matrix are follow-up increments.

--*/

#ifndef _AURA_VAO_TABLES_H_
#define _AURA_VAO_TABLES_H_

//=============================================================================
// Empty automation table.
//
// PortCls only requires that the item pointers be NULL when the matching
// counts are zero.  Referenced from the filter descriptors so they are never
// NULL (some PortCls paths dereference the filter's table unconditionally).
//=============================================================================
static
PCAUTOMATION_TABLE AuraNullAutomation =
{
    0, 0, NULL,     // Property
    0, 0, NULL,     // Method
    0, 0, NULL,     // Event
    0               // Reserved
};

//=============================================================================
// Wave filter - streaming (host) pin
//=============================================================================

//
// Data ranges.  One range per (channel count, sample type) combination; the
// channel count in a range is an exact-match requirement for
// DataRangeIntersection (the class handler does the rest).
//
static
KSDATARANGE_AUDIO AuraWavePinDataRangesStream[] =
{
    {   // 0 : 32-bit IEEE float
        {
            sizeof(KSDATARANGE_AUDIO),
            0,                                              // Flags
            0,                                              // SampleSize (don't care)
            0,                                              // Reserved
            STATICGUIDOF(KSDATAFORMAT_TYPE_AUDIO),
            STATICGUIDOF(KSDATAFORMAT_SUBTYPE_IEEE_FLOAT),
            STATICGUIDOF(KSDATAFORMAT_SPECIFIER_WAVEFORMATEX)
        },
        AURA_DEFAULT_CHANNELS,                              // MaximumChannels
        32, 32,                                             // Min/Max bits per sample
        44100, 96000                                        // Min/Max sample rate
    },
    {   // 1 : 16-bit PCM
        {
            sizeof(KSDATARANGE_AUDIO),
            0,
            0,
            0,
            STATICGUIDOF(KSDATAFORMAT_TYPE_AUDIO),
            STATICGUIDOF(KSDATAFORMAT_SUBTYPE_PCM),
            STATICGUIDOF(KSDATAFORMAT_SPECIFIER_WAVEFORMATEX)
        },
        AURA_DEFAULT_CHANNELS,
        16, 16,
        44100, 96000
    }
};

static
PKSDATARANGE AuraWavePinDataRangePointersStream[] =
{
    PKSDATARANGE(&AuraWavePinDataRangesStream[0]),
    PKSDATARANGE(&AuraWavePinDataRangesStream[1])
};

//=============================================================================
// Wave filter / topology filter - bridge (analog) pins
//=============================================================================

static
KSDATARANGE AuraPinDataRangesBridge[] =
{
    {
        sizeof(KSDATARANGE),
        0,
        0,
        0,
        STATICGUIDOF(KSDATAFORMAT_TYPE_AUDIO),
        STATICGUIDOF(KSDATAFORMAT_SUBTYPE_ANALOG),
        STATICGUIDOF(KSDATAFORMAT_SPECIFIER_NONE)
    }
};

static
PKSDATARANGE AuraPinDataRangePointersBridge[] =
{
    PKSDATARANGE(&AuraPinDataRangesBridge[0])
};

//=============================================================================
// Wave filter pins
//=============================================================================

static
PCPIN_DESCRIPTOR AuraWaveMiniportPins[] =
{
    // KSPIN_WAVE_RENDER_SINK : the host render stream pin.
    {
        1,                                          // MaxGlobalInstanceCount
        1,                                          // MaxFilterInstanceCount
        0,                                          // MinFilterInstanceCount
        &AuraNullAutomation,                        // AutomationTable
        {
            0,                                      // InterfacesCount
            NULL,                                   // Interfaces
            0,                                      // MediumsCount
            NULL,                                   // Mediums
            SIZEOF_ARRAY(AuraWavePinDataRangePointersStream),
            AuraWavePinDataRangePointersStream,     // DataRanges
            KSPIN_DATAFLOW_IN,                      // DataFlow
            KSPIN_COMMUNICATION_SINK,               // Communication
            &KSCATEGORY_AUDIO,                      // Category
            NULL,                                   // Name
            0                                       // Reserved
        }
    },
    // KSPIN_WAVE_BRIDGE : toward the topology filter.
    {
        0,                                          // MaxGlobalInstanceCount (not instantiable)
        0,
        0,
        &AuraNullAutomation,
        {
            0,
            NULL,
            0,
            NULL,
            SIZEOF_ARRAY(AuraPinDataRangePointersBridge),
            AuraPinDataRangePointersBridge,
            KSPIN_DATAFLOW_OUT,
            KSPIN_COMMUNICATION_NONE,
            &KSCATEGORY_AUDIO,
            NULL,
            0
        }
    }
};

//
// Internal connection: render sink -> bridge (no nodes in between yet).
//
static
PCCONNECTION_DESCRIPTOR AuraWaveMiniportConnections[] =
{
    { PCFILTER_NODE, KSPIN_WAVE_RENDER_SINK, PCFILTER_NODE, KSPIN_WAVE_BRIDGE }
};

static
PCFILTER_DESCRIPTOR AuraWaveMiniportFilterDescriptor =
{
    0,                                          // Version
    &AuraNullAutomation,                        // AutomationTable
    sizeof(PCPIN_DESCRIPTOR),                   // PinSize
    SIZEOF_ARRAY(AuraWaveMiniportPins),         // PinCount
    AuraWaveMiniportPins,                       // Pins
    sizeof(PCNODE_DESCRIPTOR),                  // NodeSize
    0,                                          // NodeCount
    NULL,                                       // Nodes
    SIZEOF_ARRAY(AuraWaveMiniportConnections),  // ConnectionCount
    AuraWaveMiniportConnections,                // Connections
    0,                                          // CategoryCount
    NULL                                        // Categories (class defaults)
};

//=============================================================================
// Topology filter pins
//=============================================================================

static
PCPIN_DESCRIPTOR AuraTopoMiniportPins[] =
{
    // KSPIN_TOPO_BRIDGE : receives from the wave filter.
    {
        0,
        0,
        0,
        &AuraNullAutomation,
        {
            0,
            NULL,
            0,
            NULL,
            SIZEOF_ARRAY(AuraPinDataRangePointersBridge),
            AuraPinDataRangePointersBridge,
            KSPIN_DATAFLOW_IN,
            KSPIN_COMMUNICATION_NONE,
            &KSCATEGORY_AUDIO,
            NULL,
            0
        }
    },
    // KSPIN_TOPO_SPEAKER : the endpoint-facing ("physical") output.
    {
        0,
        0,
        0,
        &AuraNullAutomation,
        {
            0,
            NULL,
            0,
            NULL,
            SIZEOF_ARRAY(AuraPinDataRangePointersBridge),
            AuraPinDataRangePointersBridge,
            KSPIN_DATAFLOW_OUT,
            KSPIN_COMMUNICATION_NONE,
            &KSNODETYPE_SPEAKER,
            NULL,
            0
        }
    }
};

static
PCCONNECTION_DESCRIPTOR AuraTopoMiniportConnections[] =
{
    { PCFILTER_NODE, KSPIN_TOPO_BRIDGE, PCFILTER_NODE, KSPIN_TOPO_SPEAKER }
};

static
PCFILTER_DESCRIPTOR AuraTopoMiniportFilterDescriptor =
{
    0,
    &AuraNullAutomation,
    sizeof(PCPIN_DESCRIPTOR),
    SIZEOF_ARRAY(AuraTopoMiniportPins),
    AuraTopoMiniportPins,
    sizeof(PCNODE_DESCRIPTOR),
    0,
    NULL,
    SIZEOF_ARRAY(AuraTopoMiniportConnections),
    AuraTopoMiniportConnections,
    0,
    NULL
};

//=============================================================================
// Wave <-> topology physical connections.
//
// Registered with PcRegisterPhysicalConnection(DeviceObject,
// FromUnknown, FromPin, ToUnknown, ToPin).  For render the data flows
// wave-bridge -> topology-bridge, so the wave filter is the "From" side.
//=============================================================================

typedef struct _AURA_PHYSICAL_CONNECTION
{
    ULONG   WavePin;        // pin on the wave (sub)device
    ULONG   TopologyPin;    // pin on the topology (sub)device
} AURA_PHYSICAL_CONNECTION;

static
AURA_PHYSICAL_CONNECTION AuraPhysicalConnections[] =
{
    { KSPIN_WAVE_BRIDGE, KSPIN_TOPO_BRIDGE }
};

#endif // _AURA_VAO_TABLES_H_
