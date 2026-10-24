#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef int (*PFN_vaio_detect)(char* out, int cap);
typedef int (*PFN_vaio_start)(const char* engine_dll, const char* params_json, const char* output_endpoint_substr);
typedef int (*PFN_vaio_stop)();
typedef int (*PFN_vaio_status)(char* out, int cap);
typedef int (*PFN_vaio_set_param)(const char* id, int isFloat, const void* v4);
typedef int (*PFN_vaio_set_param_str)(const char* id, const char* utf8, int bytes);
typedef int (*PFN_vaio_get_param)(const char* id, int isFloat, void* out4);
typedef int (*PFN_vaio_get_param_str)(const char* id, char* out, int cap);
typedef int (*PFN_vaio_viz_read)(void* out408, int count);
typedef int (*PFN_vaio_bypass)(int on);
typedef int (*PFN_vaio_test_start)(int kind, const float* pcm, int frames, int ch, int rate);
typedef int (*PFN_vaio_test_stop)();

int main(int argc, char* argv[])
{
    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);
    printf("=== AuraVAIO Bridge Smoke Test ===\n");
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

    PFN_vaio_detect      p_detect      = (PFN_vaio_detect)GetProcAddress(hBridge, "vaio_detect");
    PFN_vaio_start       p_start       = (PFN_vaio_start)GetProcAddress(hBridge, "vaio_start");
    PFN_vaio_stop        p_stop        = (PFN_vaio_stop)GetProcAddress(hBridge, "vaio_stop");
    PFN_vaio_status      p_status      = (PFN_vaio_status)GetProcAddress(hBridge, "vaio_status");
    PFN_vaio_set_param   p_set_param   = (PFN_vaio_set_param)GetProcAddress(hBridge, "vaio_set_param");
    PFN_vaio_set_param_str p_set_param_str = (PFN_vaio_set_param_str)GetProcAddress(hBridge, "vaio_set_param_str");
    PFN_vaio_get_param   p_get_param   = (PFN_vaio_get_param)GetProcAddress(hBridge, "vaio_get_param");
    PFN_vaio_get_param_str p_get_param_str = (PFN_vaio_get_param_str)GetProcAddress(hBridge, "vaio_get_param_str");
    PFN_vaio_viz_read    p_viz_read    = (PFN_vaio_viz_read)GetProcAddress(hBridge, "vaio_viz_read");
    PFN_vaio_bypass      p_bypass      = (PFN_vaio_bypass)GetProcAddress(hBridge, "vaio_bypass");
    PFN_vaio_test_start  p_test_start  = (PFN_vaio_test_start)GetProcAddress(hBridge, "vaio_test_start");
    PFN_vaio_test_stop   p_test_stop   = (PFN_vaio_test_stop)GetProcAddress(hBridge, "vaio_test_stop");

    if (!p_detect || !p_start || !p_stop || !p_status || !p_set_param ||
        !p_set_param_str || !p_get_param || !p_get_param_str || !p_viz_read ||
        !p_bypass || !p_test_start || !p_test_stop)
    {
        printf("[FAIL] Missing one or more required C ABI exports!\n");
        return 2;
    }
    printf("[PASS] All 12 C ABI exports resolved successfully\n");

    char buf[4096];
    memset(buf, 0, sizeof(buf));
    int drc = p_detect(buf, sizeof(buf));
    printf("[INFO] vaio_detect rc=%d:\n  %s\n", drc, buf);

    if (strstr(buf, "\"found\":true") == NULL)
    {
        printf("[WARN] Driver not found in detect output, start may fail\n");
    }

    printf("[STEP] Starting vaio_start...\n");
    int src = p_start("", "", "");
    printf("[INFO] vaio_start rc=%d\n", src);

    memset(buf, 0, sizeof(buf));
    p_status(buf, sizeof(buf));
    printf("[INFO] vaio_status:\n  %s\n", buf);

    if (src != 0)
    {
        printf("[FAIL] vaio_start failed (rc=%d)\n", src);
        return 3;
    }

    printf("[STEP] Testing parameter set...\n");
    int ival = 1;
    p_set_param("bass.enable", 0, &ival);
    float fval = 2.5f;
    p_set_param("bass.gain", 1, &fval);

    printf("[STEP] Testing test signal start (kind 1: tone)...\n");
    int tsrc = p_test_start(1, NULL, 0, 0, 0);
    printf("[INFO] vaio_test_start rc=%d\n", tsrc);

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
    printf("[INFO] vaio_status after pump:\n  %s\n", buf);

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
    printf("[INFO] vaio_status after stop:\n  %s\n", buf);

    if (strstr(buf, "\"running\":false") == NULL)
    {
        printf("[FAIL] Expected running:false after stop\n");
        return 4;
    }

    printf("=== [SUCCESS] AuraVAIO Bridge Verified Successfully! ===\n");
    return 0;
}
