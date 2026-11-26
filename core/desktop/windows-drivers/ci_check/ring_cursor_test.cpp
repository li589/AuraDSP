#include <cstdio>

#include "RingCursor.h"

int main()
{
    AURA_VAIO_SHARED_HEADER header{};
    header.WriteOffset = 1234;
    header.ReadOffset = 17;
    header.TotalBytesWritten = 9000;
    header.TotalBytesRead = 1000;

    AuraRingAnchorReadCursor(&header);

    if (header.ReadOffset != 1234)
    {
        std::fprintf(stderr, "FAIL: ReadOffset=%lu (expected 1234)\n",
                     static_cast<unsigned long>(header.ReadOffset));
        return 1;
    }
    if (header.TotalBytesRead != 9000)
    {
        std::fprintf(stderr, "FAIL: TotalBytesRead=%llu (expected 9000)\n",
                     static_cast<unsigned long long>(header.TotalBytesRead));
        return 1;
    }

    std::puts("ok: fresh mapping anchors both ring read counters");
    return 0;
}
