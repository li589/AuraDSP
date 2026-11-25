// geometry_atomic_test.cpp — pending/active 声道几何与宿主块边界回归。
// 新增 ABI 在 RED 阶段按名动态解析：旧引擎可完整编译、运行并报告缺失行为，
// 避免把链接失败误当成语义失败。
#include "auradsp_engine.h"
#include "geometry_snapshot.h"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <limits>
#include <thread>
#include <vector>

#ifdef _WIN32
#include <windows.h>
#else
#include <dlfcn.h>
#endif

namespace {

using Geometry = auradsp_geometry;

using FnRequestGeometry = auradsp_status (*)(auradsp_handle, int32_t, int32_t,
                                             uint64_t*);
using FnGetActiveGeometry = auradsp_status (*)(auradsp_handle, Geometry*);
using FnProcessGeometry = auradsp_status (*)(
    auradsp_handle, const float*, float*, int, const Geometry*);

FnRequestGeometry requestGeometry = nullptr;
FnGetActiveGeometry getActiveGeometry = nullptr;
FnProcessGeometry processGeometry = nullptr;
int failures = 0;
int checks = 0;

void Check(bool condition, const char* message) {
    ++checks;
    if (!condition) {
        ++failures;
        std::fprintf(stderr, "FAIL: %s\n", message);
    }
}

void ResolveGeometryAbi() {
#ifdef _WIN32
    const HMODULE module = GetModuleHandleW(L"auradsp_engine.dll");
    requestGeometry = module ? reinterpret_cast<FnRequestGeometry>(
        GetProcAddress(module, "auradsp_request_geometry")) : nullptr;
    getActiveGeometry = module ? reinterpret_cast<FnGetActiveGeometry>(
        GetProcAddress(module, "auradsp_get_active_geometry")) : nullptr;
    processGeometry = module ? reinterpret_cast<FnProcessGeometry>(
        GetProcAddress(module, "auradsp_process_geometry")) : nullptr;
#else
    requestGeometry = reinterpret_cast<FnRequestGeometry>(
        dlsym(RTLD_DEFAULT, "auradsp_request_geometry"));
    getActiveGeometry = reinterpret_cast<FnGetActiveGeometry>(
        dlsym(RTLD_DEFAULT, "auradsp_get_active_geometry"));
    processGeometry = reinterpret_cast<FnProcessGeometry>(
        dlsym(RTLD_DEFAULT, "auradsp_process_geometry"));
#endif
}

struct Engine {
    auradsp_handle h = auradsp_create(48000.0f, 64);
    Engine() { Check(h != nullptr, "create geometry test engine"); }
    ~Engine() { if (h) auradsp_destroy(h); }
    Engine(const Engine&) = delete;
    Engine& operator=(const Engine&) = delete;
};

bool HasGeometryAbi(const Engine& engine) {
    (void)engine;
    const bool request = requestGeometry != nullptr;
    const bool active = getActiveGeometry != nullptr;
    const bool process = processGeometry != nullptr;
    Check(request, "auradsp_request_geometry export is available");
    Check(active, "auradsp_get_active_geometry export is available");
    Check(process, "auradsp_process_geometry export is available");
    return request && active && process;
}

Geometry Active(auradsp_handle h) {
    Geometry g{0, 0, 0};
    Check(getActiveGeometry(h, &g) == AURADSP_OK,
          "read active geometry");
    return g;
}

void Process(auradsp_handle h, int32_t channels) {
    constexpr int kFrames = 16;
    std::vector<float> in(static_cast<size_t>(kFrames * channels), 0.0f);
    std::vector<float> out(in.size(), 0.0f);
    for (size_t i = 0; i < in.size(); ++i) in[i] = 0.001f;
    auradsp_process(h, in.data(), out.data(), kFrames);
}

void TestRequestIsPendingUntilProcess() {
    Engine e;
    if (!e.h || !HasGeometryAbi(e)) return;
    const Geometry initial = Active(e.h);
    Check(initial.channels == 2 && initial.mode == 0,
          "initial active geometry is stereo matrix");
    uint64_t generation = 0;
    Check(requestGeometry(e.h, 4, 1, &generation) == AURADSP_OK,
          "request valid quad discrete geometry");
    Check(generation > initial.generation, "request advances generation");
    const Geometry before = Active(e.h);
    Check(before.generation == initial.generation &&
              before.channels == initial.channels && before.mode == initial.mode,
          "setter return does not change active geometry before process");
    Process(e.h, 4);
    const Geometry after = Active(e.h);
    Check(after.generation == generation && after.channels == 4 && after.mode == 1,
          "first process block activates the complete requested geometry");
}

void TestSequentialRequestsHaveOneWidthPerBlock() {
    Engine e;
    if (!e.h || !HasGeometryAbi(e)) return;
    const int32_t widths[] = {2, 4, 6, 8};
    uint64_t previous = Active(e.h).generation;
    for (int32_t width : widths) {
        uint64_t generation = 0;
        Check(requestGeometry(e.h, width, 0, &generation) == AURADSP_OK,
              "request 2/4/6/8 geometry sequence");
        const Geometry before = Active(e.h);
        Check(before.generation == previous,
              "active generation remains stable before block boundary");
        Check(before.channels == 2 || before.channels == 4 ||
                  before.channels == 6 || before.channels == 8,
              "pre-block geometry has one legal width");
        Process(e.h, width);
        const Geometry after = Active(e.h);
        Check(after.generation == generation && after.channels == width &&
                  (after.mode == 0 || after.mode == 1),
              "post-block geometry has exactly the requested width and mode");
        Check(after.generation > previous, "active generation increases per request");
        previous = generation;
    }
}

void TestLatestRequestPublishesWholeGeometry() {
    Engine e;
    if (!e.h || !HasGeometryAbi(e)) return;
    uint64_t first = 0, second = 0;
    Check(requestGeometry(e.h, 4, 1, &first) == AURADSP_OK,
          "request first complete geometry");
    Check(requestGeometry(e.h, 6, 1, &second) == AURADSP_OK,
          "replace pending request before activation");
    Check(second > first, "replacement has a newer generation");
    Process(e.h, 6);
    const Geometry active = Active(e.h);
    Check(active.generation == second && active.channels == 6 && active.mode == 1,
          "activation never mixes channels and mode from different generations");
}

void TestInvalidRequestsKeepPendingAndActiveGeneration() {
    Engine e;
    if (!e.h || !HasGeometryAbi(e)) return;
    uint64_t valid = 0;
    Check(requestGeometry(e.h, 6, 0, &valid) == AURADSP_OK,
          "establish valid geometry generation");
    Process(e.h, 6);
    const Geometry before = Active(e.h);
    const int32_t badChannels[] = {0, 1, 3, 5, 7, 9, -2};
    for (int32_t channels : badChannels) {
        uint64_t generation = 0;
        Check(requestGeometry(e.h, channels, 0, &generation) == AURADSP_E_PARAM,
              "reject invalid channel count");
    }
    const int32_t badModes[] = {-1, 2, 99};
    for (int32_t mode : badModes) {
        uint64_t generation = 0;
        Check(requestGeometry(e.h, 2, mode, &generation) == AURADSP_E_PARAM,
              "reject invalid channel mode");
    }
    Process(e.h, 6);
    const Geometry after = Active(e.h);
    Check(after.generation == before.generation && after.channels == before.channels &&
              after.mode == before.mode,
          "invalid requests leave pending and active generation unchanged");
    uint64_t next = 0;
    Check(requestGeometry(e.h, 8, 1, &next) == AURADSP_OK,
          "valid request after invalid sequence");
    Check(next == valid + 1, "invalid requests do not consume generation values");
}

void TestLegacySetParamWrappersDeferActivation() {
    Engine e;
    if (!e.h || !HasGeometryAbi(e)) return;
    const Geometry initial = Active(e.h);
    int32_t channels = 4;
    int32_t mode = 1;
    Check(auradsp_set_param(e.h, "channels.count", &channels, sizeof(channels)) ==
              AURADSP_OK,
          "legacy channels.count setter remains source compatible");
    Check(auradsp_set_param(e.h, "channels.mode", &mode, sizeof(mode)) ==
              AURADSP_OK,
          "legacy channels.mode setter remains source compatible");
    const Geometry before = Active(e.h);
    Check(before.generation == initial.generation && before.channels == 2 &&
              before.mode == 0,
          "legacy setters only publish pending geometry");
    int32_t requested = 0;
    Check(auradsp_get_param(e.h, "channels.count", &requested, sizeof(requested)) ==
              AURADSP_OK && requested == 4,
          "legacy getter returns the latest requested channel count");
    Process(e.h, 4);
    const Geometry after = Active(e.h);
    Check(after.channels == 4 && after.mode == 1 &&
              after.generation > initial.generation,
          "legacy requests activate together at the block boundary");
}

struct HostSimulator {
    auradsp_handle h;
    uint64_t requestedGeneration = 0;
    int32_t requestedChannels = 2;
    int32_t requestedMode = 0;
    int32_t workCh = 2;

    bool SyncActiveAtBlockStart() {
        Geometry active{0, 0, 0};
        if (getActiveGeometry(h, &active) != AURADSP_OK) return false;
        if (active.generation != requestedGeneration ||
            active.channels != requestedChannels || active.mode != requestedMode)
            return false;
        workCh = active.channels;
        return true;
    }

    void Request(int32_t channels, int32_t mode) {
        const int32_t oldWork = workCh;
        if (requestGeometry(h, channels, mode, &requestedGeneration) == AURADSP_OK) {
            requestedChannels = channels;
            requestedMode = mode;
        }
        Check(workCh == oldWork, "request does not immediately publish workCh");
    }

    void RunTransitionBlock() {
        Check(!SyncActiveAtBlockStart(),
              "mismatched generation does not publish new workCh");
        // 过渡块用请求宽驱动私有 scratch 以推进引擎，但结果不发布到宿主输出。
        Process(h, requestedChannels);
    }
};

void TestHostSimulatorPublishesOnlyMatchingGeneration() {
    Engine e;
    if (!e.h || !HasGeometryAbi(e)) return;
    Geometry active = Active(e.h);
    HostSimulator host{e.h, active.generation, active.channels, active.mode,
                       active.channels};
    Check(host.SyncActiveAtBlockStart() && host.workCh == 2,
          "host initially publishes matching active stereo");

    const int32_t widths[] = {4, 6, 8, 2};
    for (int32_t width : widths) {
        const int32_t oldWork = host.workCh;
        host.Request(width, 0);
        Check(host.workCh == oldWork, "pending request retains prior workCh");
        host.RunTransitionBlock();
        Check(host.workCh == oldWork, "transition block retains prior workCh");
        Check(host.SyncActiveAtBlockStart() && host.workCh == width,
              "next block publishes only the matching active generation");
    }

    const int32_t stable = host.workCh;
    host.requestedGeneration += 1;  // 模拟失败/错代请求。
    Process(e.h, stable);
    Check(!host.SyncActiveAtBlockStart() && host.workCh == stable,
          "generation mismatch never publishes a partial host geometry");
}

class PhaseGate {
 public:
    bool WaitFor(int target) {
        constexpr int kSpins = 10000000;
        for (int i = 0; i < kSpins; ++i) {
            if (aborted_.load(std::memory_order_acquire)) return false;
            if (phase_.load(std::memory_order_acquire) >= target) return true;
            std::this_thread::yield();
        }
        Abort();
        return false;
    }
    void Advance(int phase) {
        if (!aborted_.load(std::memory_order_relaxed))
            phase_.store(phase, std::memory_order_release);
    }
    void Abort() {
        aborted_.store(true, std::memory_order_release);
        phase_.store((std::numeric_limits<int>::max)(), std::memory_order_release);
    }

 private:
    std::atomic<int> phase_{0};
    std::atomic<bool> aborted_{false};
};

void TestRequestProcessRaceCannotOverwriteExactWidthGuards() {
    Engine e;
    if (!e.h || !HasGeometryAbi(e)) return;
    constexpr int kFrames = 16;
    constexpr int kPhysicalChannels = 8;
    constexpr float kGuard = 12345.0f;
    std::vector<float> in(static_cast<size_t>(kFrames * kPhysicalChannels), 0.001f);
    std::vector<float> out(static_cast<size_t>(kFrames * kPhysicalChannels), kGuard);
    PhaseGate gate;
    Geometry expected{};
    auradsp_status processStatus = AURADSP_E_STATE;

    // Real reader/writer threads with deterministic phases: the host snapshots
    // active, then the control thread requests 8ch, then the host enters process.
    // The allocation is physically 8ch so a RED run cannot corrupt memory;
    // samples after the expected 2ch block are guard regions.
    std::thread host([&] {
        if (getActiveGeometry(e.h, &expected) != AURADSP_OK) {
            gate.Advance(1);
            (void)gate.WaitFor(2);
            gate.Advance(3);
            return;
        }
        gate.Advance(1);
        if (!gate.WaitFor(2)) {
            gate.Advance(3);
            return;
        }
        processStatus = processGeometry(
            e.h, in.data(), out.data(), kFrames, &expected);
        gate.Advance(3);
    });
    const bool hostSnapshotted = gate.WaitFor(1);
    uint64_t requestedGeneration = 0;
    const auradsp_status requestStatus = hostSnapshotted
        ? requestGeometry(e.h, 8, 1, &requestedGeneration) : AURADSP_E_STATE;
    gate.Advance(2);
    const bool hostProcessed = gate.WaitFor(3);
    host.join();

    Check(hostSnapshotted && hostProcessed,
          "request/process race reached both deterministic phases");
    Check(requestStatus == AURADSP_OK,
          "racing request publishes a newer geometry");
    Check(processStatus == AURADSP_OK,
          "expected-active block processes without consuming racing request");
    bool guardsIntact = true;
    for (int i = kFrames * expected.channels;
         i < kFrames * kPhysicalChannels; ++i) {
        if (out[static_cast<size_t>(i)] != kGuard) guardsIntact = false;
    }
    Check(guardsIntact, "request/process race cannot write beyond expected width");
    const Geometry active = Active(e.h);
    Check(active.generation == expected.generation &&
              active.channels == expected.channels && active.mode == expected.mode,
          "request/process race retains the host's expected active geometry");
}

void TestStaleExpectedGeometryFailsClosedBeforeBufferAccess() {
    Engine e;
    if (!e.h || !HasGeometryAbi(e)) return;
    const Geometry initial = Active(e.h);
    uint64_t first = 0, latest = 0;
    Check(requestGeometry(e.h, 4, 0, &first) == AURADSP_OK,
          "publish first pending geometry");
    Check(requestGeometry(e.h, 8, 1, &latest) == AURADSP_OK,
          "replace pending before stale host block");
    const Geometry stale{first, 4, 0};
    const Geometry current{latest, 8, 1};
    constexpr int kFrames = 16;
    constexpr float kGuard = 54321.0f;
    std::vector<float> in(static_cast<size_t>(kFrames * 8), 0.001f);
    std::vector<float> out(static_cast<size_t>(kFrames * 8), kGuard);

    Check(processGeometry(e.h, in.data(), out.data(), kFrames, &stale) ==
              AURADSP_E_STATE,
          "stale expected geometry is rejected before processing");
    bool untouched = true;
    for (float sample : out) {
        if (sample != kGuard) untouched = false;
    }
    Check(untouched, "rejected expected geometry leaves output untouched");
    const Geometry before = Active(e.h);
    Check(before.generation == initial.generation &&
              before.channels == initial.channels && before.mode == initial.mode,
          "rejected expected geometry does not advance active");

    Check(processGeometry(e.h, in.data(), out.data(), kFrames, &current) ==
              AURADSP_OK,
          "latest complete expected geometry can activate");
    const Geometry after = Active(e.h);
    Check(after.generation == latest && after.channels == 8 && after.mode == 1,
          "latest expected geometry activates as one complete snapshot");

    const Geometry invalid{0, 8, 1};
    Check(processGeometry(e.h, in.data(), out.data(), kFrames, &invalid) ==
              AURADSP_E_PARAM,
          "sentinel expected geometry is rejected as invalid");
    std::fill(out.begin(), out.end(), kGuard);
    Check(processGeometry(e.h, in.data(), out.data(), kFrames, nullptr) ==
              AURADSP_E_PARAM,
          "null expected geometry cannot fall back to the racy legacy entry");
    untouched = true;
    for (float sample : out) {
        if (sample != kGuard) untouched = false;
    }
    Check(untouched, "null expected geometry leaves output untouched");
}

template <typename Begin, typename Finish, typename Load>
void TestSnapshotPublicationPhases(Begin begin, Finish finish, Load load) {
    std::atomic<uint64_t> generation{7};
    std::atomic<int32_t> channels{6};
    std::atomic<int32_t> mode{0};
    PhaseGate gate;
    bool readerFinished = false;
    bool sentinelRejected = false;
    bool payloadRejected = false;
    bool complete = false;
    auradsp_detail::GeometrySnapshot snapshot{};

    std::thread reader([&] {
        if (!gate.WaitFor(1)) return;
        snapshot = {77, 77, 77};
        sentinelRejected = !load(generation, channels, mode, &snapshot) &&
            snapshot.generation == 77 && snapshot.channels == 77 && snapshot.mode == 77;
        gate.Advance(2);
        if (!gate.WaitFor(3)) return;
        snapshot = {77, 77, 77};
        payloadRejected = !load(generation, channels, mode, &snapshot) &&
            snapshot.generation == 77 && snapshot.channels == 77 && snapshot.mode == 77;
        gate.Advance(4);
        if (!gate.WaitFor(5)) return;
        snapshot = {};
        complete = load(generation, channels, mode, &snapshot) &&
            snapshot.generation == 8 && snapshot.channels == 8 && snapshot.mode == 1;
        readerFinished = true;
    });

    begin(generation);
    gate.Advance(1);
    const bool reachedPayload = gate.WaitFor(2);
    channels.store(8, std::memory_order_seq_cst);
    mode.store(1, std::memory_order_seq_cst);
    gate.Advance(3);
    const bool reachedPublish = gate.WaitFor(4);
    const bool finished = finish(generation, 8);
    gate.Advance(5);
    reader.join();

    Check(readerFinished && reachedPayload && reachedPublish,
          "writer/reader phase test completed without timeout");
    Check(sentinelRejected,
          "snapshot read rejects generation sentinel before payload writes");
    Check(payloadRejected,
          "snapshot read rejects sentinel while complete payload is prepared");
    Check(finished && complete,
          "snapshot read accepts only the final release-published generation");
}

template <typename LoadWithCallback>
void TestSnapshotMixedGenerationInterleave(LoadWithCallback load) {
    std::atomic<uint64_t> generation{7};
    std::atomic<int32_t> channels{6};
    std::atomic<int32_t> mode{0};
    PhaseGate gate;
    bool callbackCompleted = false;
    bool loaded = true;
    auradsp_detail::GeometrySnapshot snapshot{};

    std::thread reader([&] {
        loaded = load(generation, channels, mode, &snapshot, [&] {
            gate.Advance(1);
            callbackCompleted = gate.WaitFor(2);
        });
    });
    const bool interleaved = gate.WaitFor(1);
    if (interleaved) {
        auradsp_detail::begin_geometry_publication(generation);
        channels.store(8, std::memory_order_seq_cst);
        mode.store(1, std::memory_order_seq_cst);
        auradsp_detail::finish_geometry_publication(generation, 8);
    }
    gate.Advance(2);
    reader.join();

    Check(callbackCompleted, "mixed-generation reader/writer interleave completed");
    Check(!loaded,
          "snapshot rejects old generation paired with a newer payload");
    Check(snapshot.generation == 0 && snapshot.channels == 0 && snapshot.mode == 0,
          "rejected snapshot cannot expose mixed geometry");
}

void TestPendingSnapshotWriterReaderPhases() {
    TestSnapshotPublicationPhases(
        [](std::atomic<uint64_t>& g) {
            auradsp_detail::begin_geometry_publication(g);
        },
        [](std::atomic<uint64_t>& g, uint64_t next) {
            return auradsp_detail::finish_geometry_publication(g, next);
        },
        [](const std::atomic<uint64_t>& g, const std::atomic<int32_t>& ch,
           const std::atomic<int32_t>& mode,
           auradsp_detail::GeometrySnapshot* out) {
            return auradsp_detail::load_pending_geometry_snapshot(
                g, ch, mode, out);
        });
    TestSnapshotMixedGenerationInterleave(
        [](const std::atomic<uint64_t>& g, const std::atomic<int32_t>& ch,
           const std::atomic<int32_t>& mode,
           auradsp_detail::GeometrySnapshot* out, auto&& after_generation) {
            return auradsp_detail::load_pending_geometry_snapshot(
                g, ch, mode, out,
                std::forward<decltype(after_generation)>(after_generation));
        });
}

void TestActiveSnapshotWriterReaderPhases() {
    TestSnapshotPublicationPhases(
        [](std::atomic<uint64_t>& g) {
            auradsp_detail::begin_geometry_publication(g);
        },
        [](std::atomic<uint64_t>& g, uint64_t next) {
            return auradsp_detail::finish_geometry_publication(g, next);
        },
        [](const std::atomic<uint64_t>& g, const std::atomic<int32_t>& ch,
           const std::atomic<int32_t>& mode,
           auradsp_detail::GeometrySnapshot* out) {
            return auradsp_detail::load_active_geometry_snapshot(
                g, ch, mode, out);
        });
    TestSnapshotMixedGenerationInterleave(
        [](const std::atomic<uint64_t>& g, const std::atomic<int32_t>& ch,
           const std::atomic<int32_t>& mode,
           auradsp_detail::GeometrySnapshot* out, auto&& after_generation) {
            return auradsp_detail::load_active_geometry_snapshot(
                g, ch, mode, out,
                std::forward<decltype(after_generation)>(after_generation));
        });
}

void TestGenerationTaggedResetClaimCannotLoseNewerReset() {
    std::atomic<uint64_t> reset{8};
    Check(!auradsp_detail::claim_geometry_reset(reset, 7) &&
              reset.load(std::memory_order_seq_cst) == 8,
          "reset for a future generation is restored, not consumed early");

    reset.store(7, std::memory_order_seq_cst);
    Check(auradsp_detail::claim_geometry_reset(reset, 7) &&
              reset.load(std::memory_order_seq_cst) == 0,
          "reset for the active generation is consumed exactly once");

    reset.store(8, std::memory_order_seq_cst);
    const bool claimed = auradsp_detail::claim_geometry_reset(reset, 7, [&] {
        // Deterministic new request landing after the old reset was claimed.
        reset.store(9, std::memory_order_seq_cst);
    });
    Check(!claimed && reset.load(std::memory_order_seq_cst) == 9,
          "restoring a stale reset cannot overwrite a newer generation reset");
}

void TestGenerationExhaustionFailsClosed() {
    uint64_t next = 123;
    Check(!auradsp_detail::next_geometry_generation(0, &next) && next == 123,
          "sentinel generation cannot be incremented");
    Check(!auradsp_detail::next_geometry_generation(
              (std::numeric_limits<uint64_t>::max)(), &next) && next == 123,
          "generation exhaustion fails closed without wrapping");
    Check(auradsp_detail::next_geometry_generation(
              (std::numeric_limits<uint64_t>::max)() - 1, &next) &&
              next == (std::numeric_limits<uint64_t>::max)(),
          "last usable generation is published without wrap");
}

using TestFn = void (*)();

}  // namespace

int main() {
    ResolveGeometryAbi();
    const TestFn tests[] = {
        TestRequestIsPendingUntilProcess,
        TestSequentialRequestsHaveOneWidthPerBlock,
        TestLatestRequestPublishesWholeGeometry,
        TestInvalidRequestsKeepPendingAndActiveGeneration,
        TestLegacySetParamWrappersDeferActivation,
        TestHostSimulatorPublishesOnlyMatchingGeneration,
        TestRequestProcessRaceCannotOverwriteExactWidthGuards,
        TestStaleExpectedGeometryFailsClosedBeforeBufferAccess,
        TestPendingSnapshotWriterReaderPhases,
        TestActiveSnapshotWriterReaderPhases,
        TestGenerationTaggedResetClaimCannotLoseNewerReset,
        TestGenerationExhaustionFailsClosed,
    };
    for (TestFn test : tests) test();
    std::fprintf(stderr, "geometry_atomic_test: %d checks, %d failures\n",
                 checks, failures);
    return failures == 0 ? 0 : 1;
}
