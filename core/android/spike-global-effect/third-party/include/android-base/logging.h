/*
 * Minimal android-base/logging.h stub: stream-style LOG(LEVEL) macros
 * forwarded to liblog (__android_log_print). Only the subset used by
 * libfmq / AOSP effect code is provided.
 */
#pragma once

#include <android/log.h>
#include <sstream>

#ifndef LOG_TAG
#define LOG_TAG "spike_effect"
#endif

#define SPIKE_LOG(prio, tag, fmt, ...) \
    __android_log_print(prio, tag, fmt, ##__VA_ARGS__)

namespace android {
namespace base {

// Simple replacement for libbase LogSeverity stream objects.
class LogStream {
public:
    explicit LogStream(android_LogPriority prio, const char* tag)
        : prio_(prio), tag_(tag) {}
    ~LogStream() {
        const std::string s = oss_.str();
        if (!s.empty()) __android_log_print(prio_, tag_, "%s", s.c_str());
    }
    LogStream(const LogStream&) = delete;
    LogStream& operator=(const LogStream&) = delete;

    template <typename T>
    LogStream& operator<<(const T& v) {
        oss_ << v;
        return *this;
    }

private:
    android_LogPriority prio_;
    const char* tag_;
    std::ostringstream oss_;
};

// CHECK / DCHECK equivalents (libbase subset used by libfmq).
// Stream-style: CHECK(exp) << "message"; aborts on failure.
class CheckStream {
public:
    CheckStream(bool ok, const char* file, int line, const char* what)
        : ok_(ok), file_(file), line_(line), what_(what) {}
    ~CheckStream() {
        if (!ok_) {
            __android_log_print(ANDROID_LOG_FATAL, "spike_check", "%s:%d CHECK failed: %s %s",
                                file_, line_, what_, oss_.str().c_str());
            abort();
        }
    }
    CheckStream(const CheckStream&) = delete;
    CheckStream& operator=(const CheckStream&) = delete;

    template <typename T>
    CheckStream& operator<<(const T& v) {
        if (!ok_) oss_ << v;
        return *this;
    }

private:
    bool ok_;
    const char* file_;
    int line_;
    const char* what_;
    std::ostringstream oss_;
};

}  // namespace base
}  // namespace android

// liblog error-report hook (upstream: log/log.h); stubbed to plain log here.
extern "C" int android_errorWriteLog(int tag, const char* subTag);

#define CHECK(exp) \
    android::base::CheckStream(static_cast<bool>(exp), __FILE__, __LINE__, #exp)

#define LOG(severity)                                                            \
    android::base::LogStream(                                                    \
        ((#severity) == std::string("ERROR"))   ? ANDROID_LOG_ERROR             \
        : ((#severity) == std::string("WARNING")) ? ANDROID_LOG_WARN             \
        : ((#severity) == std::string("INFO"))  ? ANDROID_LOG_INFO              \
        : ((#severity) == std::string("FATAL")) ? ANDROID_LOG_FATAL             \
                                                : ANDROID_LOG_DEBUG,            \
        LOG_TAG)
