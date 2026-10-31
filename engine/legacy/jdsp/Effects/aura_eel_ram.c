/*
 * aura_eel_ram.c — EEL2 gmem 区惰性物理提交（Windows: VEH 按页提交）。
 *
 * 详见 aura_eel_ram.h 与 engine/legacy/PATCHES.md P-045。
 */
#include "aura_eel_ram.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "eel2/ns-eel.h"

#define AURA_RAM_BYTES ((size_t)NSEEL_RAM_ITEMSPERBLOCK * sizeof(float))

#ifdef _WIN32

#ifndef AURA_RAM_PRECOMMIT_BYTES
/* 预提交 1MB：绝大多数脚本只用低地址几 KB，预提交避免音频线程首访触发 VEH；
 * 更深的地址由 VEH 按 64KB 页提交。 */
#define AURA_RAM_PRECOMMIT_BYTES (1u * 1024u * 1024u)
#endif
#define AURA_RAM_PAGE_BYTES (64u * 1024u) /* Windows 最小提交粒度 */
#define AURA_RAM_MAX_REGIONS 64

typedef struct {
    void *base;
    size_t committed;
} AuraRamRegion;

static AuraRamRegion g_regions[AURA_RAM_MAX_REGIONS];
static int g_region_count = 0;
static SRWLOCK g_regions_lock = SRWLOCK_INIT;
static INIT_ONCE g_veh_once = INIT_ONCE_STATIC_INIT;
static PVOID g_veh_handle = NULL;

/* 把 [base, base+need) 提交为可读写，返回 1=成功。 */
static int aura_ram_commit_locked(int idx, size_t need) {
    AuraRamRegion *r = &g_regions[idx];
    if (need > AURA_RAM_BYTES) need = AURA_RAM_BYTES;
    if (need <= r->committed) return 1;
    void *p = VirtualAlloc((char *)r->base + r->committed,
                           need - r->committed, MEM_COMMIT, PAGE_READWRITE);
    if (!p) return 0;
    r->committed = need;
    return 1;
}

/* VEH：只处理落在已登记 gmem 区内的访问违规，按页提交后继续执行。 */
static LONG CALLBACK aura_ram_veh(PEXCEPTION_POINTERS info) {
    EXCEPTION_RECORD *er = info ? info->ExceptionRecord : NULL;
    if (!er || er->ExceptionCode != EXCEPTION_ACCESS_VIOLATION) {
        return EXCEPTION_CONTINUE_SEARCH;
    }
    if (er->NumberParameters < 2) return EXCEPTION_CONTINUE_SEARCH;
    ULONG_PTR addr = er->ExceptionInformation[1];
    LONG handled = EXCEPTION_CONTINUE_SEARCH;

    AcquireSRWLockExclusive(&g_regions_lock);
    for (int i = 0; i < g_region_count; ++i) {
        ULONG_PTR base = (ULONG_PTR)g_regions[i].base;
        if (addr >= base && addr < base + AURA_RAM_BYTES) {
            /* 提交到「出错页末尾」即可；一次异常只可能落在未提交页。 */
            size_t need = (size_t)(addr - base) + 1;
            need = (need + AURA_RAM_PAGE_BYTES - 1) & ~(size_t)(AURA_RAM_PAGE_BYTES - 1);
            if (aura_ram_commit_locked(i, need)) {
                handled = EXCEPTION_CONTINUE_EXECUTION;
            }
            break;
        }
    }
    ReleaseSRWLockExclusive(&g_regions_lock);
    return handled;
}

static BOOL CALLBACK aura_ram_init_veh(PINIT_ONCE once, PVOID param, PVOID *ctx) {
    (void)once;
    (void)param;
    (void)ctx;
    /* first=1：尽早处理，避免其它 VEH 先看到我们的占位页。 */
    g_veh_handle = AddVectoredExceptionHandler(1, aura_ram_veh);
    return TRUE; /* 只需执行一次；即使注册失败也返回 TRUE，后续访问会直接崩。 */
}

void *aura_eel_ram_alloc(void) {
    InitOnceExecuteOnce(&g_veh_once, aura_ram_init_veh, NULL, NULL);

    void *base = VirtualAlloc(NULL, AURA_RAM_BYTES, MEM_RESERVE, PAGE_NOACCESS);
    if (!base) return NULL;

    size_t pre = AURA_RAM_PRECOMMIT_BYTES;
    if (pre > AURA_RAM_BYTES) pre = AURA_RAM_BYTES;
    if (!VirtualAlloc(base, pre, MEM_COMMIT, PAGE_READWRITE)) {
        VirtualFree(base, 0, MEM_RELEASE);
        return NULL;
    }

    AcquireSRWLockExclusive(&g_regions_lock);
    if (g_region_count >= AURA_RAM_MAX_REGIONS) {
        ReleaseSRWLockExclusive(&g_regions_lock);
        VirtualFree(base, 0, MEM_RELEASE);
        return NULL;
    }
    g_regions[g_region_count].base = base;
    g_regions[g_region_count].committed = pre;
    ++g_region_count;
    ReleaseSRWLockExclusive(&g_regions_lock);
    return base;
}

void aura_eel_ram_clear(void *base) {
    if (!base) return;
    size_t committed = 0;
    AcquireSRWLockExclusive(&g_regions_lock);
    for (int i = 0; i < g_region_count; ++i) {
        if (g_regions[i].base == base) {
            committed = g_regions[i].committed;
            break;
        }
    }
    ReleaseSRWLockExclusive(&g_regions_lock);
    if (committed) memset(base, 0, committed);
}

void aura_eel_ram_free(void *base) {
    if (!base) return;
    AcquireSRWLockExclusive(&g_regions_lock);
    for (int i = 0; i < g_region_count; ++i) {
        if (g_regions[i].base == base) {
            g_regions[i] = g_regions[g_region_count - 1];
            --g_region_count;
            break;
        }
    }
    ReleaseSRWLockExclusive(&g_regions_lock);
    VirtualFree(base, 0, MEM_RELEASE);
}

#else /* !_WIN32 —— POSIX 的 calloc/mmap 本身按零页惰性提交 */

void *aura_eel_ram_alloc(void) {
    return calloc((size_t)NSEEL_RAM_ITEMSPERBLOCK, sizeof(float));
}

void aura_eel_ram_clear(void *base) {
    if (base) memset(base, 0, AURA_RAM_BYTES);
}

void aura_eel_ram_free(void *base) {
    free(base);
}

#endif
