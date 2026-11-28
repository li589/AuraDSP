#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <stddef.h>
#include <math.h>
#include <time.h>
#include <float.h>
#include "legacy/jdsp/Effects/eel2/dr_flac.h"
#include "legacy/jdsp/Effects/eel2/ns-eel.h"
#include "legacy/jdsp/jdsp_header.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int check_recursive_mutex(void)
{
    pthread_mutex_t mutex;
    if (aura_mutex_init_recursive(&mutex) != 0) return 1;
    if (pthread_mutex_lock(&mutex) != 0) return 2;
    if (pthread_mutex_lock(&mutex) != 0) return 3;
    if (pthread_mutex_unlock(&mutex) != 0) return 4;
    if (pthread_mutex_unlock(&mutex) != 0) return 5;
    if (pthread_mutex_destroy(&mutex) != 0) return 6;
    return 0;
}

static int check_sample_rate_and_free(void)
{
    JamesDSPLib *lib = (JamesDSPLib *)calloc(1, sizeof(JamesDSPLib));
    if (!lib) return 9;
    JamesDSPGlobalMemoryAllocation();
    if (!JamesDSPInit(lib, 256, 48000.0f))
    {
        free(lib);
        JamesDSPGlobalMemoryDeallocation();
        return 10;
    }
    JamesDSPSetSampleRate(lib, 44100.0f, 1);
    JamesDSPFree(lib);
    free(lib);
    JamesDSPGlobalMemoryDeallocation();
    return 0;
}

int main(int argc, char **argv)
{
    if (argc != 2) return 2;
    int rc;
    if (strcmp(argv[1], "recursive") == 0)
        rc = check_recursive_mutex();
    else
        rc = check_sample_rate_and_free();
    if (rc != 0)
    {
        fprintf(stderr, "legacy mutex case failed: %d\n", rc);
        return 1;
    }
    printf("legacy mutex %s: passed\n", argv[1]);
    return 0;
}
