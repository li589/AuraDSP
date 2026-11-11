/*++
Module Name:

    dlog_perm_test.cpp

Abstract:

    验证驱动 GET_DEBUG_LOG 的访问控制加固（审计·调试低6）。

    加固前的语义（漏洞）：共享环**解映射后**，任何本地进程都能读走并清空
    驱动调试日志；从未 MAP 过的进程也能读。

    加固后的语义：日志的读取权限跟随"最近一次成功 MAP 的进程"
    （g_pDebugLogHolder）——映射期间只有持有者可读，解映射后仍只有持有者
    可读，直到该进程退出（Cleanup 路径清除持有者记录）。

    本工具需要**两个进程**协作判定，故提供多种模式：

      hold  <sec>  MAP 共享环（成为 holder），期间周期读日志，sec 秒后 UNMAP
      mapunmap <sec>  MAP 后立刻 UNMAP，但进程仍存活 sec 秒
                      （用来验证"解映射后仍受保护"）
      read           不 MAP，直接读日志
      sleep <sec>    仅等待（编排用）

    预期矩阵（由外部编排，见 tools/dlog_perm_test.md）：
      T1 A=mapunmap 存活期间，B=read  → 拒绝（ERROR_ACCESS_DENIED=5）
      T2 A=hold 期间，A 自己 read      → 成功
      T3 A 退出后，B=read              → 成功（holder 随进程退出清除）
      T4 无 A 时，B=read              → 成功（从未 MAP 过时不设防）

--*/

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../../common/AuraVaioIpc.h"

static HANDLE g_hDev = INVALID_HANDLE_VALUE;

static BOOL OpenDev(void)
{
    g_hDev = CreateFileW(AURA_VAIO_USER_DEVICE_PATH,
                         GENERIC_READ | GENERIC_WRITE,
                         FILE_SHARE_READ | FILE_SHARE_WRITE,
                         NULL, OPEN_EXISTING, 0, NULL);
    if (g_hDev == INVALID_HANDLE_VALUE) {
        printf("[dlog] CreateFile failed err=%lu\n", GetLastError());
        return FALSE;
    }
    return TRUE;
}

static BOOL ReadDebugLog(DWORD *outErr)
{
    AURA_DEBUG_LOG log;
    DWORD ret = 0;
    memset(&log, 0, sizeof(log));
    if (!DeviceIoControl(g_hDev, IOCTL_AURAVAIO_GET_DEBUG_LOG,
                         NULL, 0, &log, sizeof(log), &ret, NULL)) {
        *outErr = GetLastError();
        printf("[dlog] GET_DEBUG_LOG DENIED err=%lu\n", *outErr);
        return FALSE;
    }
    *outErr = 0;
    printf("[dlog] GET_DEBUG_LOG OK count=%lu writeIndex=%lu\n",
           log.Count, log.WriteIndex);
    return TRUE;
}

static BOOL MapRing(PVOID *outAddr)
{
    AURA_VAIO_MAP_RESPONSE resp;
    DWORD ret = 0;
    memset(&resp, 0, sizeof(resp));
    if (!DeviceIoControl(g_hDev, IOCTL_AURAVAIO_MAP_SHARED_RING,
                         NULL, 0, &resp, sizeof(resp), &ret, NULL)) {
        printf("[dlog] MAP failed err=%lu\n", GetLastError());
        return FALSE;
    }
    *outAddr = resp.UserAddress;
    printf("[dlog] MAP ok userVA=%p total=%lu\n",
           resp.UserAddress, resp.TotalMappedSizeBytes);
    return TRUE;
}

static void UnmapRing(PVOID addr)
{
    AURA_VAIO_UNMAP_REQUEST req;
    DWORD ret = 0;
    req.UserAddress = addr;
    if (!DeviceIoControl(g_hDev, IOCTL_AURAVAIO_UNMAP_SHARED_RING,
                         &req, sizeof(req), NULL, 0, &ret, NULL)) {
        printf("[dlog] UNMAP failed err=%lu\n", GetLastError());
        return;
    }
    printf("[dlog] UNMAP ok\n");
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        printf("usage: dlog_perm_test.exe hold <sec> | mapunmap <sec> | read | sleep <sec>\n");
        return 2;
    }
    const char *mode = argv[1];
    int secs = (argc >= 3) ? atoi(argv[2]) : 5;

    if (strcmp(mode, "sleep") == 0) {
        Sleep((DWORD)secs * 1000);
        return 0;
    }

    if (!OpenDev()) {
        return 3;
    }

    if (strcmp(mode, "read") == 0) {
        DWORD err = 0;
        BOOL ok = ReadDebugLog(&err);
        CloseHandle(g_hDev);
        /* 0=读到了，5=被拒（ERROR_ACCESS_DENIED） */
        return ok ? 0 : ((err == ERROR_ACCESS_DENIED) ? 5 : 6);
    }

    if (strcmp(mode, "hold") == 0) {
        PVOID addr = NULL;
        if (!MapRing(&addr)) { CloseHandle(g_hDev); return 4; }
        for (int i = 0; i < secs * 10; ++i) {
            DWORD err = 0;
            ReadDebugLog(&err);
            Sleep(100);
        }
        UnmapRing(addr);
        CloseHandle(g_hDev);
        return 0;
    }

    if (strcmp(mode, "mapunmap") == 0) {
        PVOID addr = NULL;
        if (!MapRing(&addr)) { CloseHandle(g_hDev); return 4; }
        UnmapRing(addr);
        /* 关键窗口：已 UNMAP、进程仍存活 —— 加固后此期间他人仍应被拒 */
        printf("[dlog] READY\n");
        fflush(stdout);
        Sleep((DWORD)secs * 1000);
        CloseHandle(g_hDev);
        return 0;
    }

    printf("[dlog] unknown mode: %s\n", mode);
    CloseHandle(g_hDev);
    return 2;
}
