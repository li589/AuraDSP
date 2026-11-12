// vaio_dlog_dump.cpp — dump the VAIO driver's DataRangeIntersection debug log (dev-only)
//
// Pure consumer of IOCTL_AURAVAIO_GET_DEBUG_LOG: unlike
// vaio_multichannel_probe (which runs its own format matrix first and
// thereby evicts earlier entries from the 32-entry ring), this tool
// generates NO KS traffic of its own, so it can snapshot the log right
// after another tool's negotiation (vaio_fmt_probe, vaio_set_format).
//
// Build (VS2017+ x64, from this directory):
//   cl /utf-8 /EHsc /O2 vaio_dlog_dump.cpp /link ole32.lib uuid.lib
//
// Usage: vaio_dlog_dump

#include <windows.h>
#include <cstdio>
#include "../common/AuraVaioIpc.h"

int main() {
    HANDLE h = CreateFileW(L"\\\\.\\AuraVaioControl", GENERIC_READ | GENERIC_WRITE,
                           FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                           OPEN_EXISTING, 0, nullptr);
    if (h == INVALID_HANDLE_VALUE) {
        printf("open control device failed: %lu\n", GetLastError());
        return 1;
    }
    AURA_DEBUG_LOG log = {};
    DWORD ret = 0;
    if (!DeviceIoControl(h, IOCTL_AURAVAIO_GET_DEBUG_LOG, nullptr, 0,
                         &log, sizeof(log), &ret, nullptr)) {
        printf("GET_DEBUG_LOG failed: %lu\n", GetLastError());
        CloseHandle(h);
        return 2;
    }
    printf("entries: %lu writeIndex: %lu\n", log.Count, log.WriteIndex);
    const ULONG startIdx = (log.WriteIndex - log.Count) % 32;
    for (ULONG i = 0; i < log.Count; ++i) {
        const auto& e = log.Entries[(startIdx + i) % 32];
        FILETIME ft;
        ft.dwLowDateTime = (DWORD)(e.Timestamp100ns & 0xFFFFFFFFull);
        ft.dwHighDateTime = (DWORD)(e.Timestamp100ns >> 32);
        SYSTEMTIME st = {};
        FileTimeToSystemTime(&ft, &st);
        printf("[%2lu] %02d:%02d:%02d.%03dZ Pin=%lu Status=0x%08lX FormatSize=%lu OutBufLen=%lu\n",
               i, st.wHour, st.wMinute, st.wSecond, st.wMilliseconds,
               e.PinId, e.Status, e.FormatSize, e.OutputBufferLength);
        printf("     Client: reqCh=%lu reqBits=%lu reqRate=%lu mask=0x%03lX sub={%08lX} spec={%08lX}\n",
               e.ExtraChannels, e.ExtraBits, e.ExtraSampleRate,
               e.ExtraChannelMask, e.SubFormat.Data1, e.Specifier.Data1);
        printf("     Range:  maxCh=%lu maxBits=%lu maxRate=%lu sub={%08lX}\n",
               e.MyMaxChannels, e.MyMaxBits, e.MyMaxSampleRate,
               e.MySubFormat.Data1);
    }
    CloseHandle(h);
    return 0;
}
