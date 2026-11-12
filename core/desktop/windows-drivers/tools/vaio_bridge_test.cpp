// vaio_bridge_test.cpp — AuraVAIO 桥冒烟测试（统一桥 ABI `ab_*`）
//
// 历史：本工具最初按 VAIO 专属前缀 `vaio_*` 导出编写；2026-10-30 导出面
// 清理后三桥只导出 `ab_*`（见 bridge/common/aurabridge.h 文件头），本工具
// 未同步更新，一度沦为「导出全空、调用即崩」的过期件（第十七轮取证时
// 定罪）。2026-11-12 按现行契约整体迁移到 `ab_*`，签名以 aurabridge.h
// 为准：
//   - ab_start(engine_dll, params_json, config_json)：VAIO 的落点端点经
//     config_json 的 {"endpoint":"子串"} 指定；传 "" = 桥内默认选择。
//   - params_json 为 "id=f1.5;id2=i3" 形式（非 JSON 对象）。
//   - ab_viz_read 帧为 1600B（ABI v2），电平偏移 272（见 Phase B 注释）。
//
// 构建（独立小工具，不进 CMake）：
//   cl /utf-8 /EHsc /O2 vaio_bridge_test.cpp /link ole32.lib
// 运行：与 auravaio_bridge.dll / auradsp_engine.dll 同目录（或 DLL 在 PATH
// 中），且 AuraVAIO 驱动已安装。退出码 0 = 全部通过。
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef unsigned (*PFN_ab_abi_version)(void);
typedef int (*PFN_ab_capabilities)(char* out, int cap);
typedef int (*PFN_ab_detect)(char* out, int cap);
typedef int (*PFN_ab_start)(const char* engine_dll, const char* params_json, const char* config_json);
typedef int (*PFN_ab_stop)();
typedef int (*PFN_ab_status)(char* out, int cap);
typedef int (*PFN_ab_set_param)(const char* id, int isFloat, const void* v4);
typedef int (*PFN_ab_set_param_str)(const char* id, const char* utf8, int bytes);
typedef int (*PFN_ab_get_param)(const char* id, int isFloat, void* out4);
typedef int (*PFN_ab_get_param_str)(const char* id, char* out, int cap);
typedef int (*PFN_ab_viz_read)(void* out1600, int count);
typedef int (*PFN_ab_bypass)(int on);
typedef int (*PFN_ab_test_start)(int kind, const float* pcm, int frames, int ch, int rate);
typedef int (*PFN_ab_test_stop)();

int main(int argc, char* argv[])
{
    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);
    printf("=== AuraVAIO Bridge Smoke Test (ab_* ABI) ===\n");
    // 白噪声专项 S2 附带（2026-11-12）：桥/引擎按裸名加载只搜 exe
    // 所在目录，与 argv[1] 给的 bridgeDir 无关——测试 exe 不与桥
    // 同目录时恒 126 误报（guest 实测）。有目录参数先设 DLL 搜索
    // 目录，裸名加载与桥自身依赖解析都落到该目录。
    if (argc > 1 && argv[1] && argv[1][0])
    {
        SetDllDirectoryA(argv[1]);
    }
    HMODULE hBridge = LoadLibraryA("auravaio_bridge.dll");
    if (!hBridge)
    {
        DWORD err = GetLastError();
        printf("[FAIL] Could not load auravaio_bridge.dll (GetLastError=%lu)\n", err);
        char msgBuf[512];
        FormatMessageA(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS,
                       NULL, err, MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT),
                       msgBuf, sizeof(msgBuf), NULL);
        printf("[FAIL] Error msg: %s\n", msgBuf);
        return 1;
    }
    printf("[PASS] Loaded auravaio_bridge.dll\n");

    HMODULE hEng = LoadLibraryA("auradsp_engine.dll");
    if (!hEng)
    {
        DWORD err = GetLastError();
        printf("[WARN] Direct LoadLibraryA(auradsp_engine.dll) failed (GetLastError=%lu)\n", err);
        char msgBuf[512];
        FormatMessageA(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS,
                       NULL, err, MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT),
                       msgBuf, sizeof(msgBuf), NULL);
        printf("[WARN] Engine error msg: %s\n", msgBuf);
    }
    else
    {
        printf("[PASS] Direct LoadLibraryA(auradsp_engine.dll) succeeded\n");
        FreeLibrary(hEng);
    }

    PFN_ab_abi_version   p_abi_version  = (PFN_ab_abi_version)GetProcAddress(hBridge, "ab_abi_version");
    PFN_ab_capabilities  p_capabilities = (PFN_ab_capabilities)GetProcAddress(hBridge, "ab_capabilities");
    PFN_ab_detect        p_detect       = (PFN_ab_detect)GetProcAddress(hBridge, "ab_detect");
    PFN_ab_start         p_start        = (PFN_ab_start)GetProcAddress(hBridge, "ab_start");
    PFN_ab_stop          p_stop         = (PFN_ab_stop)GetProcAddress(hBridge, "ab_stop");
    PFN_ab_status        p_status       = (PFN_ab_status)GetProcAddress(hBridge, "ab_status");
    PFN_ab_set_param     p_set_param    = (PFN_ab_set_param)GetProcAddress(hBridge, "ab_set_param");
    PFN_ab_set_param_str p_set_param_str = (PFN_ab_set_param_str)GetProcAddress(hBridge, "ab_set_param_str");
    PFN_ab_get_param     p_get_param    = (PFN_ab_get_param)GetProcAddress(hBridge, "ab_get_param");
    PFN_ab_get_param_str p_get_param_str = (PFN_ab_get_param_str)GetProcAddress(hBridge, "ab_get_param_str");
    PFN_ab_viz_read      p_viz_read     = (PFN_ab_viz_read)GetProcAddress(hBridge, "ab_viz_read");
    PFN_ab_bypass        p_bypass       = (PFN_ab_bypass)GetProcAddress(hBridge, "ab_bypass");
    PFN_ab_test_start    p_test_start   = (PFN_ab_test_start)GetProcAddress(hBridge, "ab_test_start");
    PFN_ab_test_stop     p_test_stop    = (PFN_ab_test_stop)GetProcAddress(hBridge, "ab_test_stop");

    if (!p_abi_version || !p_capabilities || !p_detect || !p_start || !p_stop ||
        !p_status || !p_set_param || !p_set_param_str || !p_get_param ||
        !p_get_param_str || !p_viz_read || !p_bypass || !p_test_start || !p_test_stop)
    {
        printf("[FAIL] Missing one or more required ab_* exports!\n");
        return 2;
    }
    printf("[PASS] All 14 ab_* exports resolved successfully\n");
    printf("[INFO] ab_abi_version = %u (contract expects 1)\n", p_abi_version());

    char buf[4096];
    memset(buf, 0, sizeof(buf));
    int crc = p_capabilities(buf, sizeof(buf));
    printf("[INFO] ab_capabilities rc=%d:\n  %s\n", crc, buf);

    memset(buf, 0, sizeof(buf));
    int drc = p_detect(buf, sizeof(buf));
    printf("[INFO] ab_detect rc=%d:\n  %s\n", drc, buf);

    if (drc < 0)
    {
        printf("[WARN] ab_detect failed, start may fail\n");
    }

    printf("[STEP] Starting ab_start (auto engine, no params, default endpoint)...\n");
    int src = p_start("", "", "");
    printf("[INFO] ab_start rc=%d\n", src);

    memset(buf, 0, sizeof(buf));
    p_status(buf, sizeof(buf));
    printf("[INFO] ab_status:\n  %s\n", buf);

    if (src != 0)
    {
        printf("[FAIL] ab_start failed (rc=%d)\n", src);
        return 3;
    }

    printf("[STEP] Testing parameter set...\n");
    int ival = 1;
    p_set_param("bass.enable", 0, &ival);
    float fval = 2.5f;
    p_set_param("bass.gain", 1, &fval);

    printf("[STEP] Testing test signal start (kind 1: sine)...\n");
    int tsrc = p_test_start(1, NULL, 0, 0, 0);
    printf("[INFO] ab_test_start rc=%d\n", tsrc);

    printf("[STEP] Polling pump loop and visualization for 1.5 seconds...\n");
    for (int i = 0; i < 15; i++)
    {
        Sleep(100);
        // [Phase B] ABI v2：viz 帧实际 1600B（引擎按 sizeof(auradsp_viz_frame) 写）。
        // 此前 512B 栈缓冲接 1600B 帧 = 栈溢出；且 L/R 偏移写死 12 落在
        // timestamp_ms 中段——level_l_dbfs 真实偏移 = 8+8+128+128 = 272。
        char viz[1600];
        int vcnt = p_viz_read(viz, 1);
        if (vcnt > 0)
        {
            // Viz frame layout: seq(8B) + ts(8B) + spectrum(128B) + eq_in(128B) → level_l/r at 272
            float* flt = (float*)(viz + 272);
            printf("  Poll %2d: viz frames=%d, L=%.2fdB, R=%.2fdB\n", i, vcnt, flt[0], flt[1]);
        }
    }

    memset(buf, 0, sizeof(buf));
    p_status(buf, sizeof(buf));
    printf("[INFO] ab_status after pump:\n  %s\n", buf);

    printf("[STEP] Testing bypass toggle...\n");
    p_bypass(1);
    Sleep(50);
    p_bypass(0);

    printf("[STEP] Stopping test signal...\n");
    p_test_stop();

    printf("[STEP] Stopping bridge...\n");
    p_stop();

    memset(buf, 0, sizeof(buf));
    p_status(buf, sizeof(buf));
    printf("[INFO] ab_status after stop:\n  %s\n", buf);

    if (strstr(buf, "\"running\":false") == NULL)
    {
        printf("[FAIL] Expected running:false after stop\n");
        return 4;
    }

    printf("=== [SUCCESS] AuraVAIO Bridge Verified Successfully! ===\n");
    return 0;
}
