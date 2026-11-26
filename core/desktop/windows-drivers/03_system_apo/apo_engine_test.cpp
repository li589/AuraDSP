// apo_engine_test.cpp — System APO 真处理端到端冒烟（设计 P4/D10）
//
// 不进 audiodg：进程内 COM 直驱 CAuraApo（DllGetClassObject 路
// 径，同 apo_selftest），但验证的是 v2 真处理全链：
//   锁定 → 座位被本进程抢到（telemetry）→ 基线块（默认参数）
//   → 经参数块发布 input.gain=-12dB（扮演 App 发布者，seqlock
//   协议）→ 输出 RMS 相对基线跌到 ~0.25（决定性断言：参数通
//   道 + worker 应用 + 引擎真处理三段同时成立才可能）→
//   telemetry 的 paramsApplied/updateSeq/spectrum 均在动 →
//   增益恢复 0dB 后经插件块装 probe_gain.clap（Part I Q2）：
//   telemetry v3 loaded=1、处理比率 ~0.5、块内旁路回 ~1.0、
//   身份清空卸载 → INPLACE 同址处理同样成立 → 解锁后座位释放。
// Global\ 需 SeCreateGlobalPrivilege：无特权时自动切
// AURAAPO_CHANNELS_LOCAL=1 走 Local\ 名（与心跳 LOCAL 旋钮同
// 先例；名字不同、协议相同）。退出码即裁定（0=全过）。
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <audioenginebaseapo.h>
#include <audiomediatype.h>
#include <sddl.h>
#include <ks.h>
#include <ksmedia.h>
#include <mmdeviceapi.h>

#include <initguid.h>
DEFINE_GUID(IID_IAudioProcessingObject,
    0xfd7f2b29, 0x24d0, 0x4b5c, 0xb1, 0x77, 0x59, 0x2c, 0x39, 0xf9, 0xca, 0x10);
DEFINE_GUID(IID_IAudioProcessingObjectRT,
    0x9e1d6a6d, 0xddbc, 0x4e95, 0xa4, 0xc7, 0xad, 0x64, 0xba, 0x37, 0x84, 0x6c);
DEFINE_GUID(IID_IAudioProcessingObjectConfiguration,
    0x0e5ed805, 0xaba6, 0x49c3, 0x8f, 0x9a, 0x2b, 0x8c, 0x88, 0x9c, 0x4f, 0xa8);
DEFINE_GUID(IID_IAudioSystemEffects,
    0x5fa00f27, 0xadd6, 0x499a, 0x8a, 0x9d, 0x6b, 0x98, 0x52, 0x1f, 0xa7, 0x5b);

#include <cmath>
#include <atomic>
#include <cstdint>
#include <string>
#include <cstdio>
#include <cstring>
#include <vector>

#include "ApoEndpointProps.h"
#include "ApoParamIndex.h"
#include "ApoShared.h"
#include "AuraApoGuid.h"

namespace {

int g_fail = 0;
void check(const char* name, bool ok, const char* detail = "") {
    printf("[%s] %s %s\n", ok ? "PASS" : "FAIL", name, detail);
    fflush(stdout);
    if (!ok) ++g_fail;
}

bool HasGlobalPrivilege() {
    HANDLE tok = nullptr;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &tok)) return false;
    struct {
        DWORD cnt;
        LUID_AND_ATTRIBUTES attrs[1];
    } priv{};
    DWORD size = 0;
    LUID luid;
    bool found = false;
    if (LookupPrivilegeValueW(nullptr, L"SeCreateGlobalPrivilege", &luid) &&
        GetTokenInformation(tok, TokenPrivileges, &priv, sizeof(priv), &size)) {
        for (DWORD i = 0; i < priv.cnt; ++i) {
            if (priv.attrs[i].Luid.HighPart == luid.HighPart &&
                priv.attrs[i].Luid.LowPart == luid.LowPart &&
                (priv.attrs[i].Attributes & SE_PRIVILEGE_ENABLED)) {
                found = true;
                break;
            }
        }
    }
    CloseHandle(tok);
    return found;
}

double Rms(const float* b, int n) {
    double acc = 0;
    for (int i = 0; i < n; i++) acc += (double)b[i] * b[i];
    return sqrt(acc / n);
}

void FillSine(float* b, int frames, int startIdx) {
    for (int i = 0; i < frames; i++) {
        float s = (float)(0.2 * sin(2 * 3.14159265358979 * 440.0 *
                                    (startIdx + i) / 48000.0));
        b[i * 2] = s;
        b[i * 2 + 1] = s;
    }
}

bool PublishNumericParam(const char* id, uint32_t value) {
    uint32_t idx = UINT32_MAX;
    for (uint32_t i = 0; i < APO_NUM_PARAM_COUNT; ++i) {
        if (strcmp(kApoNumParamIds[i], id) == 0) {
            idx = i;
            break;
        }
    }
    if (idx == UINT32_MAX) return false;
    HANDLE h = OpenFileMappingW(FILE_MAP_ALL_ACCESS, FALSE, AuraApoParamsName());
    if (!h) return false;
    auto* pb = (uint8_t*)MapViewOfFile(h, FILE_MAP_ALL_ACCESS, 0, 0,
                                       APO_BLOCK_MAPPING_BYTES);
    if (!pb) {
        CloseHandle(h);
        return false;
    }
    auto* hdr = (ApoParamBlockHeader*)pb;
    if (hdr->magic != APO_PARAMS_MAGIC || hdr->version != APO_PARAMS_VERSION) {
        memset(pb, 0, APO_BLOCK_USED_BYTES);
        hdr->magic = APO_PARAMS_MAGIC;
        hdr->version = APO_PARAMS_VERSION;
        hdr->numCount = APO_NUM_PARAM_COUNT;
        hdr->writeSeq = 0;
    }
    const uint32_t seq = hdr->writeSeq;
    hdr->writeSeq = seq + 1;
    pb[APO_BLOCK_MASK_OFFSET + idx / 8] |= (uint8_t)(1u << (idx % 8));
    memcpy(pb + APO_BLOCK_VALUES_OFFSET + 4 * idx, &value, sizeof(value));
    MemoryBarrier();
    hdr->writeSeq = seq + 2;
    UnmapViewOfFile(pb);
    CloseHandle(h);
    return true;
}

bool PublishStringParam(const char* id, const wchar_t* path) {
    uint32_t slot = UINT32_MAX;
    for (uint32_t i = 0; i < APO_STR_SLOT_COUNT; ++i) {
        if (strcmp(kApoStrSlotIds[i], id) == 0) {
            slot = i;
            break;
        }
    }
    if (slot == UINT32_MAX) return false;
    char utf8[MAX_PATH * 3] = {0};
    const int bytes = WideCharToMultiByte(CP_UTF8, 0, path, -1, utf8,
                                          sizeof(utf8), nullptr, nullptr);
    if (bytes <= 0 || (uint32_t)bytes > kApoStrSlotCaps[slot]) return false;
    HANDLE h = OpenFileMappingW(FILE_MAP_ALL_ACCESS, FALSE, AuraApoParamsName());
    if (!h) return false;
    auto* pb = (uint8_t*)MapViewOfFile(h, FILE_MAP_ALL_ACCESS, 0, 0,
                                       APO_BLOCK_MAPPING_BYTES);
    if (!pb) {
        CloseHandle(h);
        return false;
    }
    auto* hdr = (ApoParamBlockHeader*)pb;
    if (hdr->magic != APO_PARAMS_MAGIC || hdr->version != APO_PARAMS_VERSION) {
        memset(pb, 0, APO_BLOCK_USED_BYTES);
        hdr->magic = APO_PARAMS_MAGIC;
        hdr->version = APO_PARAMS_VERSION;
        hdr->numCount = APO_NUM_PARAM_COUNT;
        hdr->writeSeq = 0;
    }
    const uint32_t seq = hdr->writeSeq;
    hdr->writeSeq = seq + 1;
    const uint32_t bit = APO_NUM_PARAM_COUNT + slot;
    pb[APO_BLOCK_MASK_OFFSET + bit / 8] |= (uint8_t)(1u << (bit % 8));
    uint8_t* dst = pb + kApoStrSlotOffsets[slot];
    memset(dst, 0, kApoStrSlotCaps[slot]);
    memcpy(dst, utf8, (size_t)bytes - 1);
    hdr->strUsed[slot] = (uint32_t)bytes - 1;
    // Task 18 fix round 1: file slots carry a per-slot publication intent in
    // previously reserved header words. Re-publishing identical bytes must be
    // distinguishable from the worker merely polling the same snapshot.
    if (slot >= 4 && slot < 6) ++hdr->reserved[slot - 4];
    MemoryBarrier();
    hdr->writeSeq = seq + 2;
    UnmapViewOfFile(pb);
    CloseHandle(h);
    return true;
}

// Task 18 is deliberately read through a local projection so these regression
// tests compile and run against the v7 host for genuine RED evidence.
struct Task18TelemetryTail {
    uint64_t enginePathHash;
    uint32_t engineLoadGen;
    uint32_t convReady;
    uint32_t ddcReady;
    uint32_t stopStatus;
    char lastFileError[256];
};
constexpr uint32_t kTask18TelemetryOffset = 1632;
constexpr uint32_t kTask18StopFixture = 0x41313853u;  // 'A18S'
constexpr uint32_t kTask18DdcBusyFixture = 0x41313842u;  // 'A18B'
constexpr uint32_t kTask18WaitFailureFixture = 0x41313846u;  // 'A18F'
static_assert(sizeof(Task18TelemetryTail) == 280, "test telemetry projection");

const Task18TelemetryTail* Task18Tail(const ApoTelemetryBlock* tele) {
    return tele ? reinterpret_cast<const Task18TelemetryTail*>(
                      reinterpret_cast<const uint8_t*>(tele) +
                      kTask18TelemetryOffset)
                : nullptr;
}

bool TransitFixturePath(const wchar_t* fixtureName, wchar_t* outPath, size_t cap) {
    wchar_t pd[MAX_PATH] = {};
    DWORD n = GetEnvironmentVariableW(L"ProgramData", pd, MAX_PATH);
    std::wstring root = (n > 0 && n < MAX_PATH) ? pd : L"C:\\ProgramData";
    root += L"\\AuraDSP";
    CreateDirectoryW(root.c_str(), nullptr);
    root += L"\\apo-assets";
    CreateDirectoryW(root.c_str(), nullptr);
    root += L"\\apo_engine_test";
    CreateDirectoryW(root.c_str(), nullptr);
    root += L"\\";
    root += fixtureName;
    if (root.size() + 1 > cap) return false;
    wcscpy(outPath, root.c_str());
    return true;
}

void Put16(std::vector<uint8_t>& b, uint16_t v) {
    b.push_back((uint8_t)(v & 0xFF));
    b.push_back((uint8_t)(v >> 8));
}
void Put32(std::vector<uint8_t>& b, uint32_t v) {
    Put16(b, (uint16_t)(v & 0xFFFF));
    Put16(b, (uint16_t)(v >> 16));
}

bool WriteIrFixture(const wchar_t* path, float gain) {
    constexpr uint16_t frames = 64;
    std::vector<uint8_t> b;
    const char riff[] = "RIFF";
    const char wavefmt[] = "WAVEfmt ";
    const char data[] = "data";
    b.insert(b.end(), riff, riff + 4);
    Put32(b, 36 + frames * 2);
    b.insert(b.end(), wavefmt, wavefmt + 8);
    Put32(b, 16);
    Put16(b, 1);
    Put16(b, 1);
    Put32(b, 48000);
    Put32(b, 96000);
    Put16(b, 2);
    Put16(b, 16);
    b.insert(b.end(), data, data + 4);
    Put32(b, frames * 2);
    for (uint16_t i = 0; i < frames; ++i) {
        const float sample = i == 0 ? gain : 0.0f;
        int v = (int)(sample * 32767.0f);
        if (v > 32767) v = 32767;
        if (v < -32768) v = -32768;
        Put16(b, (uint16_t)(int16_t)v);
    }
    HANDLE h = CreateFileW(path, GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                           FILE_ATTRIBUTE_NORMAL, nullptr);
    if (h == INVALID_HANDLE_VALUE) return false;
    DWORD written = 0;
    const bool ok = WriteFile(h, b.data(), (DWORD)b.size(), &written, nullptr) &&
                    written == b.size();
    CloseHandle(h);
    return ok;
}

bool WriteDdcFixture(const wchar_t* path, double gain) {
    char text[512];
    snprintf(text, sizeof(text),
             "SR_44100: %.12f,0,0,0,0\nSR_48000: %.12f,0,0,0,0\n",
             gain, gain);
    HANDLE h = CreateFileW(path, GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                           FILE_ATTRIBUTE_NORMAL, nullptr);
    if (h == INVALID_HANDLE_VALUE) return false;
    DWORD written = 0;
    const DWORD bytes = (DWORD)strlen(text);
    const bool ok = WriteFile(h, text, bytes, &written, nullptr) &&
                    written == bytes;
    CloseHandle(h);
    return ok;
}

bool ProcessedRatioNear(double value, double expected, double tolerance) {
    return value > expected - tolerance && value < expected + tolerance;
}

void CheckProductionPluginAcl() {
#ifndef AURA_APO_PLUGINS_SDDL
    check("production plugin SDDL is present", false,
          "AURA_APO_PLUGINS_SDDL missing");
#else
    PSECURITY_DESCRIPTOR sd = nullptr;
    if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
            AURA_APO_PLUGINS_SDDL, SDDL_REVISION_1, &sd, nullptr) &&
        !ConvertStringSecurityDescriptorToSecurityDescriptorW(
            AURA_APO_PLUGINS_SDDL_FALLBACK, SDDL_REVISION_1, &sd, nullptr)) {
        check("production plugin SDDL parses", false);
        return;
    }
    SECURITY_ATTRIBUTES sa{};
    sa.nLength = sizeof(sa);
    sa.lpSecurityDescriptor = sd;
    wchar_t name[96];
    swprintf(name, 96, L"Local\\AuraDSP_ApoPluginsAclTest_%lu",
             (unsigned long)GetCurrentProcessId());
    HANDLE created = CreateFileMappingW(INVALID_HANDLE_VALUE, &sa,
                                        PAGE_READWRITE, 0, 4096, name);
    LocalFree(sd);
    if (!created) {
        check("production plugin ACL fixture mapping", false);
        return;
    }
    HANDLE hRead = OpenFileMappingW(FILE_MAP_READ, FALSE, name);
    SetLastError(ERROR_SUCCESS);
    HANDLE hWrite = OpenFileMappingW(FILE_MAP_WRITE, FALSE, name);
    const DWORD writeErr = GetLastError();
    char detail[96];
    snprintf(detail, sizeof(detail), "read=%p write=%p err=%lu",
             hRead, hWrite, (unsigned long)writeErr);
    check("production plugin mapping: standard user read only",
          hRead != nullptr && hWrite == nullptr &&
              writeErr == ERROR_ACCESS_DENIED,
          detail);
    if (hRead) CloseHandle(hRead);
    if (hWrite) CloseHandle(hWrite);
    CloseHandle(created);
#endif
}

}  // namespace

// N1 transit fence (2026-11-22): the APO host only loads plugin
// binaries from under %ProgramData%\AuraDSP\apo-assets - the
// production App transit-copies them there before publishing.
// The test mirrors that contract: copy the probe fixtures into
// the transit root and publish the TRANSIT paths, never the
// build-tree originals. Returns false when the copy fails.
bool TransitCopy(const wchar_t* srcPath, wchar_t* outPath, size_t cap,
                 const wchar_t* fixtureName = nullptr) {
    wchar_t pd[MAX_PATH] = {};
    DWORD n = GetEnvironmentVariableW(L"ProgramData", pd, MAX_PATH);
    std::wstring root = (n > 0 && n < MAX_PATH) ? pd : L"C:\\ProgramData";
    root += L"\\AuraDSP";
    CreateDirectoryW(root.c_str(), nullptr);
    root += L"\\apo-assets";
    CreateDirectoryW(root.c_str(), nullptr);
    root += L"\\apo_engine_test";
    CreateDirectoryW(root.c_str(), nullptr);
    root += L"\\";
    if (fixtureName) {
        root += fixtureName;
    } else {
        const wchar_t* slash = wcsrchr(srcPath, L'\\');
        root += slash ? slash + 1 : L"fixture.clap";
    }
    if (root.size() + 1 > cap) return false;
    wcscpy(outPath, root.c_str());
    return CopyFileW(srcPath, outPath, FALSE) != 0;
}

int RunApoEngineSuite(bool trustedFixture) {
    g_fail = 0;
    printf("apo_engine_test mode: %s\n",
           trustedFixture ? "trusted-fixture" : "production");
    CheckProductionPluginAcl();
    const bool local = !HasGlobalPrivilege();
    if (local) {
        SetEnvironmentVariableA("AURAAPO_CHANNELS_LOCAL", "1");
        printf("note: no SeCreateGlobalPrivilege, channels via Local\\ names\n");
    }
    // Pre-create only the fixture mapping with the test user's DACL. This
    // deliberately gives the suite write access even against the production
    // DLL, so direct shared-block tampering reaches its fail-closed branch.
    HANDLE testPluginMap = CreateFileMappingW(
        INVALID_HANDLE_VALUE, nullptr, PAGE_READWRITE, 0,
        APO_PLUGIN_BLOCK_BYTES, AuraApoPluginsName());
    check("test plugin mapping writable fixture", testPluginMap != nullptr);
    if (!testPluginMap) return 1;
    if (FAILED(CoInitializeEx(nullptr, COINIT_MULTITHREADED))) {
        check("CoInitializeEx", false);
        return 1;
    }
    // Production and explicitly trusted fixture hosts are separate DLLs.
    wchar_t self[MAX_PATH] = {0};
    GetModuleFileNameW(nullptr, self, MAX_PATH);
    wchar_t* slash = wcsrchr(self, L'\\');
    wcscpy(slash ? slash + 1 : self,
           trustedFixture ? L"AuraApoTrustedTest.dll" : L"AuraApo.dll");
    HMODULE dll = LoadLibraryW(self);
    check(trustedFixture ? "LoadLibrary AuraApoTrustedTest.dll"
                         : "LoadLibrary production AuraApo.dll",
          dll != nullptr);
    if (!dll) return 1;
    using GetClassFn = HRESULT(__stdcall*)(REFCLSID, REFIID, void**);
    auto getClass = (GetClassFn)GetProcAddress(dll, "DllGetClassObject");
    IClassFactory* factory = nullptr;
    HRESULT hr = getClass ? getClass(CLSID_AuraApoEfx, IID_IClassFactory,
                                     (void**)&factory)
                          : E_FAIL;
    check("DllGetClassObject", SUCCEEDED(hr) && factory);
    if (!factory) return 1;
    IUnknown* unk = nullptr;
    hr = factory->CreateInstance(nullptr, IID_IUnknown, (void**)&unk);
    factory->Release();
    check("CreateInstance", SUCCEEDED(hr) && unk);
    if (!unk) return 1;
    IAudioProcessingObject* apo = nullptr;
    IAudioProcessingObjectRT* rt = nullptr;
    IAudioProcessingObjectConfiguration* cfg = nullptr;
    unk->QueryInterface(IID_IAudioProcessingObject, (void**)&apo);
    unk->QueryInterface(IID_IAudioProcessingObjectRT, (void**)&rt);
    unk->QueryInterface(IID_IAudioProcessingObjectConfiguration, (void**)&cfg);
    check("QI apo/rt/cfg", apo && rt && cfg);
    if (!apo || !rt || !cfg) return 1;
    check("Initialize", apo->Initialize(0, nullptr) == S_OK);

    UNCOMPRESSEDAUDIOFORMAT uf{};
    uf.guidFormatType = KSDATAFORMAT_SUBTYPE_IEEE_FLOAT;
    uf.dwSamplesPerFrame = 2;
    uf.dwBytesPerSampleContainer = 4;
    uf.dwValidBitsPerSample = 32;
    uf.fFramesPerSecond = 48000.0f;
    uf.dwChannelMask = 3;
    IAudioMediaType* fmt = nullptr;
    check("CreateAudioMediaType",
          CreateAudioMediaTypeFromUncompressedAudioFormat(&uf, &fmt) == S_OK && fmt);
    if (!fmt) return 1;
    APO_CONNECTION_DESCRIPTOR inDesc{}, outDesc{};
    inDesc.pFormat = fmt;
    inDesc.u32MaxFrameCount = 512;
    outDesc = inDesc;
    APO_CONNECTION_DESCRIPTOR* pins[1] = {&inDesc};
    APO_CONNECTION_DESCRIPTOR* pouts[1] = {&outDesc};

    // Task 18 cold start: the parameter block and file-effect selections exist
    // before the first LockForProcess, exactly as in a restored session.
    HANDLE paramFixture = CreateFileMappingW(
        INVALID_HANDLE_VALUE, nullptr, PAGE_READWRITE, 0,
        APO_BLOCK_MAPPING_BYTES, AuraApoParamsName());
    check("file effects: pre-lock parameter fixture", paramFixture != nullptr);
    wchar_t irHalf[MAX_PATH] = {0}, irQuarter[MAX_PATH] = {0};
    wchar_t ddcHalf[MAX_PATH] = {0}, ddcQuarter[MAX_PATH] = {0};
    wchar_t irMissing[MAX_PATH] = {0}, ddcMissing[MAX_PATH] = {0};
    wchar_t fixtureName[96];
    auto fixtureNamed = [&](const wchar_t* stem, const wchar_t* ext,
                            wchar_t* out) {
        swprintf(fixtureName, 96, L"%s_%lu%s", stem,
                 (unsigned long)GetCurrentProcessId(), ext);
        return TransitFixturePath(fixtureName, out, MAX_PATH);
    };
    const bool fileFixtures =
        fixtureNamed(L"task18_ir_half", L".wav", irHalf) &&
        fixtureNamed(L"task18_ir_quarter", L".wav", irQuarter) &&
        fixtureNamed(L"task18_ddc_half", L".vdc", ddcHalf) &&
        fixtureNamed(L"task18_ddc_quarter", L".vdc", ddcQuarter) &&
        fixtureNamed(L"task18_ir_missing", L".wav", irMissing) &&
        fixtureNamed(L"task18_ddc_missing", L".vdc", ddcMissing) &&
        WriteIrFixture(irHalf, 0.5f) && WriteIrFixture(irQuarter, 0.25f) &&
        WriteDdcFixture(ddcHalf, 0.5) && WriteDdcFixture(ddcQuarter, 0.25);
    check("file effects: deterministic IR/DDC fixtures", fileFixtures);
    bool coldPublished = paramFixture && fileFixtures;
    coldPublished = PublishStringParam("convolver.ir.path", irHalf) && coldPublished;
    coldPublished = PublishStringParam("ddc.load", ddcHalf) && coldPublished;
    coldPublished = PublishNumericParam("convolver.enable", 1) && coldPublished;
    coldPublished = PublishNumericParam("ddc.enable", 1) && coldPublished;
    check("file effects: cold-start selections published", coldPublished);

    check("LockForProcess", cfg->LockForProcess(1, pins, 1, pouts) == S_OK);
    Sleep(700);

    // telemetry：座位应已被本进程（宿主进程）的 APO 实例抢到。
    HANDLE hTele = OpenFileMappingW(FILE_MAP_ALL_ACCESS, FALSE, AuraApoTelemetryName());
    check("telemetry mapping exists", hTele != nullptr);
    const ApoTelemetryBlock* tele = nullptr;
    if (hTele) {
        tele = (const ApoTelemetryBlock*)MapViewOfFile(
            hTele, FILE_MAP_ALL_ACCESS, 0, 0, APO_TELEMETRY_BYTES);
    }
    check("telemetry view", tele != nullptr);
    wchar_t engineOriginal[MAX_PATH] = {0};
    wchar_t engineMoved[MAX_PATH] = {0};
    HMODULE loadedEngine = GetModuleHandleW(L"auradsp_engine_apo.dll");
    const DWORD enginePathLen = loadedEngine
        ? GetModuleFileNameW(loadedEngine, engineOriginal, MAX_PATH)
        : 0;
    const uint64_t enginePathHash = enginePathLen > 0
        ? AuraEndpointIdHash(engineOriginal)
        : 0;
    check("file effects: actual engine module path captured",
          enginePathLen > 0 && enginePathLen < MAX_PATH);
    if (tele) {
        char d[128];
        snprintf(d, sizeof(d), "seat=%ld pid=%lu sr=%lu ch=%lu fault=%lu",
                 tele->seatState, (unsigned long)tele->ownerPid,
                 (unsigned long)tele->sampleRate, (unsigned long)tele->channels,
                 (unsigned long)tele->fault);
        check("seat claimed by this process",
              tele->seatState == 1 && tele->ownerPid == GetCurrentProcessId() &&
                  tele->sampleRate == 48000 && tele->channels == 2 &&
                  tele->fault == 0,
              d);
        // 第五轮 S3：telemetry v4 加载诊断——起链成功后必须报
        // version>=4 且 loadStage=READY（失败口径见 ApoShared.h）。
        char d4[96];
        snprintf(d4, sizeof(d4), "version=%lu stage=%lu err=%lu",
                 (unsigned long)tele->version,
                 (unsigned long)tele->loadStage,
                 (unsigned long)tele->loadErr);
        check("telemetry v4 load diag ready",
              tele->version >= 4 &&
                  tele->loadStage == APO_LOAD_STAGE_READY &&
                  tele->loadErr == 0,
              d4);
        const auto* t18 = Task18Tail(tele);
        char d8[160];
        snprintf(d8, sizeof(d8),
                 "version=%lu hash=%llx expected=%llx gen=%lu stop=%lu",
                 (unsigned long)tele->version,
                 (unsigned long long)t18->enginePathHash,
                 (unsigned long long)enginePathHash,
                 (unsigned long)t18->engineLoadGen,
                 (unsigned long)t18->stopStatus);
        check("telemetry v8 reports actual engine path hash and generation",
              tele->version >= 8 && t18->enginePathHash == enginePathHash &&
                  enginePathHash != 0 && t18->engineLoadGen > 0 &&
                  t18->stopStatus == 0,
              d8);
    }

    // 音频脚手架：16 块 × 512 帧正弦，RMS 取后 8 块（避链路瞬态）。
    const int kBlocks = 16, kFrames = 512;
    static float inBuf[kFrames * 2], outBuf[kFrames * 2];
    APO_CONNECTION_PROPERTY inProp{}, outProp{};
    inProp.pBuffer = (UINT_PTR)inBuf;
    inProp.u32ValidFrameCount = kFrames;
    inProp.u32BufferFlags = BUFFER_VALID;
    outProp.pBuffer = (UINT_PTR)outBuf;
    APO_CONNECTION_PROPERTY* pinProps[1] = {&inProp};
    APO_CONNECTION_PROPERTY* poutProps[1] = {&outProp};
    auto runBlocks = [&](int fromBlock, double& rmsOut) {
        double acc = 0;
        int cnt = 0;
        for (int b = 0; b < kBlocks; b++) {
            FillSine(inBuf, kFrames, (fromBlock + b) * kFrames);
            memset(outBuf, 0, sizeof(outBuf));
            rt->APOProcess(1, pinProps, 1, poutProps);
            if (b >= kBlocks / 2) {
                acc += Rms(outBuf, kFrames * 2);
                cnt++;
            }
        }
        rmsOut = acc / cnt;
    };
    const double rmsIn = 0.2 / sqrt(2.0);

    double fileColdRms = 0.0;
    runBlocks(0, fileColdRms);
    if (tele) {
        const auto* t18 = Task18Tail(tele);
        char d[192];
        snprintf(d, sizeof(d),
                 "conv=%lu ddc=%lu err=%s ratio=%.4f (expect 0.25)",
                 (unsigned long)t18->convReady, (unsigned long)t18->ddcReady,
                 t18->lastFileError, fileColdRms / rmsIn);
        check("file effects: cold-start APO loads IR+DDC and changes audio",
              tele->version >= 8 && t18->convReady == 1 && t18->ddcReady == 1 &&
                  t18->lastFileError[0] == 0 &&
                  ProcessedRatioNear(fileColdRms / rmsIn, 0.25, 0.06),
              d);
    }

    check("file effects: in-APO IR reselection published",
          PublishStringParam("convolver.ir.path", irQuarter));
    check("file effects: in-APO DDC reselection published",
          PublishStringParam("ddc.load", ddcQuarter));
    Sleep(700);
    double reselectRms = 0.0;
    runBlocks(kBlocks, reselectRms);
    if (tele) {
        const auto* t18 = Task18Tail(tele);
        char d[160];
        snprintf(d, sizeof(d), "conv=%lu ddc=%lu ratio=%.4f (expect 0.0625)",
                 (unsigned long)t18->convReady, (unsigned long)t18->ddcReady,
                 reselectRms / rmsIn);
        check("file effects: in-APO reselection is ready and audible",
              t18->convReady == 1 && t18->ddcReady == 1 &&
                  ProcessedRatioNear(reselectRms / rmsIn, 0.0625, 0.025),
              d);
    }

    // A failed replacement must unload the old effect, report an error, and a
    // later retry of the previously successful path must not be diff-suppressed.
    check("file effects: missing IR replacement published",
          PublishStringParam("convolver.ir.path", irMissing));
    check("file effects: missing DDC replacement published",
          PublishStringParam("ddc.load", ddcMissing));
    Sleep(700);
    double failedFileRms = 0.0;
    runBlocks(2 * kBlocks, failedFileRms);
    if (tele) {
        const auto* t18 = Task18Tail(tele);
        char d[256];
        snprintf(d, sizeof(d), "conv=%lu ddc=%lu err=%s ratio=%.4f",
                 (unsigned long)t18->convReady, (unsigned long)t18->ddcReady,
                 t18->lastFileError, failedFileRms / rmsIn);
        check("file effects: engine failure clears ready and old processing",
              t18->convReady == 0 && t18->ddcReady == 0 &&
                  t18->lastFileError[0] != 0 &&
                  ProcessedRatioNear(failedFileRms / rmsIn, 1.0, 0.18),
              d);
    }
    // Fixing the underlying files is not enough: the user must be able to
    // re-select the byte-identical failed paths and get a real retry.
    check("file effects: formerly missing IR fixture created",
          WriteIrFixture(irMissing, 0.5f));
    check("file effects: formerly missing DDC fixture created",
          WriteDdcFixture(ddcMissing, 0.5));
    check("file effects: identical failed IR path re-published",
          PublishStringParam("convolver.ir.path", irMissing));
    check("file effects: identical failed DDC path re-published",
          PublishStringParam("ddc.load", ddcMissing));
    Sleep(700);
    double identicalRetryRms = 0.0;
    runBlocks(3 * kBlocks, identicalRetryRms);
    if (tele) {
        const auto* t18 = Task18Tail(tele);
        char d[256];
        snprintf(d, sizeof(d), "conv=%lu ddc=%lu err=%s ratio=%.4f",
                 (unsigned long)t18->convReady, (unsigned long)t18->ddcReady,
                 t18->lastFileError, identicalRetryRms / rmsIn);
        check("file effects: identical failed paths retry after files are fixed",
              t18->convReady == 1 && t18->ddcReady == 1 &&
                  t18->lastFileError[0] == 0 &&
                  ProcessedRatioNear(identicalRetryRms / rmsIn, 0.25, 0.06),
              d);
    }
    check("file effects: identical good IR retry published",
          PublishStringParam("convolver.ir.path", irQuarter));
    check("file effects: identical good DDC retry published",
          PublishStringParam("ddc.load", ddcQuarter));
    Sleep(700);
    double retryFileRms = 0.0;
    runBlocks(3 * kBlocks, retryFileRms);
    if (tele) {
        const auto* t18 = Task18Tail(tele);
        check("file effects: identical good paths retry after engine failure",
              t18->convReady == 1 && t18->ddcReady == 1 &&
                  t18->lastFileError[0] == 0 &&
                  ProcessedRatioNear(retryFileRms / rmsIn, 0.0625, 0.025));
    }

    if (trustedFixture) {
        // Deterministically fail one real host application with the engine's
        // documented retryable DDC slot-busy outcome, then re-publish the same
        // path. Only the trusted DLL contains this engine-boundary fault hook.
        auto* fixtureTele = const_cast<ApoTelemetryBlock*>(tele);
        fixtureTele->reserved[2] = kTask18DdcBusyFixture;
        check("file effects: retryable DDC busy path published",
              PublishStringParam("ddc.load", ddcHalf));
        Sleep(500);
        double ddcBusyRms = 0.0;
        runBlocks(4 * kBlocks, ddcBusyRms);
        check("file effects: retryable DDC busy is visible and unloads old DDC",
              Task18Tail(tele)->ddcReady == 0 &&
                  strstr(Task18Tail(tele)->lastFileError, "retryable") != nullptr &&
                  ProcessedRatioNear(ddcBusyRms / rmsIn, 0.25, 0.06),
              Task18Tail(tele)->lastFileError);
        check("file effects: identical retryable DDC path re-published",
              PublishStringParam("ddc.load", ddcHalf));
        Sleep(700);
        double ddcBusyRetryRms = 0.0;
        runBlocks(5 * kBlocks, ddcBusyRetryRms);
        check("file effects: identical DDC path retries after slot-busy failure",
              Task18Tail(tele)->ddcReady == 1 &&
                  Task18Tail(tele)->lastFileError[0] == 0 &&
                  ProcessedRatioNear(ddcBusyRetryRms / rmsIn, 0.125, 0.04));
        check("file effects: DDC quarter restored after busy regression",
              PublishStringParam("ddc.load", ddcQuarter));
        Sleep(600);
    }

    check("file effects: outside-fence IR replacement published",
          PublishStringParam("convolver.ir.path", self));
    Sleep(500);
    double fenceRms = 0.0;
    runBlocks(4 * kBlocks, fenceRms);
    if (tele) {
        const auto* t18 = Task18Tail(tele);
        check("file effects: host fence rejection is visible and unloads old IR",
              t18->convReady == 0 && t18->lastFileError[0] != 0 &&
                  ProcessedRatioNear(fenceRms / rmsIn, 0.25, 0.06));
    }
    check("file effects: good IR retry after fence rejection published",
          PublishStringParam("convolver.ir.path", irQuarter));
    Sleep(600);

    // VM-10: Windows permits a same-volume rename of an already loaded DLL.
    // No occupancy lock is added; generation/hash prove that processing stays
    // on the original loaded module rather than silently loading the new path.
    const uint32_t genBeforeRename = tele ? Task18Tail(tele)->engineLoadGen : 0;
    if (enginePathLen > 0) {
        wcscpy(engineMoved, engineOriginal);
        wchar_t* name = wcsrchr(engineMoved, L'\\');
        swprintf(name ? name + 1 : engineMoved,
                 name ? (size_t)(engineMoved + MAX_PATH - name - 1)
                      : (size_t)MAX_PATH,
                 L"auradsp_engine_apo_task18_%lu.moved.dll",
                 (unsigned long)GetCurrentProcessId());
    }
    const bool renamed = enginePathLen > 0 && MoveFileW(engineOriginal, engineMoved);
    check("VM-10: loaded engine DLL same-volume rename succeeds", renamed);
    double renamedRms = 0.0;
    runBlocks(5 * kBlocks, renamedRms);
    if (tele) {
        const auto* t18 = Task18Tail(tele);
        check("VM-10: rename keeps same loaded module and processing",
              t18->engineLoadGen == genBeforeRename &&
                  t18->enginePathHash == enginePathHash &&
                  ProcessedRatioNear(renamedRms / rmsIn, 0.0625, 0.025));
    }
    if (renamed) {
        check("VM-10: loaded engine DLL name restored",
              MoveFileW(engineMoved, engineOriginal) != 0);
    }

    // Session restore: unlock destroys the engine, but the persisted parameter
    // block still selects both files. The next cold engine must load them before
    // enabling either stage and publish a new load generation.
    check("file effects: unlock before restored session",
          cfg->UnlockForProcess() == S_OK);
    check("file effects: restored session lock",
          cfg->LockForProcess(1, pins, 1, pouts) == S_OK);
    Sleep(700);
    double restoredRms = 0.0;
    runBlocks(6 * kBlocks, restoredRms);
    if (tele) {
        const auto* t18 = Task18Tail(tele);
        char d[160];
        snprintf(d, sizeof(d), "gen=%lu->%lu conv=%lu ddc=%lu ratio=%.4f",
                 (unsigned long)genBeforeRename,
                 (unsigned long)t18->engineLoadGen,
                 (unsigned long)t18->convReady, (unsigned long)t18->ddcReady,
                 restoredRms / rmsIn);
        check("file effects: session-restored APO reloads IR+DDC",
              t18->engineLoadGen > genBeforeRename && t18->convReady == 1 &&
                  t18->ddcReady == 1 && t18->lastFileError[0] == 0 &&
                  ProcessedRatioNear(restoredRms / rmsIn, 0.0625, 0.025),
              d);
    }

    check("file effects: explicit empty IR path published",
          PublishStringParam("convolver.ir.path", L""));
    check("file effects: explicit empty DDC path published",
          PublishStringParam("ddc.load", L""));
    Sleep(700);
    double clearedRms = 0.0;
    runBlocks(7 * kBlocks, clearedRms);
    if (tele) {
        const auto* t18 = Task18Tail(tele);
        char d[192];
        snprintf(d, sizeof(d), "conv=%lu ddc=%lu err=%s ratio=%.4f",
                 (unsigned long)t18->convReady, (unsigned long)t18->ddcReady,
                 t18->lastFileError, clearedRms / rmsIn);
        check("file effects: empty paths explicitly unload IR+DDC",
              t18->convReady == 0 && t18->ddcReady == 0 &&
                  t18->lastFileError[0] == 0 &&
                  ProcessedRatioNear(clearedRms / rmsIn, 1.0, 0.18),
              d);
    }
    check("file effects: disable convolver after clear",
          PublishNumericParam("convolver.enable", 0));
    check("file effects: disable DDC after clear",
          PublishNumericParam("ddc.enable", 0));
    Sleep(300);

    double baseRms = 0;
    runBlocks(0, baseRms);
    {
        char d[96];
        snprintf(d, sizeof(d), "base=%.4f in=%.4f ratio=%.3f", baseRms, rmsIn,
                 baseRms / rmsIn);
        check("baseline processed (defaults, near unity)",
              baseRms / rmsIn > 0.7 && baseRms / rmsIn < 1.35, d);
    }

    // Geometry host regression: a mode request is pending until the next
    // process block, counts exactly one applied parameter, and telemetry
    // reports active (not pending) mode on both sides of that boundary.
    check("geometry mode baseline publish", PublishNumericParam("channels.mode", 0));
    Sleep(200);
    const uint32_t modeAppliedBase = tele ? tele->paramsApplied : 0;
    check("geometry mode request publish", PublishNumericParam("channels.mode", 1));
    Sleep(1100);  // also crosses the legacy telemetry readback throttle
    if (tele) {
        char d[160];
        snprintf(d, sizeof(d),
                 "applied=%lu->%lu eff=%lu host=%lu engine=%lu (pending mode=1)",
                 (unsigned long)modeAppliedBase,
                 (unsigned long)tele->paramsApplied,
                 (unsigned long)tele->effChannelsMode,
                 (unsigned long)tele->engChHost,
                 (unsigned long)tele->engChEngine);
        check("geometry mode counts once and telemetry stays active pre-process",
              tele->paramsApplied == modeAppliedBase + 1 &&
                  tele->effChannelsMode == 0 && tele->engChHost == 2 &&
                  tele->engChEngine == 2,
              d);
    }
    double modeRms = 0.0;
    runBlocks(0, modeRms);
    Sleep(150);
    if (tele) {
        char d[96];
        snprintf(d, sizeof(d), "eff=%lu host=%lu engine=%lu",
                 (unsigned long)tele->effChannelsMode,
                 (unsigned long)tele->engChHost,
                 (unsigned long)tele->engChEngine);
        check("geometry telemetry follows active mode after process",
              tele->effChannelsMode == 1 && tele->engChHost == 2 &&
                  tele->engChEngine == 2,
              d);
    }
    const uint32_t modeAppliedDiscrete = tele ? tele->paramsApplied : 0;
    check("geometry mode restore publish", PublishNumericParam("channels.mode", 0));
    Sleep(200);
    if (tele) {
        check("geometry mode restore counts once",
              tele->paramsApplied == modeAppliedDiscrete + 1);
    }
    runBlocks(kBlocks, modeRms);
    Sleep(150);
    if (tele) check("geometry active mode restored", tele->effChannelsMode == 0);

    // 扮演 App 发布者：input.gain=-12dB ≈ ×0.2512（该参数单位
    // 是 dB、量程 ±15——首跑实测 +0.25dB 得比率 1.030 与理论
    // 10^(0.25/20)=1.029 吻合，通道无恙、探针语义曾错）。
    int gainIdx = -1;
    for (uint32_t i = 0; i < APO_NUM_PARAM_COUNT; i++) {
        if (strcmp(kApoNumParamIds[i], "input.gain") == 0) {
            gainIdx = (int)i;
            break;
        }
    }
    check("input.gain in generated table", gainIdx >= 0);
    HANDLE hPar = OpenFileMappingW(FILE_MAP_ALL_ACCESS, FALSE, AuraApoParamsName());
    check("params mapping exists (created by APO host)", hPar != nullptr);
    if (hPar && gainIdx >= 0) {
        auto* blk = (uint8_t*)MapViewOfFile(hPar, FILE_MAP_ALL_ACCESS, 0, 0,
                                            APO_BLOCK_MAPPING_BYTES);
        check("params view", blk != nullptr);
        if (blk) {
            auto* hdr = (ApoParamBlockHeader*)blk;
            if (hdr->magic != APO_PARAMS_MAGIC) {
                hdr->magic = APO_PARAMS_MAGIC;
                hdr->version = APO_PARAMS_VERSION;
                hdr->numCount = APO_NUM_PARAM_COUNT;
            }
            uint32_t seq = hdr->writeSeq;
            hdr->writeSeq = seq + 1;  // 奇：写入中
            blk[APO_BLOCK_MASK_OFFSET + gainIdx / 8] |=
                (uint8_t)(1u << (gainIdx % 8));
            float g = -12.0f;
            memcpy(blk + APO_BLOCK_VALUES_OFFSET + 4 * gainIdx, &g, 4);
            MemoryBarrier();
            hdr->writeSeq = seq + 2;  // 偶：稳定
            UnmapViewOfFile(blk);
        }
        CloseHandle(hPar);
    }
    Sleep(500);  // worker 50ms 轮询：应用 + viz 泵均须在此窗内发生

    double gainRms = 0;
    runBlocks(kBlocks, gainRms);
    {
        char d[96];
        snprintf(d, sizeof(d), "gained=%.4f base=%.4f ratio=%.3f", gainRms,
                 baseRms, gainRms / baseRms);
        check("DECISIVE: input.gain -12dB applied via param channel",
              gainRms / baseRms > 0.19 && gainRms / baseRms < 0.31, d);
    }
    if (tele) {
        double specSum = 0;
        for (float v : tele->spectrum) specSum += v;
        char d[128];
        snprintf(d, sizeof(d), "applied=%lu seq=%lu specSum=%.2f fault=%lu",
                 (unsigned long)tele->paramsApplied,
                 (unsigned long)tele->updateSeq, specSum,
                 (unsigned long)tele->fault);
        check("telemetry live (applied/viz/spectrum)",
              tele->paramsApplied >= 1 && tele->updateSeq > 0 && specSum > 0 &&
                  tele->fault == 0,
              d);
    }

    // ---- Part I Q2 插件段：经插件块装真 CLAP 插件 ----
    // 先把 input.gain 恢复 0dB 取干净基线，再扮演发布者把
    // probe_gain.clap 的身份写进插件块：worker 应加载它
    // （telemetry v3 loaded=1）、处理比率 ~0.5、块内旁路后
    // 回 ~1.0、身份清空后卸载。探针文件缺席时整段跳过（本机
    // 无构建产物时不误判；CI J5b 由 apo_probe_gain 目标供货）。
    {
        HANDLE hPar2 = OpenFileMappingW(FILE_MAP_ALL_ACCESS, FALSE,
                                        AuraApoParamsName());
        if (hPar2 && gainIdx >= 0) {
            auto* blk = (uint8_t*)MapViewOfFile(
                hPar2, FILE_MAP_ALL_ACCESS, 0, 0, APO_BLOCK_MAPPING_BYTES);
            if (blk) {
                auto* hdr = (ApoParamBlockHeader*)blk;
                uint32_t seq = hdr->writeSeq;
                hdr->writeSeq = seq + 1;
                float g = 0.0f;
                memcpy(blk + APO_BLOCK_VALUES_OFFSET + 4 * gainIdx, &g, 4);
                MemoryBarrier();
                hdr->writeSeq = seq + 2;
                UnmapViewOfFile(blk);
            }
            CloseHandle(hPar2);
        }
        Sleep(400);
        double unityRms = 0;
        runBlocks(2 * kBlocks, unityRms);
        char d[96];
        snprintf(d, sizeof(d), "unity=%.4f base=%.4f ratio=%.3f", unityRms,
                 baseRms, unityRms / baseRms);
        check("gain restored to unity", unityRms / baseRms > 0.85 &&
                                            unityRms / baseRms < 1.18,
              d);

        wchar_t plugPath[MAX_PATH];
        wcscpy(plugPath, self);
        wchar_t* pslash = wcsrchr(plugPath, L'\\');
        wcscpy(pslash ? pslash + 1 : plugPath, L"probe_gain.clap");
        bool haveProbe =
            GetFileAttributesW(plugPath) != INVALID_FILE_ATTRIBUTES;
        if (haveProbe && trustedFixture) {
            wchar_t transitPath[MAX_PATH], fixtureName[80];
            swprintf(fixtureName, 80, L"apo_task2_trusted_gain_%lu.clap",
                     (unsigned long)GetCurrentProcessId());
            if (TransitCopy(plugPath, transitPath, MAX_PATH, fixtureName)) {
                wcscpy(plugPath, transitPath);
            } else {
                check("trusted gain fixture copied to transit", false);
                haveProbe = false;
            }
        }
        if (!haveProbe) {
            printf("[SKIP] plugin section (probe_gain.clap absent)\n");
        } else if (!trustedFixture) {
            wchar_t productionPath[MAX_PATH], tamperedPath[MAX_PATH];
            wchar_t productionName[80], tamperedName[80];
            swprintf(productionName, 80, L"apo_task2_production_gain_%lu.clap",
                     (unsigned long)GetCurrentProcessId());
            swprintf(tamperedName, 80, L"apo_task2_tampered_gain_%lu.clap",
                     (unsigned long)GetCurrentProcessId());
            const bool copied =
                TransitCopy(plugPath, productionPath, MAX_PATH,
                            productionName) &&
                TransitCopy(plugPath, tamperedPath, MAX_PATH,
                            tamperedName);
            check("production rejection fixtures copied", copied);
            HANDLE hPlug = copied
                ? OpenFileMappingW(FILE_MAP_ALL_ACCESS, FALSE,
                                   AuraApoPluginsName())
                : nullptr;
            uint8_t* pb = hPlug ? (uint8_t*)MapViewOfFile(
                                      hPlug, FILE_MAP_ALL_ACCESS, 0, 0,
                                      APO_PLUGIN_BLOCK_BYTES)
                                : nullptr;
            check("production rejection: writable tamper view", pb != nullptr);
            if (pb) {
                auto* phdr = (ApoPluginBlockHeader*)pb;
                if (phdr->magic != APO_PLUGINS_MAGIC) {
                    memset(pb, 0, APO_PLUGIN_BLOCK_USED_BYTES);
                    phdr->magic = APO_PLUGINS_MAGIC;
                    phdr->version = APO_PLUGINS_VERSION;
                    phdr->blockBytes = APO_PLUGIN_BLOCK_BYTES;
                    phdr->chainEnabled = 1;
                }
                auto* slotHdr = (ApoPluginSlotHeader*)(pb +
                    APO_PLUGIN_BLOCK_HEADER_BYTES);
                uint8_t* pathReg = pb + APO_PLUGIN_BLOCK_HEADER_BYTES +
                                   APO_PLUGIN_SLOT_HEADER_BYTES;
                uint8_t* idReg = pathReg + APO_PLUGIN_PATH_BYTES;
                auto publish = [&](const wchar_t* path, uint32_t gen) {
                    char pathU8[MAX_PATH * 3];
                    const int pn = WideCharToMultiByte(
                        CP_UTF8, 0, path, -1, pathU8, sizeof(pathU8),
                        nullptr, nullptr);
                    const uint32_t seq = phdr->writeSeq;
                    phdr->writeSeq = seq + 1;
                    memset(pathReg, 0, APO_PLUGIN_PATH_BYTES);
                    memcpy(pathReg, pathU8, (size_t)pn - 1);
                    memset(idReg, 0, APO_PLUGIN_ID_BYTES);
                    memcpy(idReg, "com.auradsp.probe.gain", 22);
                    slotHdr->format = 2;
                    slotHdr->insertStage = 0;
                    slotHdr->channelMask = 0xFF;
                    slotHdr->bypass = 0;
                    slotHdr->loadGen = gen;
                    slotHdr->stateGen = 0;
                    slotHdr->pathBytes = (uint32_t)pn - 1;
                    slotHdr->stateBytes = 0;
                    MemoryBarrier();
                    phdr->writeSeq = seq + 2;
                };
                auto checkRejected = [&](const char* label, uint32_t gen,
                                         double unity, int block) {
                    Sleep(800);
                    if (tele) {
                        char td[128];
                        snprintf(td, sizeof(td),
                                 "loaded=%u gen=%lu expectedGen=%lu",
                                 tele->plugins[0].loaded,
                                 (unsigned long)tele->plugins[0].appliedLoadGen,
                                 (unsigned long)gen);
                        check(label, tele->plugins[0].loaded == 0 &&
                                         tele->plugins[0].appliedLoadGen == gen,
                              td);
                    }
                    double rejectedRms = 0;
                    runBlocks(block, rejectedRms);
                    snprintf(d, sizeof(d), "rms=%.4f unity=%.4f ratio=%.3f",
                             rejectedRms, unity, rejectedRms / unity);
                    check("production plugin rejection keeps passthrough",
                          rejectedRms / unity > 0.85 &&
                              rejectedRms / unity < 1.18,
                          d);
                };
                publish(productionPath, 1);
                checkRejected("production transit fixture is not loaded", 1,
                              unityRms, 3 * kBlocks);
                // Same writable block, now directly re-pointed to another
                // user-created .clap. No trusted publisher call is involved.
                publish(tamperedPath, 2);
                checkRejected("tampered user-writable plugin path is not loaded",
                              2, unityRms, 4 * kBlocks);
                const uint32_t seq = phdr->writeSeq;
                phdr->writeSeq = seq + 1;
                slotHdr->format = 0;
                slotHdr->pathBytes = 0;
                slotHdr->loadGen = 3;
                MemoryBarrier();
                phdr->writeSeq = seq + 2;
                Sleep(400);
                UnmapViewOfFile(pb);
            }
            if (hPlug) CloseHandle(hPlug);
        } else {
            HANDLE hPlug = OpenFileMappingW(FILE_MAP_ALL_ACCESS, FALSE,
                                            AuraApoPluginsName());
            check("plugin mapping exists (created by APO host)",
                  hPlug != nullptr);
            uint8_t* pb = hPlug ? (uint8_t*)MapViewOfFile(
                                      hPlug, FILE_MAP_ALL_ACCESS, 0, 0,
                                      APO_PLUGIN_BLOCK_BYTES)
                                : nullptr;
            check("plugin view", pb != nullptr);
            if (pb) {
                auto* phdr = (ApoPluginBlockHeader*)pb;
                if (phdr->magic != APO_PLUGINS_MAGIC) {
                    phdr->magic = APO_PLUGINS_MAGIC;
                    phdr->version = APO_PLUGINS_VERSION;
                    phdr->blockBytes = APO_PLUGIN_BLOCK_BYTES;
                    phdr->chainEnabled = 1;
                    phdr->pdcEnabled = 0;
                    phdr->writeSeq = 0;
                }
                auto* slotHdr = (ApoPluginSlotHeader*)(pb +
                    APO_PLUGIN_BLOCK_HEADER_BYTES);
                uint8_t* pathReg = pb + APO_PLUGIN_BLOCK_HEADER_BYTES +
                                   APO_PLUGIN_SLOT_HEADER_BYTES;
                uint8_t* idReg = pathReg + APO_PLUGIN_PATH_BYTES;
                char pathU8[MAX_PATH * 3];
                int pn = WideCharToMultiByte(CP_UTF8, 0, plugPath, -1,
                                             pathU8, sizeof(pathU8),
                                             nullptr, nullptr);
                auto plugWrite = [&](auto&& body) {
                    uint32_t seq = phdr->writeSeq;
                    phdr->writeSeq = seq + 1;  // 奇：写入中
                    body();
                    MemoryBarrier();
                    phdr->writeSeq = seq + 2;  // 偶：稳定
                };
                // 身份发布：CLAP / stage 0 / 全声道 / 不旁路 / gen 1。
                plugWrite([&] {
                    memset(pathReg, 0, APO_PLUGIN_PATH_BYTES);
                    memcpy(pathReg, pathU8, (size_t)pn - 1);
                    memset(idReg, 0, APO_PLUGIN_ID_BYTES);
                    memcpy(idReg, "com.auradsp.probe.gain", 22);
                    slotHdr->format = 2;
                    slotHdr->insertStage = 0;
                    slotHdr->channelMask = 0xFF;
                    slotHdr->bypass = 0;
                    slotHdr->loadGen = 1;
                    slotHdr->stateGen = 0;
                    slotHdr->pathBytes = (uint32_t)pn - 1;
                    slotHdr->stateBytes = 0;
                });
                Sleep(800);  // worker 50ms 轮询 + 插件加载
                if (tele) {
                    char td[128];
                    snprintf(td, sizeof(td),
                             "ver=%lu loaded=%u gen=%lu calls=%lu",
                             (unsigned long)tele->version,
                             tele->plugins[0].loaded,
                             (unsigned long)tele->plugins[0].appliedLoadGen,
                             (unsigned long)tele->plugins[0].processCalls);
                    check("telemetry v3: plugin loaded via block",
                          tele->version >= 3 && tele->plugins[0].loaded == 1 &&
                              tele->plugins[0].appliedLoadGen == 1 &&
                              tele->plugins[0].fault == 0,
                          td);
                }
                double plugRms = 0;
                runBlocks(3 * kBlocks, plugRms);
                snprintf(d, sizeof(d), "plug=%.4f unity=%.4f ratio=%.3f",
                         plugRms, unityRms, plugRms / unityRms);
                check("DECISIVE: probe gain 0.5 via APO plugin hosting",
                      plugRms / unityRms > 0.4 && plugRms / unityRms < 0.6,
                      d);
                // 块内旁路（loadGen 不变）→ 回到 ~1.0。
                plugWrite([&] { slotHdr->bypass = 1; });
                Sleep(400);
                double bypRms = 0;
                runBlocks(4 * kBlocks, bypRms);
                snprintf(d, sizeof(d), "bypassed=%.4f ratio=%.3f", bypRms,
                         bypRms / unityRms);
                check("block bypass restores unity",
                      bypRms / unityRms > 0.85 && bypRms / unityRms < 1.18,
                      d);
                if (tele) {
                    check("telemetry: bypass effective",
                          tele->plugins[0].bypass == 1);
                }
                // 身份清空（gen 2）→ 卸载、telemetry loaded=0。
                plugWrite([&] {
                    slotHdr->format = 0;
                    slotHdr->pathBytes = 0;
                    slotHdr->loadGen = 2;
                });
                Sleep(500);
                if (tele) {
                    check("telemetry: plugin unloaded",
                          tele->plugins[0].loaded == 0 &&
                              tele->plugins[0].appliedLoadGen == 2);
                }
                UnmapViewOfFile(pb);
            }
            if (hPlug) CloseHandle(hPlug);
        }
    }

    // ---- Part I Q4 崩溃隔离段：崩溃插件闩锁 + 邻槽续处理 ----
    // 槽 0 重挂 probe_gain、槽 1 装 probe_crash（process 内空写
    // AV）：引擎逐槽 SEH 应把故障闩锁在槽 1（telemetry fault=1、
    // 类别 7=process_crash、有效旁路），槽 0 继续处理，整机不
    // 进透传闩锁（tele->fault 保持 0、座位仍在）。决定性比率：
    // input.gain -12dB × 增益插件 0.5 ≈ 0.126——透传会是 1.0、
    // 邻槽同死会是 0.251，三者可分。仅显式可信测试宿主执行。
    if (trustedFixture) {
        wchar_t gainPath[MAX_PATH], crashPath[MAX_PATH];
        wcscpy(gainPath, self);
        wchar_t* gs = wcsrchr(gainPath, L'\\');
        wcscpy(gs ? gs + 1 : gainPath, L"probe_gain.clap");
        wcscpy(crashPath, self);
        wchar_t* cs = wcsrchr(crashPath, L'\\');
        wcscpy(cs ? cs + 1 : crashPath, L"probe_crash.clap");
        bool haveCrash =
            GetFileAttributesW(crashPath) != INVALID_FILE_ATTRIBUTES &&
            GetFileAttributesW(gainPath) != INVALID_FILE_ATTRIBUTES;
        if (haveCrash) {
            wchar_t tGain[MAX_PATH], tCrash[MAX_PATH];
            wchar_t gainName[80], crashName[80];
            swprintf(gainName, 80, L"apo_task2_crash_gain_%lu.clap",
                     (unsigned long)GetCurrentProcessId());
            swprintf(crashName, 80, L"apo_task2_crash_probe_%lu.clap",
                     (unsigned long)GetCurrentProcessId());
            if (TransitCopy(gainPath, tGain, MAX_PATH, gainName) &&
                TransitCopy(crashPath, tCrash, MAX_PATH, crashName)) {
                wcscpy(gainPath, tGain);
                wcscpy(crashPath, tCrash);
            } else {
                check("trusted crash fixtures copied to transit", false);
                haveCrash = false;
            }
        }
        // 本段自测单位基线（增益已在 Q2 段恢复 0dB、两槽皆空）。
        double q4Unity = 0;
        runBlocks(2 * kBlocks, q4Unity);
        if (!haveCrash) {
            printf("[SKIP] crash section (probe_crash.clap absent)\n");
        } else {
            HANDLE hPlug = OpenFileMappingW(FILE_MAP_ALL_ACCESS, FALSE,
                                            AuraApoPluginsName());
            uint8_t* pb = hPlug ? (uint8_t*)MapViewOfFile(
                                      hPlug, FILE_MAP_ALL_ACCESS, 0, 0,
                                      APO_PLUGIN_BLOCK_BYTES)
                                : nullptr;
            check("crash section: plugin view", pb != nullptr);
            if (pb) {
                auto* phdr = (ApoPluginBlockHeader*)pb;
                auto plugWrite = [&](auto&& body) {
                    uint32_t seq = phdr->writeSeq;
                    phdr->writeSeq = seq + 1;
                    body();
                    MemoryBarrier();
                    phdr->writeSeq = seq + 2;
                };
                auto setSlot = [&](int slot, const wchar_t* wp,
                                   const char* id, uint32_t gen) {
                    uint8_t* base = pb + APO_PLUGIN_BLOCK_HEADER_BYTES +
                                    (size_t)slot * APO_PLUGIN_SLOT_STRIDE;
                    auto* sh = (ApoPluginSlotHeader*)base;
                    uint8_t* pathReg = base + APO_PLUGIN_SLOT_HEADER_BYTES;
                    uint8_t* idReg = pathReg + APO_PLUGIN_PATH_BYTES;
                    char u8[MAX_PATH * 3];
                    int pn = WideCharToMultiByte(CP_UTF8, 0, wp, -1, u8,
                                                 sizeof(u8), nullptr,
                                                 nullptr);
                    memset(pathReg, 0, APO_PLUGIN_PATH_BYTES);
                    memcpy(pathReg, u8, (size_t)pn - 1);
                    memset(idReg, 0, APO_PLUGIN_ID_BYTES);
                    memcpy(idReg, id, strlen(id));
                    sh->format = 2;
                    sh->insertStage = 0;
                    sh->channelMask = 0xFF;
                    sh->bypass = 0;
                    sh->loadGen = gen;
                    sh->stateGen = 0;
                    sh->pathBytes = (uint32_t)pn - 1;
                    sh->stateBytes = 0;
                };
                plugWrite([&] {
                    setSlot(0, gainPath, "com.auradsp.probe.gain", 3);
                    setSlot(1, crashPath, "com.auradsp.probe.crash", 1);
                });
                Sleep(900);
                if (tele) {
                    check("crash section: both slots loaded",
                          tele->plugins[0].loaded == 1 &&
                              tele->plugins[0].appliedLoadGen == 3 &&
                              tele->plugins[1].loaded == 1 &&
                              tele->plugins[1].appliedLoadGen == 1 &&
                              tele->plugins[1].fault == 0);
                }
                const uint32_t calls0 =
                    tele ? tele->plugins[0].processCalls : 0;
                // 崩溃发生在这几块内（槽 1 首块即 AV，被引擎 SEH
                // 闩锁）；测试进程与 APO 对象必须存活到这里。
                double crashRms = 0;
                runBlocks(3 * kBlocks, crashRms);
                Sleep(300);
                if (tele) {
                    char td[128];
                    snprintf(td, sizeof(td),
                             "fault=%u cat=%u byp=%u calls0=%lu->%lu "
                             "engineFault=%lu seat=%ld",
                             tele->plugins[1].fault,
                             tele->plugins[1].faultCategory,
                             tele->plugins[1].bypass,
                             (unsigned long)calls0,
                             (unsigned long)tele->plugins[0].processCalls,
                             (unsigned long)tele->fault,
                             (long)tele->seatState);
                    check("crash latched to slot 1 (process_crash)",
                          tele->plugins[1].fault == 1 &&
                              tele->plugins[1].faultCategory == 7 &&
                              tele->plugins[1].bypass == 1,
                          td);
                    check("neighbour slot keeps processing",
                          tele->plugins[0].processCalls > calls0, td);
                    check("engine NOT in passthrough fallback",
                          tele->fault == 0 && tele->seatState == 1, td);
                }
                // 参数通道仍活：input.gain 拉到 -12dB，期望比率
                // ≈ 0.5（槽 0 增益插件）× 0.2512 ≈ 0.126。
                HANDLE hPar3 = OpenFileMappingW(
                    FILE_MAP_ALL_ACCESS, FALSE, AuraApoParamsName());
                if (hPar3 && gainIdx >= 0) {
                    auto* blk = (uint8_t*)MapViewOfFile(
                        hPar3, FILE_MAP_ALL_ACCESS, 0, 0,
                        APO_BLOCK_MAPPING_BYTES);
                    if (blk) {
                        auto* hdr = (ApoParamBlockHeader*)blk;
                        uint32_t seq = hdr->writeSeq;
                        hdr->writeSeq = seq + 1;
                        float g = -12.0f;
                        memcpy(blk + APO_BLOCK_VALUES_OFFSET +
                                   4 * gainIdx,
                               &g, 4);
                        MemoryBarrier();
                        hdr->writeSeq = seq + 2;
                        UnmapViewOfFile(blk);
                    }
                    CloseHandle(hPar3);
                }
                Sleep(400);
                double mixRms = 0;
                runBlocks(3 * kBlocks, mixRms);
                char d[96];
                snprintf(d, sizeof(d), "mix=%.4f unity=%.4f ratio=%.3f",
                         mixRms, q4Unity, mixRms / q4Unity);
                check("DECISIVE: gain param + neighbour plugin still "
                      "processing (0.5 x -12dB)",
                      mixRms / q4Unity > 0.09 && mixRms / q4Unity < 0.17,
                      d);
                // 收尾：恢复 0dB + 清空两槽（代次推进）。
                HANDLE hPar4 = OpenFileMappingW(
                    FILE_MAP_ALL_ACCESS, FALSE, AuraApoParamsName());
                if (hPar4 && gainIdx >= 0) {
                    auto* blk = (uint8_t*)MapViewOfFile(
                        hPar4, FILE_MAP_ALL_ACCESS, 0, 0,
                        APO_BLOCK_MAPPING_BYTES);
                    if (blk) {
                        auto* hdr = (ApoParamBlockHeader*)blk;
                        uint32_t seq = hdr->writeSeq;
                        hdr->writeSeq = seq + 1;
                        float g = 0.0f;
                        memcpy(blk + APO_BLOCK_VALUES_OFFSET +
                                   4 * gainIdx,
                               &g, 4);
                        MemoryBarrier();
                        hdr->writeSeq = seq + 2;
                        UnmapViewOfFile(blk);
                    }
                    CloseHandle(hPar4);
                }
                plugWrite([&] {
                    for (int slot = 0; slot < 2; slot++) {
                        uint8_t* base = pb +
                            APO_PLUGIN_BLOCK_HEADER_BYTES +
                            (size_t)slot * APO_PLUGIN_SLOT_STRIDE;
                        auto* sh = (ApoPluginSlotHeader*)base;
                        sh->format = 0;
                        sh->pathBytes = 0;
                        sh->loadGen += 1;
                    }
                });
                Sleep(400);
                UnmapViewOfFile(pb);
            }
            if (hPlug) CloseHandle(hPlug);
        }
    }

    // INPLACE 变体：同址缓冲处理结果一致（增益已恢复 0dB）。
    {
        static float inplaceBuf[kFrames * 2];
        FillSine(inplaceBuf, kFrames, 0);
        APO_CONNECTION_PROPERTY p{};
        p.pBuffer = (UINT_PTR)inplaceBuf;
        p.u32ValidFrameCount = kFrames;
        p.u32BufferFlags = BUFFER_VALID;
        APO_CONNECTION_PROPERTY* props[1] = {&p};
        // 先跑几块让链路状态与分块一致，再量一块。
        for (int b = 0; b < 4; b++) {
            FillSine(inplaceBuf, kFrames, b * kFrames);
            rt->APOProcess(1, props, 1, props);
        }
        FillSine(inplaceBuf, kFrames, 99 * kFrames);
        rt->APOProcess(1, props, 1, props);
        double r = Rms(inplaceBuf, kFrames * 2) / rmsIn;
        char d[96];
        snprintf(d, sizeof(d), "inplace ratio=%.3f (expect ~1.0)", r);
        check("in-place processing", r > 0.85 && r < 1.18, d);
    }

    // ---- 第四十一轮：多端点分块/分座/覆写 ----
    // 两个实例经伪造 FX 属性存储拿到不同端点身份与覆写：
    // A 覆写 mode=0/fill=0，B 覆写 mode=1/fill=1。断言：
    // (1) 两端点各有自己的 telemetry 块（v7 身份段自证）且座位
    //     同时被占（v1 全局座位下第二个必然失败）；
    // (2) 参数块写 mode=1/fill=1 时 A 的生效回读仍为 0/0（覆写
    //     胜出）；参数块改写 0/0 后 B 仍为 1/1（覆写胜出）。
    {
        struct FakeStore : IPropertyStore {
            std::wstring token;
            ULONG mode = 0, fill = 0;
            std::atomic<ULONG> refs{1};
            HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void** ppv) override {
                if (riid == IID_IUnknown || riid == IID_IPropertyStore) {
                    *ppv = static_cast<IPropertyStore*>(this);
                    AddRef();
                    return S_OK;
                }
                *ppv = nullptr;
                return E_NOINTERFACE;
            }
            ULONG STDMETHODCALLTYPE AddRef() override { return ++refs; }
            ULONG STDMETHODCALLTYPE Release() override {
                ULONG r = --refs;
                if (r == 0) delete this;
                return r;
            }
            HRESULT STDMETHODCALLTYPE GetCount(DWORD* c) override {
                *c = 4;
                return S_OK;
            }
            HRESULT STDMETHODCALLTYPE GetAt(DWORD, PROPERTYKEY* k) override {
                *k = AuraEndpointPropKey(kAuraPropPidToken);
                return S_OK;
            }
            HRESULT STDMETHODCALLTYPE GetValue(REFPROPERTYKEY key, PROPVARIANT* v) override {
                PropVariantInit(v);
                if (key.fmtid != AuraEndpointPropsSetGuid()) return S_OK;
                if (key.pid == kAuraPropPidToken) {
                    const size_t bytes = (token.size() + 1) * sizeof(wchar_t);
                    auto* buf = (wchar_t*)CoTaskMemAlloc(bytes);
                    if (!buf) return E_OUTOFMEMORY;
                    memcpy(buf, token.c_str(), bytes);
                    v->vt = VT_LPWSTR;
                    v->pwszVal = buf;
                } else if (key.pid == kAuraPropPidFlags) {
                    v->vt = VT_UI4;
                    v->ulVal = kAuraOverrideModeValid | kAuraOverrideFillValid;
                } else if (key.pid == kAuraPropPidMode) {
                    v->vt = VT_UI4;
                    v->ulVal = mode;
                } else if (key.pid == kAuraPropPidFill) {
                    v->vt = VT_UI4;
                    v->ulVal = fill;
                }
                return S_OK;
            }
            HRESULT STDMETHODCALLTYPE SetValue(REFPROPERTYKEY, REFPROPVARIANT) override {
                return E_NOTIMPL;
            }
            HRESULT STDMETHODCALLTYPE Commit() override { return E_NOTIMPL; }
        };

        const wchar_t* kIdA = L"{0.0.0.00000000}.{aaaaaaaa-0000-4000-8000-0000000000a1}";
        const wchar_t* kIdB = L"{0.0.0.00000000}.{bbbbbbbb-0000-4000-8000-0000000000b2}";

        auto makeInstance = [&](FakeStore* store,
                                IAudioProcessingObjectConfiguration** outCfg,
                                IAudioProcessingObjectRT** outRt,
                                IUnknown** outUnk) -> bool {
            APOInitSystemEffects init{};
            init.APOInit.cbSize = sizeof(APOInitBaseStruct);
            init.pAPOSystemEffectsProperties = store;
            IClassFactory* f2 = nullptr;
            if (!getClass || getClass(CLSID_AuraApoEfx, IID_IClassFactory, (void**)&f2) != S_OK || !f2)
                return false;
            IUnknown* u = nullptr;
            HRESULT hr = f2->CreateInstance(nullptr, IID_IUnknown, (void**)&u);
            f2->Release();
            if (hr != S_OK || !u) return false;
            IAudioProcessingObject* a = nullptr;
            u->QueryInterface(IID_IAudioProcessingObject, (void**)&a);
            IAudioProcessingObjectRT* r = nullptr;
            u->QueryInterface(IID_IAudioProcessingObjectRT, (void**)&r);
            IAudioProcessingObjectConfiguration* c = nullptr;
            u->QueryInterface(IID_IAudioProcessingObjectConfiguration, (void**)&c);
            bool ok = a && r && c &&
                      a->Initialize(sizeof(init), (BYTE*)&init) == S_OK &&
                      c->LockForProcess(1, pins, 1, pouts) == S_OK;
            if (a) a->Release();
            if (!ok) {
                if (r) r->Release();
                if (c) c->Release();
                u->Release();
                return false;
            }
            *outCfg = c;
            *outRt = r;
            *outUnk = u;
            return true;
        };

        auto* storeA = new FakeStore();
        storeA->token = kIdA;
        storeA->mode = 0;
        storeA->fill = 0;
        auto* storeB = new FakeStore();
        storeB->token = kIdB;
        storeB->mode = 1;
        storeB->fill = 1;
        IAudioProcessingObjectConfiguration *cfgA = nullptr, *cfgB = nullptr;
        IAudioProcessingObjectRT *rtA = nullptr, *rtB = nullptr;
        IUnknown *unkA = nullptr, *unkB = nullptr;
        bool okA = makeInstance(storeA, &cfgA, &rtA, &unkA);
        bool okB = makeInstance(storeB, &cfgB, &rtB, &unkB);
        check("multi-endpoint: both instances lock", okA && okB);
        Sleep(400);
        auto processBoth = [&] {
            if (rtA) rtA->APOProcess(1, pinProps, 1, poutProps);
            if (rtB) rtB->APOProcess(1, pinProps, 1, poutProps);
        };

        auto openTeleFor = [&](const wchar_t* id) -> const ApoTelemetryBlock* {
            wchar_t nm[80];
            AuraApoTelemetryNameFor(AuraEndpointIdHash(id), nm, 80);
            HANDLE h = OpenFileMappingW(FILE_MAP_READ, FALSE, nm);
            if (!h) return nullptr;
            return (const ApoTelemetryBlock*)MapViewOfFile(h, FILE_MAP_READ, 0, 0,
                                                            APO_TELEMETRY_BYTES);
        };
        const ApoTelemetryBlock* teleA = openTeleFor(kIdA);
        const ApoTelemetryBlock* teleB = openTeleFor(kIdB);
        check("multi-endpoint: per-endpoint blocks exist", teleA && teleB);
        if (teleA && teleB) {
            char d[160];
            snprintf(d, sizeof(d), "A seat=%ld ver=%lu idok=%d B seat=%ld ver=%lu idok=%d",
                     teleA->seatState, (unsigned long)teleA->version,
                     wcscmp(teleA->endpointId, kIdA) == 0 ? 1 : 0,
                     teleB->seatState, (unsigned long)teleB->version,
                     wcscmp(teleB->endpointId, kIdB) == 0 ? 1 : 0);
            check("multi-endpoint: both seats held + identity stamped",
                  teleA->seatState == 1 && teleB->seatState == 1 &&
                      teleA->version >= 7 && teleB->version >= 7 &&
                      wcscmp(teleA->endpointId, kIdA) == 0 &&
                      wcscmp(teleB->endpointId, kIdB) == 0,
                  d);
        }

        // 参数块两相写入：先 1/1 再 0/0，覆写须恒胜出。
        auto writeBlock = [&](uint32_t mode, uint32_t fill) {
            HANDLE h = OpenFileMappingW(FILE_MAP_ALL_ACCESS, FALSE, AuraApoParamsName());
            if (!h) return;
            auto* pb = (uint8_t*)MapViewOfFile(h, FILE_MAP_ALL_ACCESS, 0, 0,
                                               APO_BLOCK_MAPPING_BYTES);
            if (!pb) {
                CloseHandle(h);
                return;
            }
            auto* hdr = (ApoParamBlockHeader*)pb;
            if (hdr->magic != APO_PARAMS_MAGIC) {
                memset(pb, 0, APO_BLOCK_USED_BYTES);
                hdr->magic = APO_PARAMS_MAGIC;
                hdr->version = APO_PARAMS_VERSION;
                hdr->numCount = APO_NUM_PARAM_COUNT;
                hdr->writeSeq = 0;
            }
            const uint32_t seq = hdr->writeSeq;
            hdr->writeSeq = seq + 1;  // 奇：写入中
            uint8_t* mask = pb + APO_BLOCK_MASK_OFFSET;
            uint32_t* vals = (uint32_t*)(pb + APO_BLOCK_VALUES_OFFSET);
            auto idxOf = [&](const char* id) {
                for (uint32_t i = 0; i < APO_NUM_PARAM_COUNT; i++)
                    if (strcmp(kApoNumParamIds[i], id) == 0) return i;
                return UINT32_MAX;
            };
            const uint32_t iMode = idxOf("channels.mode");
            const uint32_t iFill = idxOf("channels.upmix_fill");
            if (iMode != UINT32_MAX) {
                mask[iMode / 8] |= (uint8_t)(1u << (iMode % 8));
                vals[iMode] = mode;
            }
            if (iFill != UINT32_MAX) {
                mask[iFill / 8] |= (uint8_t)(1u << (iFill % 8));
                vals[iFill] = fill;
            }
            hdr->writeSeq = seq + 2;  // 偶：提交
            UnmapViewOfFile(pb);
            CloseHandle(h);
        };
        if (teleA && teleB) {
            writeBlock(1, 1);
            Sleep(600);
            processBoth();
            Sleep(100);
            char d[128];
            snprintf(d, sizeof(d), "A eff=%lu/%lu valid=%lu (expect 0/0/1)",
                     (unsigned long)teleA->effChannelsMode,
                     (unsigned long)teleA->effUpmixFill,
                     (unsigned long)teleA->effValid);
            check("multi-endpoint: A override beats block 1/1",
                  teleA->effValid == 1 && teleA->effChannelsMode == 0 &&
                      teleA->effUpmixFill == 0,
                  d);
            writeBlock(0, 0);
            Sleep(600);
            processBoth();
            Sleep(100);
            snprintf(d, sizeof(d), "B eff=%lu/%lu valid=%lu (expect 1/1/1)",
                     (unsigned long)teleB->effChannelsMode,
                     (unsigned long)teleB->effUpmixFill,
                     (unsigned long)teleB->effValid);
            check("multi-endpoint: B override beats block 0/0",
                  teleB->effValid == 1 && teleB->effChannelsMode == 1 &&
                      teleB->effUpmixFill == 1,
                  d);
        }
        // 第三相：参数块 v3 实时覆写表——A 翻 1/1、B 翻 0/0，
        // 实时表须压过 FX 初值（不经 Initialize 重读）。
        if (teleA && teleB) {
            HANDLE h = OpenFileMappingW(FILE_MAP_ALL_ACCESS, FALSE, AuraApoParamsName());
            if (h) {
                auto* pb = (uint8_t*)MapViewOfFile(h, FILE_MAP_ALL_ACCESS, 0, 0,
                                                   APO_BLOCK_MAPPING_BYTES);
                if (pb) {
                    auto* hdr = (ApoParamBlockHeader*)pb;
                    const uint32_t seq = hdr->writeSeq;
                    hdr->writeSeq = seq + 1;
                    auto* tab = (ApoEndpointOverride*)(pb + APO_EP_OVERRIDE_OFFSET);
                    tab[0].idHash = AuraEndpointIdHash(kIdA);
                    tab[0].mode = 1;
                    tab[0].fill = 1;
                    tab[0].flags = 3;
                    tab[1].idHash = AuraEndpointIdHash(kIdB);
                    tab[1].mode = 0;
                    tab[1].fill = 0;
                    tab[1].flags = 3;
                    hdr->writeSeq = seq + 2;
                    UnmapViewOfFile(pb);
                }
                CloseHandle(h);
            }
            Sleep(600);
            processBoth();
            Sleep(100);
            char d[128];
            snprintf(d, sizeof(d), "A eff=%lu/%lu (expect 1/1 live)",
                     (unsigned long)teleA->effChannelsMode,
                     (unsigned long)teleA->effUpmixFill);
            check("multi-endpoint: live table flips A over FX",
                  teleA->effChannelsMode == 1 && teleA->effUpmixFill == 1, d);
            snprintf(d, sizeof(d), "B eff=%lu/%lu (expect 0/0 live)",
                     (unsigned long)teleB->effChannelsMode,
                     (unsigned long)teleB->effUpmixFill);
            check("multi-endpoint: live table flips B over FX",
                  teleB->effChannelsMode == 0 && teleB->effUpmixFill == 0, d);
        }
        if (cfgA) cfgA->UnlockForProcess();
        if (cfgB) cfgB->UnlockForProcess();
        if (teleA) UnmapViewOfFile(teleA);
        if (teleB) UnmapViewOfFile(teleB);
        if (rtA) rtA->Release();
        if (rtB) rtB->Release();
        if (cfgA) cfgA->Release();
        if (cfgB) cfgB->Release();
        if (unkA) unkA->Release();
        if (unkB) unkB->Release();
        storeA->Release();
        storeB->Release();
    }

    // ---- 第四十二轮 S1：同实例改几何重锁（系统设置改声道模式的
    // 宿主侧等价面）——2ch 解锁后以 8ch 重锁，引擎须按新几何
    // 重建（APO-8 决议），telemetry 声道随新几何；再回 2ch。
    check("geometry count baseline publish", PublishNumericParam("channels.count", 8));
    Sleep(200);
    check("UnlockForProcess (pre-geometry)", cfg->UnlockForProcess() == S_OK);
    {
        UNCOMPRESSEDAUDIOFORMAT uf8{};
        uf8.guidFormatType = KSDATAFORMAT_SUBTYPE_IEEE_FLOAT;
        uf8.dwSamplesPerFrame = 8;
        uf8.dwBytesPerSampleContainer = 4;
        uf8.dwValidBitsPerSample = 32;
        uf8.fFramesPerSecond = 48000.0f;
        uf8.dwChannelMask = 0x63F;  // 7.1 标准掩码
        IAudioMediaType* fmt8 = nullptr;
        check("CreateAudioMediaType 8ch",
              CreateAudioMediaTypeFromUncompressedAudioFormat(&uf8, &fmt8) ==
                      S_OK &&
                  fmt8);
        APO_CONNECTION_DESCRIPTOR in8{}, out8{};
        in8.pFormat = fmt8;
        in8.u32MaxFrameCount = 512;
        out8 = in8;
        APO_CONNECTION_DESCRIPTOR* pins8[1] = {&in8};
        APO_CONNECTION_DESCRIPTOR* pouts8[1] = {&out8};
        check("LockForProcess 8ch",
              cfg->LockForProcess(1, pins8, 1, pouts8) == S_OK);
        Sleep(300);
        if (tele) {
            char d[160];
            snprintf(d, sizeof(d),
                     "seat=%ld stream=%lu host=%lu engine=%lu mode=%lu fault=%lu",
                     tele->seatState, (unsigned long)tele->channels,
                     (unsigned long)tele->engChHost,
                     (unsigned long)tele->engChEngine,
                     (unsigned long)tele->effChannelsMode,
                     (unsigned long)tele->fault);
            check("geometry relock: seat+8ch",
                  tele->seatState == 1 && tele->channels == 8 &&
                      tele->fault == 0,
                  d);
            check("8ch relock keeps create-active 2ch until first process",
                  tele->engChHost == 2 && tele->engChEngine == 2 &&
                      tele->effChannelsMode == 0,
                  d);
        }
        static float in8Buf[kFrames * 8], out8Buf[kFrames * 8];
        for (int i = 0; i < kFrames * 8; ++i) {
            in8Buf[i] = 0.1f;
            out8Buf[i] = 0.0f;
        }
        APO_CONNECTION_PROPERTY in8Prop{}, out8Prop{};
        in8Prop.pBuffer = (UINT_PTR)in8Buf;
        in8Prop.u32ValidFrameCount = kFrames;
        in8Prop.u32BufferFlags = BUFFER_VALID;
        out8Prop.pBuffer = (UINT_PTR)out8Buf;
        out8Prop.u32ValidFrameCount = kFrames;
        out8Prop.u32BufferFlags = BUFFER_VALID;
        APO_CONNECTION_PROPERTY* pin8Props[1] = {&in8Prop};
        APO_CONNECTION_PROPERTY* pout8Props[1] = {&out8Prop};
        auto waitEngineCh = [&](uint32_t want) {
            if (!tele) return false;
            const volatile ApoTelemetryBlock* shared = tele;
            for (int i = 0; i < 150; ++i) {
                MemoryBarrier();
                if (shared->engChEngine == want) return true;
                Sleep(20);
            }
            return false;
        };
        auto waitEngCh = [&](uint32_t want) {
            if (!tele) return false;
            const volatile ApoTelemetryBlock* shared = tele;
            for (int i = 0; i < 150; ++i) {
                MemoryBarrier();
                if (shared->engChHost == want && shared->engChEngine == want)
                    return true;
                Sleep(20);
            }
            return false;
        };
        rt->APOProcess(1, pin8Props, 1, pout8Props);
        const bool transitioned8 = waitEngineCh(8);
        char transition8Detail[128];
        snprintf(transition8Detail, sizeof(transition8Detail),
                 "host=%lu engine=%lu mode=%lu fault=%lu",
                 tele ? (unsigned long)tele->engChHost : 0,
                 tele ? (unsigned long)tele->engChEngine : 0,
                 tele ? (unsigned long)tele->effChannelsMode : 0,
                 tele ? (unsigned long)tele->fault : 0);
        check("8ch transition activates engine before host stepping",
              transitioned8 && tele && tele->engChHost == 2,
              transition8Detail);
        rt->APOProcess(1, pin8Props, 1, pout8Props);
        const bool active8 = waitEngCh(8);
        char active8Detail[128];
        snprintf(active8Detail, sizeof(active8Detail),
                 "host=%lu engine=%lu mode=%lu fault=%lu",
                 tele ? (unsigned long)tele->engChHost : 0,
                 tele ? (unsigned long)tele->engChEngine : 0,
                 tele ? (unsigned long)tele->effChannelsMode : 0,
                 tele ? (unsigned long)tele->fault : 0);
        check("8ch host stepping publishes on matching active block", active8,
              active8Detail);
        const uint32_t countAppliedBase = tele ? tele->paramsApplied : 0;
        check("geometry count 4 publish", PublishNumericParam("channels.count", 4));
        Sleep(200);
        if (tele) {
            char d[128];
            snprintf(d, sizeof(d), "applied=%lu->%lu host=%lu engine=%lu",
                     (unsigned long)countAppliedBase,
                     (unsigned long)tele->paramsApplied,
                     (unsigned long)tele->engChHost,
                     (unsigned long)tele->engChEngine);
            check("geometry count counts once and telemetry stays active pre-process",
                  tele->paramsApplied == countAppliedBase + 1 &&
                      tele->engChHost == 8 && tele->engChEngine == 8,
                  d);
        }
        rt->APOProcess(1, pin8Props, 1, pout8Props);
        const bool transitioned4 = waitEngineCh(4);
        check("4ch transition activates engine before host stepping",
              transitioned4 && tele && tele->engChHost == 8);
        rt->APOProcess(1, pin8Props, 1, pout8Props);
        check("4ch host stepping publishes on matching active block", waitEngCh(4));
        check("UnlockForProcess 8ch", cfg->UnlockForProcess() == S_OK);
        check("LockForProcess back to 2ch",
              cfg->LockForProcess(1, pins, 1, pouts) == S_OK);
        Sleep(300);
        if (tele) {
            check("geometry relock back: 2ch",
                  tele->seatState == 1 && tele->channels == 2 &&
                      tele->fault == 0);
        }
        if (fmt8) fmt8->Release();
    }

    // H10 fail-safe Stop: the trusted fixture blocks one worker iteration for
    // 4.5s. The host's own trusted cleanup marker proves that its ReleaseResources
    // path (unmap/destroy/FreeLibrary), not merely an independent telemetry view,
    // stayed untouched. A second timeout goes straight through final COM/DLL
    // destruction with an injected final-wait failure and verifies worker-owned
    // context/module retention followed by self-cleanup.
    if (trustedFixture && tele) {
        HANDLE stopMap = OpenFileMappingW(FILE_MAP_ALL_ACCESS, FALSE,
                                          AuraApoTelemetryName());
        const ApoTelemetryBlock* stopTele = stopMap
            ? (const ApoTelemetryBlock*)MapViewOfFile(
                  stopMap, FILE_MAP_ALL_ACCESS, 0, 0, APO_TELEMETRY_BYTES)
            : nullptr;
        check("Stop timeout: independent telemetry view", stopTele != nullptr);
        if (stopTele) {
            if (hTele) CloseHandle(hTele);
            hTele = stopMap;
            tele = stopTele;
        } else if (stopMap) {
            CloseHandle(stopMap);
        }
        // The pre-lock fixture would otherwise keep the parameter mapping alive
        // even if the host wrongly closed its own handle.
        if (paramFixture) {
            CloseHandle(paramFixture);
            paramFixture = nullptr;
        }
        auto* fixtureTele = const_cast<ApoTelemetryBlock*>(tele);
        const uint32_t genBeforeStop = Task18Tail(tele)->engineLoadGen;
        const uint32_t cleanupBeforeStop = fixtureTele->reserved[4];
        fixtureTele->reserved[0] = kTask18StopFixture;
        bool workerEntered = false;
        for (int i = 0; i < 50; ++i) {
            if (fixtureTele->reserved[1] == kTask18StopFixture) {
                workerEntered = true;
                break;
            }
            Sleep(20);
        }
        check("Stop timeout: trusted worker blocker entered", workerEntered);
        check("Stop timeout: UnlockForProcess returns after bounded wait",
              cfg->UnlockForProcess() == S_OK);
        const auto* stopped = Task18Tail(tele);
        HANDLE retainedParam = OpenFileMappingW(FILE_MAP_READ, FALSE,
                                                AuraApoParamsName());
        char stopDetail[224];
        snprintf(stopDetail, sizeof(stopDetail),
                 "seat=%ld gen=%lu->%lu stop=%lu cleanup=%lu->%lu module=%p param=%p",
                 (long)tele->seatState, (unsigned long)genBeforeStop,
                 (unsigned long)stopped->engineLoadGen,
                 (unsigned long)stopped->stopStatus,
                 (unsigned long)cleanupBeforeStop,
                 (unsigned long)fixtureTele->reserved[4],
                 (void*)GetModuleHandleW(L"auradsp_engine_apo.dll"),
                 (void*)retainedParam);
        check("Stop timeout retains host mappings, engine and DLL",
              workerEntered && tele->seatState == 1 && retainedParam != nullptr &&
                  stopped->engineLoadGen == genBeforeStop &&
                  stopped->stopStatus == 1 &&
                  fixtureTele->reserved[4] == cleanupBeforeStop &&
                  GetModuleHandleW(L"auradsp_engine_apo.dll") != nullptr,
              stopDetail);
        if (retainedParam) CloseHandle(retainedParam);
        Sleep(5000);  // blocker has now certainly returned; worker can exit
        check("Stop timeout: later Lock retries confirmed cleanup",
              cfg->LockForProcess(1, pins, 1, pouts) == S_OK);
        Sleep(400);
        check("Stop timeout: host cleanup ran and new generation starts cleanly",
              tele->seatState == 1 &&
                  Task18Tail(tele)->engineLoadGen > genBeforeStop &&
                  Task18Tail(tele)->stopStatus == 0 && tele->fault == 0 &&
                  fixtureTele->reserved[4] > cleanupBeforeStop &&
                  GetModuleHandleW(L"auradsp_engine_apo.dll") != nullptr);

        // Exercise destruction immediately after another timeout. The trusted
        // final-wait hook returns WAIT_FAILED; owner destruction must transfer
        // the heap host and a self-module reference to the still-live worker.
        const uint32_t cleanupBeforeDestroy = fixtureTele->reserved[4];
        fixtureTele->reserved[1] = 0;
        fixtureTele->reserved[0] = kTask18StopFixture;
        workerEntered = false;
        for (int i = 0; i < 50; ++i) {
            if (fixtureTele->reserved[1] == kTask18StopFixture) {
                workerEntered = true;
                break;
            }
            Sleep(20);
        }
        check("Destroy timeout: trusted worker blocker re-entered", workerEntered);
        fixtureTele->reserved[3] = kTask18WaitFailureFixture;
        // No preceding Unlock here: final owner destruction itself performs the
        // bounded Stop (which times out) and then hits the injected final-wait
        // failure while the worker is still inside its 4.5s blocker.
        rt->Release();
        cfg->Release();
        apo->Release();
        unk->Release();
        rt = nullptr;
        cfg = nullptr;
        apo = nullptr;
        unk = nullptr;
        // Drop the test's own APO module reference immediately. A live detached
        // worker must still keep its code and heap context valid.
        FreeLibrary(dll);
        dll = nullptr;
        char destroyDetail[224];
        snprintf(destroyDetail, sizeof(destroyDetail),
                 "entered=%d seat=%ld cleanup=%lu->%lu stop=%lu engine=%p apo=%p",
                 workerEntered ? 1 : 0, (long)tele->seatState,
                 (unsigned long)cleanupBeforeDestroy,
                 (unsigned long)fixtureTele->reserved[4],
                 (unsigned long)Task18Tail(tele)->stopStatus,
                 (void*)GetModuleHandleW(L"auradsp_engine_apo.dll"),
                 (void*)GetModuleHandleW(L"AuraApoTrustedTest.dll"));
        check("Destroy wait failure retains worker context, resources and modules",
              workerEntered && tele->seatState == 1 &&
                  fixtureTele->reserved[4] == cleanupBeforeDestroy &&
                  Task18Tail(tele)->stopStatus == 2 &&
                  GetModuleHandleW(L"auradsp_engine_apo.dll") != nullptr &&
                  GetModuleHandleW(L"AuraApoTrustedTest.dll") != nullptr,
              destroyDetail);
        Sleep(5000);
        check("Destroy wait failure: exited worker releases retained context safely",
              tele->seatState == 0 &&
                  fixtureTele->reserved[4] > cleanupBeforeDestroy &&
                  GetModuleHandleW(L"auradsp_engine_apo.dll") == nullptr &&
                  GetModuleHandleW(L"AuraApoTrustedTest.dll") == nullptr);
    }

    if (cfg) check("UnlockForProcess", cfg->UnlockForProcess() == S_OK);
    if (tele) {
        check("seat released after unlock", tele->seatState == 0);
        UnmapViewOfFile(tele);
    }
    if (hTele) CloseHandle(hTele);
    if (rt) rt->Release();
    if (cfg) cfg->Release();
    if (apo) apo->Release();
    if (unk) unk->Release();
    if (fmt) fmt->Release();
    CoUninitialize();
    CloseHandle(testPluginMap);
    if (paramFixture) CloseHandle(paramFixture);
    DeleteFileW(irHalf);
    DeleteFileW(irQuarter);
    DeleteFileW(ddcHalf);
    DeleteFileW(ddcQuarter);
    DeleteFileW(irMissing);
    DeleteFileW(ddcMissing);
    printf("apo_engine_test %s: %s (%d failures)\n",
           trustedFixture ? "trusted-fixture" : "production",
           g_fail ? "FAIL" : "PASS", g_fail);
    return g_fail ? 1 : 0;
}

int main() {
    const int production = RunApoEngineSuite(false);
    wchar_t trustedPath[MAX_PATH] = {0};
    GetModuleFileNameW(nullptr, trustedPath, MAX_PATH);
    wchar_t* slash = wcsrchr(trustedPath, L'\\');
    wcscpy(slash ? slash + 1 : trustedPath, L"AuraApoTrustedTest.dll");
    if (GetFileAttributesW(trustedPath) == INVALID_FILE_ATTRIBUTES) {
        printf("[SKIP] trusted fixture suite (AuraApoTrustedTest.dll absent)\n");
        return production;
    }
    const int trusted = RunApoEngineSuite(true);
    return production != 0 ? production : trusted;
}
