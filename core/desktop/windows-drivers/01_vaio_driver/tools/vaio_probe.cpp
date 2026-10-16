/*++

Module Name:

    vaio_probe.cpp

Abstract:

    AuraVAIO Driver Probe & Zero-Copy Shared Ring Buffer Verification Tool.
    
    Verifies IOCTL interface (\\.\AuraVaioControl), queries driver version
    and runtime status, tests shared ring buffer memory mapping, and
    performs live render/capture waveform monitoring.

--*/

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <winioctl.h>
#include <stdio.h>
#include <stdlib.h>
#include <math.h>

#include "../../common/AuraVaioIpc.h"

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

static void PrintUsage(const char* exe)
{
    printf("AuraVAIO Probe & IPC Verification Utility\n");
    printf("Usage:\n");
    printf("  %s                   - Run full smoke test (version, status, map/unmap)\n", exe);
    printf("  %s --status          - Query and display current driver status\n", exe);
    printf("  %s --monitor <sec>   - Monitor stream status continuously\n", exe);
    printf("  %s --read <sec>      - Map shared ring and monitor live audio levels\n", exe);
    printf("  %s --feed <sec> [Hz] - Feed synthetic sine wave into ring (for capture testing)\n", exe);
}

int main(int argc, char* argv[])
{
    bool doSmokeTest = true;
    bool doStatus    = false;
    bool doMonitor   = false;
    bool doRead      = false;
    bool doFeed      = false;
    int durationSec  = 3;
    float feedHz     = 440.0f;

    if (argc > 1)
    {
        doSmokeTest = false;
        if (_stricmp(argv[1], "--status") == 0)
        {
            doStatus = true;
        }
        else if (_stricmp(argv[1], "--monitor") == 0)
        {
            doMonitor = true;
            if (argc > 2) durationSec = atoi(argv[2]);
        }
        else if (_stricmp(argv[1], "--read") == 0)
        {
            doRead = true;
            if (argc > 2) durationSec = atoi(argv[2]);
        }
        else if (_stricmp(argv[1], "--feed") == 0)
        {
            doFeed = true;
            if (argc > 2) durationSec = atoi(argv[2]);
            if (argc > 3) feedHz = (float)atof(argv[3]);
        }
        else
        {
            PrintUsage(argv[0]);
            return 1;
        }
    }

    printf("[VAIO_PROBE] Opening control device: %ls ...\n", AURA_VAIO_USER_DEVICE_PATH);
    HANDLE hDevice = CreateFileW(
        AURA_VAIO_USER_DEVICE_PATH,
        GENERIC_READ | GENERIC_WRITE,
        FILE_SHARE_READ | FILE_SHARE_WRITE,
        NULL,
        OPEN_EXISTING,
        FILE_ATTRIBUTE_NORMAL,
        NULL
    );

    if (hDevice == INVALID_HANDLE_VALUE)
    {
        DWORD err = GetLastError();
        printf("[VAIO_PROBE] ERROR: Failed to open %ls (error %lu)\n", AURA_VAIO_USER_DEVICE_PATH, err);
        if (err == ERROR_FILE_NOT_FOUND)
        {
            printf("[VAIO_PROBE] Hint: Is AuraVaioDriver installed and running?\n");
        }
        else if (err == ERROR_ACCESS_DENIED)
        {
            printf("[VAIO_PROBE] Hint: Access denied. Check DACL permissions.\n");
        }
        return 1;
    }

    printf("[VAIO_PROBE] Successfully opened control device handle: %p\n", hDevice);

    // 1. Query Version
    AURA_VAIO_VERSION_INFO verInfo = {0};
    DWORD bytesReturned = 0;
    BOOL ok = DeviceIoControl(
        hDevice,
        IOCTL_AURAVAIO_GET_VERSION,
        NULL, 0,
        &verInfo, sizeof(verInfo),
        &bytesReturned,
        NULL
    );

    if (!ok)
    {
        printf("[VAIO_PROBE] ERROR: IOCTL_AURAVAIO_GET_VERSION failed (error %lu)\n", GetLastError());
        CloseHandle(hDevice);
        return 1;
    }

    printf("[VAIO_PROBE] Driver Version: %lu.%lu (Build %lu)\n",
           verInfo.DriverVersionMajor, verInfo.DriverVersionMinor, verInfo.DriverBuildNumber);
    printf("[VAIO_PROBE] KMDF: %lu.%lu, Track: %s, Built: %s %s\n",
           verInfo.KmdfMajor, verInfo.KmdfMinor,
           (verInfo.Track == 1) ? "Modern (KMDF 1.15)" : "Legacy (KMDF 1.11)",
           verInfo.BuildDate, verInfo.BuildTime);

    // 2. Query Status
    AURA_VAIO_STATUS_INFO statusInfo = {0};
    ok = DeviceIoControl(
        hDevice,
        IOCTL_AURAVAIO_GET_STATUS,
        NULL, 0,
        &statusInfo, sizeof(statusInfo),
        &bytesReturned,
        NULL
    );

    if (!ok)
    {
        printf("[VAIO_PROBE] ERROR: IOCTL_AURAVAIO_GET_STATUS failed (error %lu)\n", GetLastError());
        CloseHandle(hDevice);
        return 1;
    }

    printf("[VAIO_PROBE] Status:\n");
    printf("  Active Render Streams : %lu\n", statusInfo.ActiveRenderStreams);
    printf("  Active Capture Streams: %lu\n", statusInfo.ActiveCaptureStreams);
    printf("  Negotiated Format     : %lu Hz, %lu ch, %lu bits (blockAlign %lu)\n",
           statusInfo.SampleRate, statusInfo.Channels, statusInfo.BitsPerSample, statusInfo.BlockAlign);
    printf("  Shared Ring Buffer    : %lu bytes\n", statusInfo.RingBufferSizeBytes);
    printf("  Mapped Client Count   : %lu\n", statusInfo.MappedClientCount);
    printf("  Total Frames Written  : %llu\n", (unsigned long long)statusInfo.TotalFramesWritten);
    printf("  Total Frames Read     : %llu\n", (unsigned long long)statusInfo.TotalFramesRead);

    if (doStatus)
    {
        CloseHandle(hDevice);
        return 0;
    }

    if (doMonitor)
    {
        printf("[VAIO_PROBE] Monitoring for %d seconds (Ctrl+C to stop)...\n", durationSec);
        int iterations = durationSec * 5;
        for (int i = 0; i < iterations; ++i)
        {
            Sleep(200);
            ok = DeviceIoControl(
                hDevice,
                IOCTL_AURAVAIO_GET_STATUS,
                NULL, 0,
                &statusInfo, sizeof(statusInfo),
                &bytesReturned,
                NULL
            );
            if (ok)
            {
                printf("  [+%3.1fs] Render: %lu, Capture: %lu, WFrames: %llu, RFrames: %llu\r",
                       (i + 1) * 0.2f,
                       statusInfo.ActiveRenderStreams,
                       statusInfo.ActiveCaptureStreams,
                       (unsigned long long)statusInfo.TotalFramesWritten,
                       (unsigned long long)statusInfo.TotalFramesRead);
                fflush(stdout);
            }
        }
        printf("\n[VAIO_PROBE] Monitoring complete.\n");
        CloseHandle(hDevice);
        return 0;
    }

    // 3. Map shared ring buffer
    printf("[VAIO_PROBE] Mapping shared circular ring buffer...\n");
    AURA_VAIO_MAP_REQUEST mapReq = {0};
    AURA_VAIO_MAP_RESPONSE mapResp = {0};

    ok = DeviceIoControl(
        hDevice,
        IOCTL_AURAVAIO_MAP_SHARED_RING,
        &mapReq, sizeof(mapReq),
        &mapResp, sizeof(mapResp),
        &bytesReturned,
        NULL
    );

    if (!ok)
    {
        printf("[VAIO_PROBE] ERROR: IOCTL_AURAVAIO_MAP_SHARED_RING failed (error %lu)\n", GetLastError());
        CloseHandle(hDevice);
        return 1;
    }

    printf("[VAIO_PROBE] Successfully mapped shared ring:\n");
    printf("  User Virtual Address : %p\n", mapResp.UserAddress);
    printf("  Total Size           : %lu bytes\n", mapResp.TotalMappedSizeBytes);
    printf("  Header Size          : %lu bytes\n", mapResp.HeaderSizeBytes);
    printf("  Data Size            : %lu bytes\n", mapResp.DataSizeBytes);

    volatile PAURA_VAIO_SHARED_HEADER pHeader = (volatile PAURA_VAIO_SHARED_HEADER)mapResp.UserAddress;
    if (pHeader->Magic != AURA_VAIO_MAGIC_RING)
    {
        printf("[VAIO_PROBE] ERROR: Invalid magic 0x%08X (expected 0x%08X)\n",
               pHeader->Magic, AURA_VAIO_MAGIC_RING);
    }
    else
    {
        printf("[VAIO_PROBE] Magic verification passed ('AURB', Version %lu)\n", pHeader->Version);
    }

    if (doRead)
    {
        printf("[VAIO_PROBE] Monitoring shared ring audio payload for %d seconds...\n", durationSec);
        BYTE* pPayload = (BYTE*)mapResp.UserAddress + pHeader->DataOffsetBytes;
        ULONG dataSize = pHeader->DataSizeBytes;

        int iterations = durationSec * 10;
        for (int i = 0; i < iterations; ++i)
        {
            Sleep(100);
            ULONG bits = pHeader->BitsPerSample ? pHeader->BitsPerSample : 32;

            float peak = 0.0f;
            float sumSq = 0.0f;
            int sampleCount = 0;

            if (bits == 32)
            {
                const float* pFloats = (const float*)pPayload;
                int nFloats = (int)(dataSize / sizeof(float));
                for (int s = 0; s < nFloats && s < 2048; ++s)
                {
                    float val = fabsf(pFloats[s]);
                    if (val > peak) peak = val;
                    sumSq += val * val;
                    sampleCount++;
                }
            }
            else if (bits == 16)
            {
                const short* pShorts = (const short*)pPayload;
                int nShorts = (int)(dataSize / sizeof(short));
                for (int s = 0; s < nShorts && s < 2048; ++s)
                {
                    float val = fabsf((float)pShorts[s] / 32768.0f);
                    if (val > peak) peak = val;
                    sumSq += val * val;
                    sampleCount++;
                }
            }

            float rms = sampleCount > 0 ? sqrtf(sumSq / sampleCount) : 0.0f;
            float peakDb = peak > 1e-5f ? 20.0f * log10f(peak) : -96.0f;
            float rmsDb  = rms > 1e-5f ? 20.0f * log10f(rms) : -96.0f;

            printf("  [+%3.1fs] WOff: %6lu, ROff: %6lu | Peak: %6.1f dB, RMS: %6.1f dB | WTotal: %llu\r",
                   (i + 1) * 0.1f,
                   pHeader->WriteOffset,
                   pHeader->ReadOffset,
                   peakDb, rmsDb,
                   (unsigned long long)pHeader->TotalBytesWritten);
            fflush(stdout);
        }
        printf("\n[VAIO_PROBE] Read complete.\n");
    }

    if (doFeed)
    {
        printf("[VAIO_PROBE] Feeding %5.1f Hz sine wave into shared ring for %d seconds...\n", feedHz, durationSec);
        BYTE* pPayload = (BYTE*)mapResp.UserAddress + pHeader->DataOffsetBytes;
        ULONG dataSize = pHeader->DataSizeBytes;
        ULONG sampleRate = pHeader->SampleRate ? pHeader->SampleRate : 48000;
        ULONG channels = pHeader->Channels ? pHeader->Channels : 2;

        float phase = 0.0f;
        float phaseInc = 2.0f * (float)M_PI * feedHz / (float)sampleRate;

        int iterations = durationSec * 20;
        ULONG frameBytes = channels * sizeof(float);
        ULONG chunkSizeFrames = sampleRate / 20; // 50ms chunks
        ULONG chunkBytes = chunkSizeFrames * frameBytes;

        for (int i = 0; i < iterations; ++i)
        {
            ULONG writeOff = pHeader->WriteOffset % dataSize;
            for (ULONG f = 0; f < chunkSizeFrames; ++f)
            {
                float sampleVal = 0.5f * sinf(phase);
                phase += phaseInc;
                if (phase >= 2.0f * (float)M_PI) phase -= 2.0f * (float)M_PI;

                for (ULONG ch = 0; ch < channels; ++ch)
                {
                    ULONG offset = (writeOff + (f * channels + ch) * sizeof(float)) % dataSize;
                    *(float*)(pPayload + offset) = sampleVal;
                }
            }
            pHeader->WriteOffset = (writeOff + chunkBytes) % dataSize;
            pHeader->TotalBytesWritten += chunkBytes;
            Sleep(50);
            printf("  [+%3.1fs] Fed %llu bytes to ring\r", (i + 1) * 0.05f, (unsigned long long)pHeader->TotalBytesWritten);
            fflush(stdout);
        }
        printf("\n[VAIO_PROBE] Feed complete.\n");
    }

    // 4. Unmap shared ring buffer
    printf("[VAIO_PROBE] Unmapping shared ring buffer...\n");
    AURA_VAIO_UNMAP_REQUEST unmapReq = {0};
    unmapReq.UserAddress = mapResp.UserAddress;
    ok = DeviceIoControl(
        hDevice,
        IOCTL_AURAVAIO_UNMAP_SHARED_RING,
        &unmapReq, sizeof(unmapReq),
        NULL, 0,
        &bytesReturned,
        NULL
    );

    if (!ok)
    {
        printf("[VAIO_PROBE] ERROR: IOCTL_AURAVAIO_UNMAP_SHARED_RING failed (error %lu)\n", GetLastError());
    }
    else
    {
        printf("[VAIO_PROBE] Successfully unmapped shared ring buffer.\n");
    }

    CloseHandle(hDevice);
    printf("[VAIO_PROBE] SUCCESS: All probe checks passed.\n");
    return 0;
}
