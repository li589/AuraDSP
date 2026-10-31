/*
 * aura_eel_ram.h — EEL2 gmem 区（64MB float）的惰性物理提交分配器。
 *
 * 背景（2026-10-31 内存优化）：EEL2 每个 VM 的 gmem 是 1<<24 个 float（64MB）。
 * VB 回调模式下一个进程会创建 9 个引擎实例（8 条总线 + 1 个软件引擎），
 * 每个实例都编译同一份 liveprog 脚本；脚本只要引用 gmem（x[y]/tds/IIR 分频等）
 * 就会为每个 VM 实打实提交 64MB，实测 9 × 64MB = 576MB 常驻。
 *
 * 本分配器把 64MB 改成「地址空间保留 + 按页惰性提交」：
 *   - Windows：VirtualAlloc(MEM_RESERVE) + PAGE_NOACCESS，首次访问触发 VEH
 *     只提交出错的 64KB 页；脚本只碰前几 KB 时物理内存几乎为零。
 *   - 其他平台：calloc（POSIX 的 calloc/mmap 本来也是惰性零页，无需额外机制）。
 *
 * 语义保持：新提交的页天然为 0；重新编译前的清零只清「已提交前缀」，
 * 未提交部分仍是零，与旧「全量 memset 64MB」等价。
 */
#ifndef AURA_EEL_RAM_H
#define AURA_EEL_RAM_H

#ifdef __cplusplus
extern "C" {
#endif

/* 申请 64MB 逻辑 gmem（物理按需提交）。失败返回 NULL。 */
void *aura_eel_ram_alloc(void);

/* 重新编译前清零：只清已提交前缀（未提交页本就为零）。 */
void aura_eel_ram_clear(void *base);

/* 释放（调用方须保证没有在途访问，影子槽换出守卫已保证）。 */
void aura_eel_ram_free(void *base);

#ifdef __cplusplus
}
#endif

#endif /* AURA_EEL_RAM_H */
