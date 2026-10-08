/*
 * Minimal cutils/ashmem.h stub backed by memfd_create.
 * The FMQ peer (AudioFlinger) only mmaps the fd, so any
 * anonymous shared-memory fd is ABI-compatible here.
 */
#pragma once

#include <stddef.h>
#include <sys/cdefs.h>

__BEGIN_DECLS

#define ASHMEM_NAME_LEN 128

int ashmem_create_region(const char* name, size_t size);

int ashmem_set_prot_region(int fd, int prot);

__END_DECLS
