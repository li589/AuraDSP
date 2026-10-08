/*
 * Minimal native_handle.h stub (headers-only ABI-compatible with
 * AOSP libcutils) for the JamesDSP spike effect library.
 * The implementation lives in stub_impl.cpp and is compiled into
 * our .so with hidden visibility, so it never collides with the
 * process-wide libcutils.so.
 */
#pragma once

#include <stddef.h>
#include <sys/cdefs.h>

__BEGIN_DECLS

typedef struct native_handle {
    int version;        /* sizeof(native_handle_t) */
    int numFds;         /* number of file-descriptors at &data[0] */
    int numInts;        /* number of ints at (&data[numFds]) */
    int data[];         /* numFds + numInts ints */
} native_handle_t;

#define NATIVE_HANDLE_MAX_FDS 1024
#define NATIVE_HANDLE_MAX_INTS 1024

native_handle_t* native_handle_create(int numFds, int numInts);

int native_handle_delete(native_handle_t* h);

int native_handle_close(const native_handle_t* h);

__END_DECLS
