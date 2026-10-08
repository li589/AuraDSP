/*
 * Minimal utils/Errors.h stub: status_t + error constants matching
 * AOSP frameworks/native/include/utils/Errors.h values (namespace android).
 * Written as literals to keep them valid integral constant expressions.
 */
#pragma once

#include <stdint.h>
#include <sys/cdefs.h>

namespace android {

typedef int32_t status_t;

enum {
    OK                = 0,
    NO_ERROR          = 0,
    UNKNOWN_ERROR     = (-2147483647 - 1),  // INT32_MIN
    NO_MEMORY         = (-2147483647 - 1) + 1,
    INVALID_OPERATION = (-2147483647 - 1) + 2,
    BAD_VALUE         = (-2147483647 - 1) + 3,
    BAD_TYPE          = (-2147483647 - 1) + 4,
    BAD_INDEX         = (-2147483647 - 1) + 5,
    NOT_ENOUGH_DATA   = (-2147483647 - 1) + 6,
    WOULD_BLOCK       = (-2147483647 - 1) + 7,
    TIMED_OUT         = (-2147483647 - 1) + 8,
    UNKNOWN_TRANSACTION = (-2147483647 - 1) + 9,
    NO_INIT           = (-2147483647 - 1) + 11,
    PERMISSION_DENIED = (-2147483647 - 1) + 12,
    NAME_NOT_FOUND    = (-2147483647 - 1) + 13,
    DEAD_OBJECT       = (-2147483647 - 1) + 14,
    FDS_NOT_ALLOWED   = (-2147483647 - 1) + 15,
    ALREADY_EXISTS    = (-2147483647 - 1) + 17,
};

}  // namespace android
