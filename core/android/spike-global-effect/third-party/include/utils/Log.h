/*
 * Minimal utils/Log.h stub: ALOGx macros forwarded to liblog.
 * (Upstream pulls in log/log.h; NDK sysroot provides android/log.h.)
 */
#pragma once

#include <android/log.h>

#ifndef LOG_TAG
#define LOG_TAG "spike_effect"
#endif

#ifndef ALOGD
#define ALOGD(...) __android_log_print(ANDROID_LOG_DEBUG, LOG_TAG, __VA_ARGS__)
#endif
#ifndef ALOGI
#define ALOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#endif
#ifndef ALOGW
#define ALOGW(...) __android_log_print(ANDROID_LOG_WARN, LOG_TAG, __VA_ARGS__)
#endif
#ifndef ALOGE
#define ALOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)
#endif
