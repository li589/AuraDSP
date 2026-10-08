/*
 * Minimal utils/SystemClock.h stub: elapsedRealtimeNano via
 * CLOCK_BOOTTIME (semantically identical to AOSP elapsedRealtimeNano).
 */
#pragma once

#include <time.h>
#include <sys/cdefs.h>

namespace android {

inline int64_t elapsedRealtimeNano() {
    struct timespec ts;
    clock_gettime(CLOCK_BOOTTIME, &ts);
    return static_cast<int64_t>(ts.tv_sec) * 1000000000LL + ts.tv_nsec;
}

}  // namespace android
