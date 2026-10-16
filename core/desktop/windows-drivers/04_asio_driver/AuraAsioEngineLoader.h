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

class AuraAsioEngineLoader {
public:
    using FnEngCreate = void*(__cdecl*)(float sampleRate, int maxBlockFrames);
    using FnEngDestroy = void(__cdecl*)(void* handle);
    using FnEngProcess = void(__cdecl*)(void* handle, const float* in, float* out, int frames);
    using FnEngSetParam = int(__cdecl*)(void* handle, const char* id, const void* value, unsigned int bytes);
    using FnEngGetParam = int(__cdecl*)(void* handle, const char* id, void* outValue, unsigned int bytes);

    AuraAsioEngineLoader() = default;
    ~AuraAsioEngineLoader() {
        Unload();
    }

    bool Load(const std::wstring& hint = L"") {
        if (m_hModule && m_pfnProcess) return true;

        std::vector<std::wstring> candidates;
        if (!hint.empty()) candidates.push_back(hint);

        // 1. 环境变量显式指定优先
        wchar_t envBuf[MAX_PATH] = {0};
        if (GetEnvironmentVariableW(L"AURADSP_ENGINE_DLL", envBuf, MAX_PATH) > 0) {
            candidates.push_back(envBuf);
        }

        // 2. 本驱动 DLL 所在目录及工程相对路径
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
                // windows-drivers/out/Release -> windows/out/Release
                candidates.push_back(dir + L"\\..\\..\\..\\windows\\out\\Release\\auradsp_engine.dll");
            }
        }

        // 3. 当前主进程 EXE 所在目录
        wchar_t exePath[MAX_PATH] = {0};
        if (GetModuleFileNameW(nullptr, exePath, MAX_PATH) > 0) {
            std::wstring s(exePath);
            size_t k = s.find_last_of(L"\\/");
            std::wstring dir = (k == std::wstring::npos) ? L"." : s.substr(0, k);
            candidates.push_back(dir + L"\\auradsp_engine.dll");
            candidates.push_back(dir + L"\\..\\..\\..\\windows\\out\\Release\\auradsp_engine.dll");
        }

        // 4. 标准安装路径与全局搜索
        candidates.push_back(L"C:\\Program Files\\AuraDSP\\auradsp_engine.dll");
        candidates.push_back(L"C:\\Program Files\\AuraDSP\\bin\\auradsp_engine.dll");
        candidates.push_back(L"auradsp_engine.dll");

        for (const auto& path : candidates) {
            HMODULE h = LoadLibraryW(path.c_str());
            if (h) {
                auto fnCreate = (FnEngCreate)GetProcAddress(h, "auradsp_create");
                auto fnDestroy = (FnEngDestroy)GetProcAddress(h, "auradsp_destroy");
                auto fnProcess = (FnEngProcess)GetProcAddress(h, "auradsp_process");
                auto fnSetParam = (FnEngSetParam)GetProcAddress(h, "auradsp_set_param");
                auto fnGetParam = (FnEngGetParam)GetProcAddress(h, "auradsp_get_param");

                if (fnCreate && fnDestroy && fnProcess) {
                    m_hModule = h;
                    m_pfnCreate = fnCreate;
                    m_pfnDestroy = fnDestroy;
                    m_pfnProcess = fnProcess;
                    m_pfnSetParam = fnSetParam;
                    m_pfnGetParam = fnGetParam;
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
};
