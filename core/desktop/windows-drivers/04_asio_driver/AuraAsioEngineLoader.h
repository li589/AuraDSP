// AuraAsioEngineLoader.h — AuraDSP 虚拟 ASIO 驱动动态引擎装载器
//
// 依据：docs/adr/ADR-008-asio-driver-identity-and-architecture.md
// 规范：Zero-DSP 分离原则，驱动内部严禁编译或静态链接 DSP 算法，
//       必须通过 LoadLibraryW/GetProcAddress 动态绑定 auradsp_engine.dll。
#pragma once

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "auradsp_engine.h"  // auradsp_viz_frame（S4 频谱回传）

class AuraAsioEngineLoader {
public:
    using FnEngCreate = void*(__cdecl*)(float sampleRate, int maxBlockFrames);
    using FnEngDestroy = void(__cdecl*)(void* handle);
    using FnEngProcess = void(__cdecl*)(void* handle, const float* in, float* out, int frames);
    using FnEngSetParam = int(__cdecl*)(void* handle, const char* id, const void* value, unsigned int bytes);
    using FnEngGetParam = int(__cdecl*)(void* handle, const char* id, void* outValue, unsigned int bytes);
    // S4：viz 帧读取（频谱回传）。帧结构以引擎公共头为准。
    using FnEngVizRead = uint32_t(__cdecl*)(void* handle, auradsp_viz_frame* out, uint32_t maxFrames);

    AuraAsioEngineLoader() = default;
    ~AuraAsioEngineLoader() {
        Unload();
    }

    bool Load(const std::wstring& hint = L"") {
        if (m_hModule && m_pfnProcess) return true;

        // 加载纪律（2026-11-22 审查 N4 裁定，与 APO 侧 A2 对齐）：
        // 候选只许两处——① 本驱动 DLL 同目录；② 安装目录
        // （Program Files\AuraDSP）。旧版的环境变量覆盖、开发树
        // 相对路径、宿主 EXE 目录与裸名回落已全部删除：本 DLL 跑在
        // DAW 进程内，上述任一路径都等于让宿主目录/环境决定加载
        // 哪份引擎，属于 DLL 劫持面。两处皆缺 → 装载失败、驱动
        // 直通（fail-closed），不做任何全局搜索。
        std::vector<std::wstring> candidates;
        if (!hint.empty()) candidates.push_back(hint);

        // 1. 本驱动 DLL 所在目录
        HMODULE hThisMod = nullptr;
        GetModuleHandleExW(
            GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
            reinterpret_cast<LPCWSTR>(&AuraAsioEngineLoader::GetThisModuleAddress),
            &hThisMod);
        if (hThisMod) {
            wchar_t modPath[MAX_PATH] = {0};
            if (GetModuleFileNameW(hThisMod, modPath, MAX_PATH) > 0) {
                std::wstring s(modPath);
                size_t k = s.find_last_of(L"\\/");
                std::wstring dir = (k == std::wstring::npos) ? L"." : s.substr(0, k);
                candidates.push_back(dir + L"\\auradsp_engine.dll");
            }
        }

        // 2. 标准安装目录（至多到此为止）
        candidates.push_back(L"C:\\Program Files\\AuraDSP\\auradsp_engine.dll");
        candidates.push_back(L"C:\\Program Files\\AuraDSP\\bin\\auradsp_engine.dll");

        for (const auto& path : candidates) {
            HMODULE h = LoadLibraryW(path.c_str());
            if (h) {
                auto fnCreate = (FnEngCreate)GetProcAddress(h, "auradsp_create");
                auto fnDestroy = (FnEngDestroy)GetProcAddress(h, "auradsp_destroy");
                auto fnProcess = (FnEngProcess)GetProcAddress(h, "auradsp_process");
                auto fnSetParam = (FnEngSetParam)GetProcAddress(h, "auradsp_set_param");
                auto fnGetParam = (FnEngGetParam)GetProcAddress(h, "auradsp_get_param");
                // viz 为可选绑定：缺失只丢频谱回传，不否决引擎装载。
                auto fnVizRead = (FnEngVizRead)GetProcAddress(h, "auradsp_viz_read");

                if (fnCreate && fnDestroy && fnProcess) {
                    m_hModule = h;
                    m_pfnCreate = fnCreate;
                    m_pfnDestroy = fnDestroy;
                    m_pfnProcess = fnProcess;
                    m_pfnSetParam = fnSetParam;
                    m_pfnGetParam = fnGetParam;
                    m_pfnVizRead = fnVizRead;
                    m_loadedPath = path;
                    return true;
                }
                FreeLibrary(h);
            }
        }
        return false;
    }

    void Unload() {
        if (m_hModule) {
            FreeLibrary(m_hModule);
            m_hModule = nullptr;
        }
        m_pfnCreate = nullptr;
        m_pfnDestroy = nullptr;
        m_pfnProcess = nullptr;
        m_pfnSetParam = nullptr;
        m_pfnGetParam = nullptr;
        m_pfnVizRead = nullptr;
        m_loadedPath.clear();
    }

    bool IsLoaded() const {
        return m_hModule != nullptr && m_pfnProcess != nullptr;
    }

    const std::wstring& GetLoadedPath() const {
        return m_loadedPath;
    }

    void* CreateEngine(float sampleRate, int maxBlockFrames) {
        if (m_pfnCreate) {
            return m_pfnCreate(sampleRate, maxBlockFrames);
        }
        return nullptr;
    }

    void DestroyEngine(void* handle) {
        if (m_pfnDestroy && handle) {
            m_pfnDestroy(handle);
        }
    }

    // S4：读引擎 viz 帧（频谱/电平）。返回读到的帧数；未绑定
    // 或无帧为 0。
    uint32_t VizRead(void* handle, auradsp_viz_frame* out, uint32_t maxFrames) {
        if (m_pfnVizRead && handle && out) {
            return m_pfnVizRead(handle, out, maxFrames);
        }
        return 0;
    }

    bool HasViz() const { return m_pfnVizRead != nullptr; }

    void Process(void* handle, const float* in, float* out, int frames) {
        if (m_pfnProcess && handle) {
            m_pfnProcess(handle, in, out, frames);
        } else if (out && in && frames > 0) {
            memcpy(out, in, (size_t)frames * 2 * sizeof(float));
        }
    }

    int SetParam(void* handle, const char* id, const void* value, unsigned int bytes) {
        if (m_pfnSetParam && handle) {
            return m_pfnSetParam(handle, id, value, bytes);
        }
        return -1;
    }

    int GetParam(void* handle, const char* id, void* outValue, unsigned int bytes) {
        if (m_pfnGetParam && handle) {
            return m_pfnGetParam(handle, id, outValue, bytes);
        }
        return -1;
    }

    int ApplyParamsString(void* handle, const char* s) {
        if (!s || !*s || !handle || !m_pfnSetParam) return -1;
        char buf[4096] = {0};
        strncpy_s(buf, s, sizeof(buf) - 1);
        int applied = 0;
        char* nextTok = nullptr;
        for (char* tok = strtok_s(buf, ";", &nextTok); tok != nullptr; tok = strtok_s(nullptr, ";", &nextTok)) {
            char* eq = strchr(tok, '=');
            if (!eq || eq == tok) continue;
            *eq = '\0';
            const char* id = tok;
            const char* vs = eq + 1;
            if (strchr(vs, '.') || strchr(vs, 'e') || strchr(vs, 'E')) {
                const float f = (float)atof(vs);
                if (m_pfnSetParam(handle, id, &f, sizeof(float)) == 0) ++applied;
            } else {
                const int32_t iv = (int32_t)atoi(vs);
                if (m_pfnSetParam(handle, id, &iv, sizeof(int32_t)) == 0) ++applied;
            }
        }
        return applied;
    }

private:
    static void GetThisModuleAddress() {}

    HMODULE m_hModule = nullptr;
    std::wstring m_loadedPath;
    FnEngCreate m_pfnCreate = nullptr;
    FnEngDestroy m_pfnDestroy = nullptr;
    FnEngProcess m_pfnProcess = nullptr;
    FnEngSetParam m_pfnSetParam = nullptr;
    FnEngGetParam m_pfnGetParam = nullptr;
    FnEngVizRead m_pfnVizRead = nullptr;
};
