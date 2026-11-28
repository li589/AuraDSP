#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <windows.h>
#else
#include <unistd.h>
#endif

#include "legacy/cpthread.h"
#include "legacy/jdsp/jdsp_header.h"

static void FillAxis(double* freq, double* gain) {
    for (int i = 0; i < NUMPTS; ++i) {
        freq[i] = 20.0 * pow(1000.0, (double)i / (NUMPTS - 1));
        gain[i] = 0.0;
    }
}

static int RunFrozenUpdate(void) {
    JamesDSPGlobalMemoryAllocation();
    JamesDSPLib* jdsp = (JamesDSPLib*)calloc(1, sizeof(JamesDSPLib));
    if (!jdsp) return 1;
    const int rc = JamesDSPInit(jdsp, 256, 48000.0f);
    if (rc != 1) {
        free(jdsp);
        JamesDSPGlobalMemoryDeallocation();
        return 1;
    }
    double freq[NUMPTS], gain[NUMPTS];
    FillAxis(freq, gain);
    MultimodalEqualizerAxisInterpolation(jdsp, 0, 0, freq, gain);
    FFTConvolver2x2* first = jdsp->mEQ.activeConv;
    gain[7] = 3.0;
    MultimodalEqualizerAxisInterpolation(jdsp, 0, 0, freq, gain);
    const int changed = jdsp->mEQ.activeConv != first;
    JamesDSPFree(jdsp);
    free(jdsp);
    JamesDSPGlobalMemoryDeallocation();
    if (!changed) {
        fprintf(stderr, "FAIL: frozen second EQ refresh was silently lost\n");
        return 1;
    }
    puts("multimodal EQ frozen updates: both committed");
    return 0;
}

static volatile long g_stop = 0;
static volatile long g_started = 0;
static volatile long g_failed = 0;

static long TestLoad(volatile long* value) {
#ifdef _WIN32
    return _InterlockedCompareExchange(value, 0, 0);
#else
    return __atomic_load_n(value, __ATOMIC_SEQ_CST);
#endif
}

static void TestStore(volatile long* value, long next) {
#ifdef _WIN32
    _InterlockedExchange(value, next);
#else
    __atomic_store_n(value, next, __ATOMIC_SEQ_CST);
#endif
}

static void* ProcessLoop(void* arg) {
    JamesDSPLib* jdsp = (JamesDSPLib*)arg;
    TestStore(&g_started, 1);
    while (!TestLoad(&g_stop)) {
        MultimodalEqualizerProcess(jdsp, 256);
        for (int i = 0; i < 256; ++i) {
            if (!isfinite(jdsp->tmpBuffer[0][i]) ||
                !isfinite(jdsp->tmpBuffer[1][i])) {
                TestStore(&g_stop, 1);
                TestStore(&g_failed, 1);
                break;
            }
        }
    }
    return NULL;
}

static int RunRefreshRace(void) {
    JamesDSPGlobalMemoryAllocation();
    JamesDSPLib* jdsp = (JamesDSPLib*)calloc(1, sizeof(JamesDSPLib));
    if (!jdsp) return 1;
    const int rc = JamesDSPInit(jdsp, 256, 48000.0f);
    if (rc != 1) {
        free(jdsp);
        JamesDSPGlobalMemoryDeallocation();
        return 1;
    }
    double freq[NUMPTS], gain[NUMPTS];
    FillAxis(freq, gain);
    MultimodalEqualizerAxisInterpolation(jdsp, 0, 0, freq, gain);
    MultimodalEqualizerEnable(jdsp, 1);
    memset(jdsp->tmpBuffer[0], 0, 256 * sizeof(float));
    memset(jdsp->tmpBuffer[1], 0, 256 * sizeof(float));
    TestStore(&g_stop, 0);
    TestStore(&g_started, 0);
    TestStore(&g_failed, 0);
    pthread_t thread;
    if (pthread_create(&thread, NULL, ProcessLoop, jdsp) != 0) {
        JamesDSPFree(jdsp);
        free(jdsp);
        JamesDSPGlobalMemoryDeallocation();
        return 1;
    }
    while (!TestLoad(&g_started)) {
#ifdef _WIN32
        Sleep(0);
#else
        sched_yield();
#endif
    }
#ifdef _WIN32
    Sleep(1);
#else
    usleep(1000);
#endif
    for (int i = 0; i < 1000; ++i) {
        gain[7] = (i & 1) ? 3.0 : -3.0;
        jdsp->equalizerForceRefresh = 1;
        MultimodalEqualizerEnable(jdsp, 1);
    }
    TestStore(&g_stop, 1);
    pthread_join(thread, NULL);
    FFTConvolver2x2* beforeFinalRefresh = jdsp->mEQ.activeConv;
    jdsp->equalizerForceRefresh = 1;
    MultimodalEqualizerEnable(jdsp, 1);
    const int committed = jdsp->mEQ.activeConv != beforeFinalRefresh &&
                          jdsp->equalizerForceRefresh == 0;
    const int failed = TestLoad(&g_failed);
    JamesDSPFree(jdsp);
    free(jdsp);
    JamesDSPGlobalMemoryDeallocation();
    if (failed || !committed) {
        fprintf(stderr, "FAIL: EQ refresh race output=%s final-commit=%s\n",
                failed ? "non-finite" : "finite", committed ? "ok" : "lost");
        return 1;
    }
    puts("multimodal EQ refresh race: completed without invalid output");
    return 0;
}

int main(int argc, char** argv) {
    const char* mode = (argc > 1) ? argv[1] : "frozen";
    if (strcmp(mode, "race") == 0) return RunRefreshRace();
    return RunFrozenUpdate();
}
