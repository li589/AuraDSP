/*
 * Minimal android-base/unique_fd.h stub: RAII fd wrapper with the
 * small subset of the libbase API used by libfmq.
 */
#pragma once

#include <fcntl.h>
#include <unistd.h>

namespace android {
namespace base {

class unique_fd {
public:
    unique_fd() : value_(-1) {}
    explicit unique_fd(int value) : value_(value) {}
    unique_fd(unique_fd&& other) : value_(other.release()) {}
    unique_fd& operator=(unique_fd&& other) {
        reset(other.release());
        return *this;
    }
    unique_fd(const unique_fd&) = delete;
    unique_fd& operator=(const unique_fd&) = delete;
    ~unique_fd() { reset(); }

    bool ok() const { return value_ >= 0; }
    int get() const { return value_; }
    int release() __attribute__((warn_unused_result)) {
        int ret = value_;
        value_ = -1;
        return ret;
    }
    void reset(int new_value = -1) {
        if (value_ >= 0 && value_ != new_value) close(value_);
        value_ = new_value;
    }

    friend bool operator==(const unique_fd& a, int b) { return a.value_ == b; }
    friend bool operator!=(const unique_fd& a, int b) { return a.value_ != b; }
    friend bool operator==(int a, const unique_fd& b) { return a == b.value_; }
    friend bool operator!=(int a, const unique_fd& b) { return a != b.value_; }

private:
    int value_;
};

}  // namespace base
}  // namespace android
