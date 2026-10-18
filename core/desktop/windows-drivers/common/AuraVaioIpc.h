/*++

Module Name:

    AuraVaioIpc.h

Abstract:

    Shared IPC definitions and IOCTL contract between the AuraVAIO kernel
    driver (01_vaio_driver) and user-mode components (AuraDSP engine,
    probes, and Flutter GUI backend).

    SPEC-WIN-DRIVER-001 Section 1.2 ("Zero-Copy Inter-Ring IPC").

    Dual-mode header: compatible with both NTDDK (kernel-mode) and Windows SDK
    (user-mode).

--*/

#ifndef _AURA_VAIO_IPC_H_
#define _AURA_VAIO_IPC_H_

#if defined(_KERNEL_MODE) || defined(DRIVER) || defined(_NTDDK_)
    #include <ntddk.h>
#else
    #define WIN32_LEAN_AND_MEAN
    #include <windows.h>
    #include <winioctl.h>
#endif

//=============================================================================
// Control Device Identification
//=============================================================================

#define AURA_VAIO_DEVICE_NAME_NT        L"\\Device\\AuraVaioControl"
#define AURA_VAIO_DOS_DEVICE_NAME       L"\\DosDevices\\AuraVaioControl"
#define AURA_VAIO_USER_DEVICE_PATH      L"\\\\.\\AuraVaioControl"

// {8866E14B-4E31-4F29-8798-900E196024D1}
#define AURA_VAIO_DEVINTERFACE_GUID_STR "{8866E14B-4E31-4F29-8798-900E196024D1}"

// Constants
#define AURA_VAIO_MAGIC_RING            ((ULONG)('A' | ('U' << 8) | ('R' << 16) | ('B' << 24))) // 'AURB'
#define AURA_VAIO_IPC_VERSION           1
#define AURA_VAIO_DEFAULT_RING_SIZE     (64 * 1024) // 64 KB ring payload (4096 stereo float frames)

//=============================================================================
// IOCTL Codes (FILE_DEVICE_UNKNOWN = 0x22, Custom function range 0x800-0x8FF)
//=============================================================================

#define IOCTL_AURAVAIO_GET_VERSION \
    CTL_CODE(FILE_DEVICE_UNKNOWN, 0x800, METHOD_BUFFERED, FILE_ANY_ACCESS)

#define IOCTL_AURAVAIO_GET_STATUS \
    CTL_CODE(FILE_DEVICE_UNKNOWN, 0x801, METHOD_BUFFERED, FILE_ANY_ACCESS)

#define IOCTL_AURAVAIO_MAP_SHARED_RING \
    CTL_CODE(FILE_DEVICE_UNKNOWN, 0x802, METHOD_BUFFERED, FILE_ANY_ACCESS)

#define IOCTL_AURAVAIO_UNMAP_SHARED_RING \
    CTL_CODE(FILE_DEVICE_UNKNOWN, 0x803, METHOD_BUFFERED, FILE_ANY_ACCESS)

#define IOCTL_AURAVAIO_GET_DEBUG_LOG \
    CTL_CODE(FILE_DEVICE_UNKNOWN, 0x804, METHOD_BUFFERED, FILE_ANY_ACCESS)

//=============================================================================
// Data Structures
//=============================================================================

#pragma pack(push, 8)

typedef struct _AURA_VAIO_VERSION_INFO {
    ULONG   DriverVersionMajor;     // e.g. 1
    ULONG   DriverVersionMinor;     // e.g. 0
    ULONG   DriverBuildNumber;      // e.g. 1
    ULONG   KmdfMajor;              // 1
    ULONG   KmdfMinor;              // 15 (modern) or 11 (legacy)
    ULONG   Track;                  // 1 = modern (Win10/11), 2 = legacy (Win7/8)
    CHAR    BuildDate[32];          // "__DATE__"
    CHAR    BuildTime[32];          // "__TIME__"
} AURA_VAIO_VERSION_INFO, *PAURA_VAIO_VERSION_INFO;

typedef struct _AURA_VAIO_STATUS_INFO {
    ULONG       ActiveRenderStreams;    // Current active render streams
    ULONG       ActiveCaptureStreams;   // Current active capture streams
    ULONG       SampleRate;             // Negotiated sample rate (e.g. 48000)
    ULONG       Channels;               // Negotiated channel count (e.g. 2, 6, 8)
    ULONG       BitsPerSample;          // Negotiated bit depth (e.g. 32)
    ULONG       BlockAlign;             // Format block align
    ULONG       RingBufferSizeBytes;    // Ring buffer size
    ULONG       MappedClientCount;      // Number of user-mode clients mapped
    ULONGLONG   TotalFramesWritten;     // Cumulative audio frames rendered
    ULONGLONG   TotalFramesRead;        // Cumulative audio frames captured
    ULONGLONG   QpcFrequency;           // Performance counter frequency
} AURA_VAIO_STATUS_INFO, *PAURA_VAIO_STATUS_INFO;

typedef struct _AURA_VAIO_MAP_REQUEST {
    ULONG   RequestedSize;          // 0 = default (64KB)
    ULONG   Flags;                  // Reserved
} AURA_VAIO_MAP_REQUEST, *PAURA_VAIO_MAP_REQUEST;

typedef struct _AURA_VAIO_MAP_RESPONSE {
    PVOID   UserAddress;            // Mapped user-mode base address
    ULONG   TotalMappedSizeBytes;   // Total size including header + payload
    ULONG   HeaderSizeBytes;        // Offset where audio data payload begins
    ULONG   DataSizeBytes;          // Payload circular buffer size
    ULONG   SampleRate;             // Audio stream sample rate
    ULONG   Channels;               // Audio channels
    ULONG   BitsPerSample;          // Bits per sample
    ULONG   BlockAlign;             // Block align
} AURA_VAIO_MAP_RESPONSE, *PAURA_VAIO_MAP_RESPONSE;

typedef struct _AURA_VAIO_UNMAP_REQUEST {
    PVOID   UserAddress;            // Pointer returned by MAP_SHARED_RING
} AURA_VAIO_UNMAP_REQUEST, *PAURA_VAIO_UNMAP_REQUEST;

//
// Circular Audio Ring Buffer Header
// Located at the beginning (offset 0) of the mapped shared memory block.
//
typedef struct _AURA_VAIO_SHARED_HEADER {
    ULONG               Magic;                  // AURA_VAIO_MAGIC_RING ('AURB')
    ULONG               Version;                // AURA_VAIO_IPC_VERSION (1)
    ULONG               HeaderSizeBytes;        // Size of this header structure
    ULONG               TotalBufferSizeBytes;   // Total size of mapped memory
    ULONG               DataOffsetBytes;        // Offset where sample data begins
    ULONG               DataSizeBytes;          // Size of circular buffer area in bytes
    ULONG               SampleRate;             // e.g. 48000
    ULONG               Channels;               // e.g. 2, 8
    ULONG               BitsPerSample;          // e.g. 32
    ULONG               BlockAlign;             // e.g. 8
    volatile ULONG      WriteOffset;            // Current write position in circular buffer [0, DataSizeBytes)
    volatile ULONG      ReadOffset;             // Current read position in circular buffer [0, DataSizeBytes)
    volatile ULONGLONG  TotalBytesWritten;      // Monotonic total bytes written by kernel
    volatile ULONGLONG  TotalBytesRead;         // Monotonic total bytes read by consumer
    volatile ULONG      StreamState;            // 0=STOP, 1=ACQUIRE, 2=PAUSE, 3=RUN
    ULONG               Reserved[15];           // Future expansion
} AURA_VAIO_SHARED_HEADER, *PAURA_VAIO_SHARED_HEADER;

typedef struct _AURA_INTERSECTION_LOG_ENTRY {
    ULONG   PinId;
    ULONG   FormatSize;
    ULONG   OutputBufferLength;
    ULONG   Status;
    ULONG   MyMaxChannels;
    ULONG   MyMaxBits;
    ULONG   MyMaxSampleRate;
    GUID    MySubFormat;
    GUID    MajorFormat;
    GUID    SubFormat;
    GUID    Specifier;
    ULONG   ExtraChannels;
    ULONG   ExtraBits;
    ULONG   ExtraSampleRate;
    ULONG   ExtraChannelMask;
    GUID    ExtraSubFormat;
} AURA_INTERSECTION_LOG_ENTRY, *PAURA_INTERSECTION_LOG_ENTRY;

typedef struct _AURA_DEBUG_LOG {
    ULONG                       Count;
    AURA_INTERSECTION_LOG_ENTRY Entries[32];
} AURA_DEBUG_LOG, *PAURA_DEBUG_LOG;

#pragma pack(pop)

#endif // _AURA_VAIO_IPC_H_
