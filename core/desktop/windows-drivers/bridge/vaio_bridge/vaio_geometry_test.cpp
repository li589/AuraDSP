// vaio_geometry_test.cpp — deterministic VAIO host geometry regressions.
// Includes the production bridge TU so the real control helpers and mirror
// behavior are exercised without a device or DLL-loading indirection.
#include <windows.h>

#include <atomic>
#include <cstdio>
#include <thread>

#include "VaioBridge.cpp"

namespace {

int g_fail = 0;
int g_pass = 0;

void Check(bool ok, const char* what, const char* detail = "") {
    std::printf("[%s] %s %s\n", ok ? "PASS" : "FAIL", what, detail);
    if (ok) ++g_pass;
    else ++g_fail;
}

HANDLE g_aEntered = nullptr;
HANDLE g_bEntered = nullptr;
HANDLE g_bStarted = nullptr;
HANDLE g_releaseA = nullptr;
std::atomic<int> g_countingRequests{0};

auradsp_status FakeGeometryRequest(void*, int32_t channels, int32_t,
                                  uint64_t* generation) {
    if (channels == 4) {
        SetEvent(g_aEntered);
        WaitForSingleObject(g_releaseA, 2000);
        *generation = 2;
    } else if (channels == 6) {
        SetEvent(g_bEntered);
        *generation = 3;
    } else {
        *generation = 1;
    }
    return AURADSP_OK;
}

auradsp_status CountingGeometryRequest(void*, int32_t channels, int32_t,
                                       uint64_t* generation) {
    ++g_countingRequests;
    *generation = channels == 4 ? 2 : 3;
    return AURADSP_OK;
}

void ResetRequestedTuple() {
    g_vaio.requestedGeometry.Reset();
    Check(g_vaio.requestedGeometry.Publish({1, 2, 0}),
          "requested geometry fixture publish");
}

void TestRequestsAreSerializedAndCannotRegress() {
    int fakeEngine = 0;
    g_vaio.pEngine = &fakeEngine;
    g_vaio.fnRequestGeometry = FakeGeometryRequest;
    ResetRequestedTuple();

    g_aEntered = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    g_bEntered = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    g_bStarted = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    g_releaseA = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    Check(g_aEntered && g_bEntered && g_bStarted && g_releaseA,
          "geometry serialization fixture events");
    if (!g_aEntered || !g_bEntered || !g_bStarted || !g_releaseA) return;

    std::thread a([&] {
        SetEngineGeometry(4, 0);
    });
    Check(WaitForSingleObject(g_aEntered, 1000) == WAIT_OBJECT_0,
          "first geometry request enters engine control call");
    std::thread b([&] {
        SetEvent(g_bStarted);
        SetEngineGeometry(6, 0);
    });
    Check(WaitForSingleObject(g_bStarted, 1000) == WAIT_OBJECT_0,
          "second geometry request started");
    const DWORD enteredWhileA =
        WaitForSingleObject(g_bEntered, 200);
    Check(enteredWhileA == WAIT_TIMEOUT,
          "second geometry request waits for first request publication");
    SetEvent(g_releaseA);
    a.join();
    b.join();

    aurahost::GeometrySnapshot finalGeometry{};
    const bool haveFinal = g_vaio.requestedGeometry.Load(&finalGeometry);
    char detail[128];
    std::snprintf(detail, sizeof(detail),
                  "generation=%llu channels=%d mode=%d",
                  (unsigned long long)finalGeometry.generation,
                  (int)finalGeometry.channels, (int)finalGeometry.mode);
    Check(haveFinal && finalGeometry.generation == 3 &&
              finalGeometry.channels == 6 && finalGeometry.mode == 0,
          "stale completion cannot regress requested geometry", detail);

    CloseHandle(g_releaseA);
    CloseHandle(g_bStarted);
    CloseHandle(g_bEntered);
    CloseHandle(g_aEntered);
    g_releaseA = g_bStarted = g_bEntered = g_aEntered = nullptr;
    g_vaio.pEngine = nullptr;
    g_vaio.fnRequestGeometry = nullptr;
}

void TestCoherentPublicationRejectsMixedAndStaleSnapshots() {
    aurahost::GeometryState state;
    Check(state.Publish({7, 4, 0}), "coherent geometry fixture publish");
    aurahost::GeometrySnapshot loaded{};
    Check(state.Load(&loaded) && loaded.generation == 7 &&
              loaded.channels == 4 && loaded.mode == 0,
          "coherent geometry loads complete tuple");

    aurahost::GeometrySnapshot rejected{99, 99, 99};
    const bool mixed = state.Load(&rejected, [&] {
        Check(state.Publish({8, 8, 1}), "interleaved newer geometry publish");
    });
    Check(!mixed && rejected.generation == 99 && rejected.channels == 99 &&
              rejected.mode == 99,
          "double-read rejects deterministic mixed generation");

    Check(!state.Publish({8, 6, 0}) && !state.Publish({7, 2, 1}),
          "equal and older generations are rejected");
    Check(state.Load(&loaded) && loaded.generation == 8 &&
              loaded.channels == 8 && loaded.mode == 1,
          "stale publication leaves requested geometry unchanged");
}

void TestPumpIntentDefersEngineRequestToWorkerStep() {
    int fakeEngine = 0;
    ResetRequestedTuple();
    g_vaio.pEngine = &fakeEngine;
    g_vaio.fnRequestGeometry = CountingGeometryRequest;
    g_vaio.countMode.store(0, std::memory_order_release);
    g_countingRequests.store(0, std::memory_order_release);

    Check(PostEngineGeometryIntent(4), "pump posts auto geometry intent");
    Check(g_countingRequests.load(std::memory_order_acquire) == 0,
          "pump intent does not enter engine control call");
    Check(ServiceEngineGeometryIntent(), "worker consumes geometry intent");
    aurahost::GeometrySnapshot requested{};
    Check(g_countingRequests.load(std::memory_order_acquire) == 1 &&
              g_vaio.requestedGeometry.Load(&requested) &&
              requested.generation == 2 && requested.channels == 4,
          "worker step publishes requested geometry coherently");

    Check(PostEngineGeometryIntent(6), "pump posts replacement intent");
    Check(ServiceEngineGeometryIntent(), "worker consumes replacement intent");
    Check(g_countingRequests.load(std::memory_order_acquire) == 2 &&
              g_vaio.requestedGeometry.Load(&requested) &&
              requested.generation == 3 && requested.channels == 6,
          "latest pump intent wins without partial geometry");
    g_vaio.pEngine = nullptr;
    g_vaio.fnRequestGeometry = nullptr;
}

void TestStoppedModeSetPreservesMirrorSuccess() {
    g_vaio.pEngine = nullptr;
    g_vaio.fnRequestGeometry = nullptr;
    InterlockedExchange(&g_vaio.running, 0);
    g_mirrorN = 0;
    const int32_t mode = 1;
    const int rc = vaio_set_param("channels.mode", 0, &mode);
    bool mirrored = false;
    for (int i = 0; i < g_mirrorN; ++i) {
        if (strcmp(g_mirror[i].id, "channels.mode") == 0 &&
            !g_mirror[i].isFloat && g_mirror[i].i == 1) {
            mirrored = true;
            break;
        }
    }
    char detail[96];
    std::snprintf(detail, sizeof(detail), "rc=%d mirrored=%d", rc, mirrored);
    Check(rc == 0 && mirrored,
          "stopped channels.mode records mirror and succeeds without engine",
          detail);
}

}  // namespace

int main() {
    std::printf("=== VAIO host geometry regressions ===\n");
    TestRequestsAreSerializedAndCannotRegress();
    TestCoherentPublicationRejectsMixedAndStaleSnapshots();
    TestPumpIntentDefersEngineRequestToWorkerStep();
    TestStoppedModeSetPreservesMirrorSuccess();
    std::printf("vaio_geometry_test: %d checks, %d failures\n",
                g_pass + g_fail, g_fail);
    return g_fail ? 1 : 0;
}
