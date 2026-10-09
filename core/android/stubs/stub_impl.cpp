/*
 * Implementations for the third-party include stubs (native_handle,
 * ashmem). Compiled into libspikeeq.so with hidden visibility so no
 * symbol collides with the process-wide libcutils.so.
 */
#include <android/log.h>
#include <cutils/ashmem.h>
#include <cutils/native_handle.h>

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

/* ---------- native_handle (libcutils semantics) ---------- */

native_handle_t* native_handle_create(int numFds, int numInts) {
    if (numFds < 0 || numInts < 0 || numFds > NATIVE_HANDLE_MAX_FDS ||
        numInts > NATIVE_HANDLE_MAX_INTS) {
        return nullptr;
    }
    size_t size = sizeof(native_handle_t) + sizeof(int) * (numFds + numInts);
    native_handle_t* h = static_cast<native_handle_t*>(malloc(size));
    if (h) {
        h->version = sizeof(native_handle_t);
        h->numFds = numFds;
        h->numInts = numInts;
        for (int i = 0; i < numFds + numInts; i++) h->data[i] = 0;
    }
    return h;
}

int native_handle_delete(native_handle_t* h) {
    if (!h) return -EINVAL;
    if (h->version != sizeof(native_handle_t)) return -EINVAL;
    free(h);
    return 0;
}

int native_handle_close(const native_handle_t* h) {
    if (!h) return -EINVAL;
    if (h->version != sizeof(native_handle_t)) return -EINVAL;
    int ret = 0;
    for (int i = 0; i < h->numFds; i++) {
        if (close(h->data[i]) != 0) ret = -errno;
    }
    return ret;
}

/* ---------- ashmem shim (memfd-backed with /dev/ashmem fallback) ---------- */

#ifndef MFD_CLOEXEC
#define MFD_CLOEXEC 0x0001U
#endif
#ifndef MFD_ALLOW_SEALING
#define MFD_ALLOW_SEALING 0x0002U
#endif

#include <android/log.h>

/* classic ashmem device fallback (pre-memfd path, still present on modern kernels) */
#ifndef ASHMEM_IOCTL_MAGIC
#define ASHMEM_IOCTL_MAGIC 'A'
#endif
#define ASHMEM_SET_NAME   _IOW(ASHMEM_IOCTL_MAGIC, 1, char[ASHMEM_NAME_LEN])
#define ASHMEM_SET_SIZE   _IOW(ASHMEM_IOCTL_MAGIC, 3, size_t)
#define ASHMEM_GET_SIZE   _IO(ASHMEM_IOCTL_MAGIC, 4)

extern "C" int memfd_create(const char* name, unsigned int flags);

/* Path 3: regular file inside the audio HAL's own writable directory.
 * A MAP_SHARED mmap of a regular file is shared across processes when the
 * fd travels over binder, so it is a fully valid FMQ backing store.
 *
 * NOTE: libfmq names every queue "MessageQueue" (MessageQueueBase.h), so the
 * caller-supplied name is NOT unique across the status/in/out MQs of one
 * effect. Disambiguate with pid + a monotonic counter, and unlink right after
 * creation: the inode lives as long as any fd is open (framework mmaps the
 * fd it receives over binder), so nothing is lost and no stale files pile up
 * in the audio vendor dir (postmortem 2026-10-08: 3 MQs sharing one file
 * meant all queues aliased the same memory). */
static int file_backed_region(const char* n, size_t size) {
    static _Atomic int seq = 0;
    char path[160];
    snprintf(path, sizeof(path), "/data/vendor/audio/.spike_fmq_%d_%d_%s",
             static_cast<int>(getpid()), ++seq, n ? n : "anon");
    int fd = open(path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0644);
    if (fd < 0) {
        __android_log_print(ANDROID_LOG_WARN, "spike_stubs",
                            "open %s failed errno=%d", path, errno);
        return -1;
    }
    if (ftruncate(fd, static_cast<off_t>(size)) != 0) {
        __android_log_print(ANDROID_LOG_ERROR, "spike_stubs",
                            "ftruncate %s errno=%d", path, errno);
        close(fd);
        return -1;
    }
    /* Backing inode is now sized and fd-held; drop the directory entry so
     * repeated effect attach/detach cycles never accumulate files. */
    unlink(path);
    __android_log_print(ANDROID_LOG_INFO, "spike_stubs",
                        "ashmem_create_region(%s,%zu): file-backed fd=%d", n, size, fd);
    return fd;
}

int ashmem_create_region(const char* name, size_t size) {
    const char* n = name ? name : "spike_ashmem";

    /* 1st choice: memfd_create. This is the backing store the framework's own
     * libfmq expects (memfd fds travel over binder and are mmap'ed by
     * audioserver); a regular-file fd fails framework-side validation and
     * leaves the framework EventFlag group null ("invalid efGroup" -> silence,
     * postmortem 2026-10-08 crash1/round-2). */
    int fd = memfd_create(n, MFD_CLOEXEC | MFD_ALLOW_SEALING);
    if (fd >= 0) {
        if (ftruncate(fd, static_cast<off_t>(size)) == 0) {
            __android_log_print(ANDROID_LOG_INFO, "spike_stubs",
                                "ashmem_create_region(%s,%zu): memfd fd=%d", n, size, fd);
            return fd;
        }
        /* Oplus policy denies ftruncate on memfd (errno=13). Grow the memfd via
         * lseek+write instead — write() carries no ftruncate permission. */
        if (lseek(fd, static_cast<off_t>(size - 1), SEEK_SET) ==
                static_cast<off_t>(size - 1)) {
            char zero = 0;
            ssize_t wr = write(fd, &zero, 1);
            if (wr == 1) {
                __android_log_print(ANDROID_LOG_INFO, "spike_stubs",
                                    "ashmem_create_region(%s,%zu): memfd(lseek+write) fd=%d",
                                    n, size, fd);
                return fd;
            }
            __android_log_print(ANDROID_LOG_WARN, "spike_stubs",
                                "memfd lseek+write failed ret=%zd errno=%d", wr, errno);
        } else {
            __android_log_print(ANDROID_LOG_WARN, "spike_stubs", "memfd lseek failed errno=%d",
                                errno);
        }
        close(fd);
        fd = -1;
    }

    /* 2nd choice: legacy ashmem device */
    int dev = open("/dev/ashmem", O_RDWR | O_CLOEXEC);
    if (dev >= 0) {
        char buf[ASHMEM_NAME_LEN] = {0};
        strncpy(buf, n, sizeof(buf) - 1);
        if (ioctl(dev, ASHMEM_SET_NAME, buf) == 0 &&
            ioctl(dev, ASHMEM_SET_SIZE, size) == 0) {
            __android_log_print(ANDROID_LOG_INFO, "spike_stubs",
                                "ashmem_create_region(%s,%zu): /dev/ashmem fd=%d", n, size, dev);
            return dev;
        }
        __android_log_print(ANDROID_LOG_WARN, "spike_stubs",
                            "ashmem ioctl failed errno=%d, trying file-backed", errno);
        close(dev);
        dev = -1;
    }

    /* 3rd choice: file-backed region in the audio vendor dir */
    fd = file_backed_region(n, size);
    if (fd >= 0) return fd;

    __android_log_print(ANDROID_LOG_ERROR, "spike_stubs",
                        "ashmem_create_region(%s): all paths failed", n);
    return -1;
}

int ashmem_set_prot_region(int fd, int prot) {
    /* memfd regions are already RW; legacy ashmem prot control not critical here. */
    (void)fd;
    (void)prot;
    return 0;
}

/* ---------- liblog error-write hook (stubbed) ---------- */

extern "C" int android_errorWriteLog(int /*tag*/, const char* subTag) {
    __android_log_print(ANDROID_LOG_ERROR, "spike_stubs", "errorWriteLog: %s", subTag);
    return 0;
}
