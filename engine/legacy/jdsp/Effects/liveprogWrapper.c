void NSEEL_HOSTSTUB_EnterMutex() { }
void NSEEL_HOSTSTUB_LeaveMutex() { }
#include "../jdsp_header.h"
#include <time.h>
#ifdef _WIN32
#include <intrin.h>
#endif
/* [PATCHED-AuraDSP P-016 B1] 影子 VM 编译（替代原「持 jdsp_lock 原地编译」）。
 *
 * 背景（全量审查 B1/P0）：原 LiveProgStringParser 持 jdsp_lock 调
 * LiveProgLoadCode→NSEEL_code_compile ×2，而 kAuraStages liveprog lock=1
 * 令 RT 的 stage_liveprog 每块都取同一把锁——EEL 编译按用户自述可达
 * ≥2s（liveprog_page.dart:650），RT 在 EnterCriticalSection 上无限期等待
 * （无超时/无优先级继承）⇒ 整段音频卡死，即「加载脚本时卡顿」的根因。
 *
 * 设计（P-006 mEQ 卷积器双缓冲同范式）：
 *   - JamesDSPLib 预分配 AURA_LIVEPROG_SLOTS(3) 个 LiveProg 槽（各含独立
 *     NSEEL VM），jdsp->eel 指向当前活动快照；
 *   - 控制线程把 EEL 编译进「非活动」影子槽，成功后原子换 jdsp->eel 指针
 *     （x86-64 对齐指针存即原子；RT 块首只读一次，块内不碰换出实例）；
 *   - 在途守卫（双条件，任一满足即可复用换下的槽）：
 *       a) eelInFlight == 0——无任何在途 LiveProgProcess 调用
 *          （RT 入口原子 +1/出口 -1；x86 TSO + lock 前缀全屏障下，
 *          控制侧换指针后读到的 0 严谨证明无调用持有旧快照）。
 *          覆盖音频停流（eelProcCount 冻结）时的连续加载；
 *       b) eelProcCount >= retiredAt——换下后至少跑满 1 个音频块，
 *          保证换出瞬间在途的那次 Process 已返回（retiredAt = 换下时
 *          快照 +1，RT 每块在 LiveProgProcess 入口递增 eelProcCount）。
 *   - 两条件皆不满足（RT 卡在长块内，如 JamesDSPSetSampleRate 重建期间）
 *     时控制侧有界等待（500ms 墙钟），仍无槽返回 -4（引擎忙，可重试），
 *     绝不退化到活动槽原地编译——那会与 RT 竞争（UAF）；
 *   - stage_liveprog 的 lock 标志随之置 0：RT 不再为 liveprog 取锁。
 */
#define kLiveProgSlots AURA_LIVEPROG_SLOTS
#define kLiveProgSlotWaitMs 500

/* RT 在途计数（x86：lock 前缀即全屏障；POSIX：__sync 内建） */
static long lp_inflight_inc(volatile long *p)
{
#ifdef _WIN32
	return _InterlockedIncrement(p);
#else
	return __sync_add_and_fetch((long*)p, 1);
#endif
}
static long lp_inflight_dec(volatile long *p)
{
#ifdef _WIN32
	return _InterlockedDecrement(p);
#else
	return __sync_sub_and_fetch((long*)p, 1);
#endif
}
static long lp_inflight_load(volatile long *p)
{
#ifdef _WIN32
	/* cmpxchg 同值：带 lock 前缀的读，防编译器重排 + 全屏障 */
	return _InterlockedCompareExchange(p, 0, 0);
#else
	return __sync_val_compare_and_swap((long*)p, 0, 0);
#endif
}
static double lp_now_ms(void)
{
#ifdef _WIN32
	return (double)GetTickCount64();
#else
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1000000.0;
#endif
}
static void lp_sleep_ms(unsigned int ms)
{
#ifdef _WIN32
	Sleep(ms);
#else
	struct timespec ts;
	ts.tv_sec = 0;
	ts.tv_nsec = (long)ms * 1000000L;
	nanosleep(&ts, 0);
#endif
}

static void LiveProgSlotInitVM(LiveProg *pg, float fs)
{
	pg->compileSucessfully = 0;
	pg->codehandleInit = 0;
	pg->codehandleProcess = 0;
	pg->retiredAt = 0;
	pg->vmFs = 0;
	pg->input1 = 0;
	pg->input2 = 0;
	pg->vm = NSEEL_VM_alloc(); // create virtual machine
	if (!pg->vm)
		return; /* OOM：槽不可用，编译时自然跳过 */
	pg->vmFs = NSEEL_VM_regvar(pg->vm, "srate");
	if (pg->vmFs)
		*pg->vmFs = fs;
	pg->input1 = NSEEL_VM_regvar(pg->vm, "spl0");
	pg->input2 = NSEEL_VM_regvar(pg->vm, "spl1");
}
void LiveProgConstructor(JamesDSPLib *jdsp)
{
	for (int i = 0; i < kLiveProgSlots; ++i)
		LiveProgSlotInitVM(&jdsp->eelSlots[i], jdsp->fs);
	jdsp->eel = &jdsp->eelSlots[0];
	jdsp->eelProcCount = 0;
	jdsp->eelSwapProc = 0;
	jdsp->eelInFlight = 0;
}
void LiveProgDestructor(JamesDSPLib *jdsp)
{
	for (int i = 0; i < kLiveProgSlots; ++i)
	{
		LiveProg *pg = &jdsp->eelSlots[i];
		if (pg->vm)
		{
			NSEEL_code_free(pg->codehandleInit);
			NSEEL_code_free(pg->codehandleProcess);
			NSEEL_VM_free(pg->vm);
			pg->vm = 0;
			pg->codehandleInit = 0;
			pg->codehandleProcess = 0;
			pg->vmFs = 0;
			pg->input1 = 0;
			pg->input2 = 0;
		}
	}
	jdsp->eel = 0;
}
void LiveProgEnable(JamesDSPLib *jdsp)
{
	LiveProg *eel = jdsp->eel;
	/* 单次对齐 float 写（x86 原子）；RT 最多少读一个新 srate */
	if (eel && eel->vmFs)
		*eel->vmFs = jdsp->fs;
	jdsp->liveprogEnabled = 1;
}
void LiveProgDisable(JamesDSPLib *jdsp)
{
	jdsp->liveprogEnabled = 0;
}
void LiveProgUnload(JamesDSPLib *jdsp)
{
	LiveProg *eel = jdsp->eel;
	/* 单次 int 写（x86 原子）；RT 最多少停用一块 */
	if (eel)
		eel->compileSucessfully = 0;
}
/* 在指定槽上完整编译（freevars→init_memRegion→regvar→compile×2→exec init）。
 * 只动 pg（影子槽），不碰 jdsp->eel；失败时清掉本槽残留 code handle，
 * 保证该槽可再次被选为编译目标。返回 1=成功，<0=失败（错误码口径不变）。 */
static int LiveProgCompileInto(LiveProg *pg, JamesDSPLib *jdsp, char *codeTextInit, char *codeTextProcess)
{
	if (!pg->vm)
		return -1;
	pg->compileSucessfully = 0;
	compileContext *ctx = (compileContext*)pg->vm;
	NSEEL_VM_freevars(pg->vm);
	NSEEL_init_memRegion(pg->vm);
	memset(ctx->ram_state, 0, sizeof(ctx->ram_state));
	pg->vmFs = NSEEL_VM_regvar(pg->vm, "srate");
	if (pg->vmFs)
		*pg->vmFs = jdsp->fs;
	pg->input1 = NSEEL_VM_regvar(pg->vm, "spl0");
	pg->input2 = NSEEL_VM_regvar(pg->vm, "spl1");
	/* [PATCHED-AuraDSP P-001 2026-10-09] 宿主滑块：编译前注册 slider1..8，
	 * 供 engine_api "liveprog.paramN" 写值（freevars 会清掉旧注册，
	 * 因此必须在每次编译内紧跟 init_memRegion 重注册）。
	 * 补丁说明见 engine/legacy/PATCHES.md [PATCHED-AuraDSP P-014 2026-10-16] */
	for (int aura_i = 1; aura_i <= 8; aura_i++)
	{
		char aura_nm[16];
		snprintf(aura_nm, sizeof(aura_nm), "slider%d", aura_i);
		float *aura_v = NSEEL_VM_regvar(pg->vm, aura_nm);
		if (aura_v) *aura_v = 0.0f;
	}
	if (pg->codehandleInit)
	{
		NSEEL_code_free(pg->codehandleInit);
		pg->codehandleInit = 0;
	}
	if (pg->codehandleProcess)
	{
		NSEEL_code_free(pg->codehandleProcess);
		pg->codehandleProcess = 0;
	}
	ctx->functions_common = 0;
	pg->codehandleInit = NSEEL_code_compile_ex(pg->vm, codeTextInit, 0, 1);
	if (!pg->codehandleInit)
	{
		pg->compileSucessfully = 0;
		return -1;
	}
	NSEEL_code_execute(pg->codehandleInit);
	pg->codehandleProcess = NSEEL_code_compile(pg->vm, codeTextProcess, 0);
	if (pg->codehandleInit && pg->codehandleProcess)
	{
		pg->compileSucessfully = 1;
		return 1;
	}
	pg->compileSucessfully = 0;
	/* 失败：清残留，槽可复用（原实现留着 codehandleInit 不释放，
	 * 影子槽语义下必须清零，否则下次编译选它会带旧 code 句柄） */
	if (pg->codehandleInit)
	{
		NSEEL_code_free(pg->codehandleInit);
		pg->codehandleInit = 0;
	}
	if (pg->codehandleProcess)
	{
		NSEEL_code_free(pg->codehandleProcess);
		pg->codehandleProcess = 0;
	}
	return -3;
}
/* 选编译目标槽：非活动 + VM 可用 + 在途守卫通过（双条件任一满足）：
 *   a) eelInFlight == 0（无在途调用，覆盖音频停流）；
 *   b) eelProcCount >= retiredAt（换下后跑满 1 块）。
 * 返回 0 表示暂无可用槽（RT 卡在长块内的极端场景）。 */
static LiveProg *LiveProgPickSlot(JamesDSPLib *jdsp)
{
	const long inFlight = lp_inflight_load(&jdsp->eelInFlight);
	for (int i = 0; i < kLiveProgSlots; ++i)
	{
		LiveProg *s = &jdsp->eelSlots[i];
		if (s == jdsp->eel || !s->vm)
			continue;
		if (inFlight != 0 && jdsp->eelProcCount < s->retiredAt)
			continue;
		return s;
	}
	return 0;
}
/* 影子编译 + 原子换指针。返回 1=成功并已换入；<0=失败（活动快照不变，
 * 旧代码继续有效——这正是 B1 要的「编译失败不影响正在跑的音频」）。 */
static int LiveProgCompileAndSwap(JamesDSPLib *jdsp, char *codeTextInit, char *codeTextProcess)
{
	LiveProg *target = LiveProgPickSlot(jdsp);
	if (!target)
	{
		/* 有界等待（墙钟上界；Sleep(1) 实际粒度可达 ~15ms，故按时间收敛）：
		 * RT 一旦恢复流动，块边界或在途归零即放行一个槽。
		 * 绝不退化到活动槽原地编译——那会与 RT 竞争（UAF）。 */
		const double deadline = lp_now_ms() + kLiveProgSlotWaitMs;
		for (;;)
		{
			lp_sleep_ms(1);
			target = LiveProgPickSlot(jdsp);
			if (target)
				break;
			if (lp_now_ms() >= deadline)
				return -4;
		}
	}
	int rc = LiveProgCompileInto(target, jdsp, codeTextInit, codeTextProcess);
	if (rc != 1)
		return rc;
	LiveProg *prev = jdsp->eel;
	/* 原子换指针（x86-64 对齐指针存即原子；RT 块首只读一次） */
	jdsp->eel = target;
	target->retiredAt = 0;
	if (prev && prev != target)
		prev->retiredAt = jdsp->eelProcCount + 1;
	jdsp->eelSwapProc = jdsp->eelProcCount;
	return 1;
}
int LiveProgStringParser(JamesDSPLib *jdsp, char *eelCode)
{
	/* B1：不再持 jdsp_lock 编译（见文件头）。分段解析是纯局部操作。 */
	long long strLen = (long long)strlen(eelCode);
	const char *initSegment = strstr(eelCode, "@init");
	if (!initSegment)
		return 0;
	else
		initSegment += 6;
	const char *processSegment = strstr(eelCode, "@sample");
	if (!processSegment)
		return -2;
	else
		processSegment += 8;
	char *codeTextInit = (char*)malloc(strLen * sizeof(char));
	char *codeTextProcess = (char*)malloc(strLen * sizeof(char));
	if (!codeTextInit || !codeTextProcess)
	{
		free(codeTextInit);
		free(codeTextProcess);
		return -3;
	}
	memset(codeTextInit, 0, strLen * sizeof(char));
	memset(codeTextProcess, 0, strLen * sizeof(char));
	int errorMsg = 1;
	if (initSegment < processSegment)
	{
		long long cpyLen = processSegment - initSegment - (8 + 1);
		if (cpyLen > 0)
			strncpy(codeTextInit, initSegment, cpyLen);
		if (processSegment - eelCode < strLen)
			strcpy(codeTextProcess, processSegment);
	}
	else
	{
		strcpy(codeTextInit, initSegment);
		long long cpyLen = initSegment - processSegment - (6 + 1);
		if (cpyLen > 0)
			strncpy(codeTextProcess, processSegment, cpyLen);
	}
	errorMsg = LiveProgCompileAndSwap(jdsp, codeTextInit, codeTextProcess);
	free(codeTextInit);
	free(codeTextProcess);
	return errorMsg;
}
const char* checkErrorCode(int errCode)
{
	switch (errCode)
	{
	case 0:
		return "@init section not found";
	case -1:
		return "Syntax error at @init section";
	case -2:
		return "@sample section not found";
	case -3:
		return "Syntax error at @sample section";
	case -4:
		return "Engine busy (no free liveprog slot), retry";
	default:
		return "No syntax errors detected";
	}
}
void LiveProgProcess(JamesDSPLib *jdsp, size_t n)
{
	/* B1：在途守卫双计数——RT 单写者，每块必过（stage_liveprog 恒在链中），
	 * 与 liveprogEnabled 无关：停用期间块边界也要放行影子槽复用。
	 * eelProcCount 供 retiredAt 边界判定；eelInFlight 证明无调用持有快照
	 * （入口 +1 / 出口 -1，lock 前缀全屏障）。 */
	jdsp->eelProcCount++;
	lp_inflight_inc(&jdsp->eelInFlight);
	if (jdsp->liveprogEnabled)
	{
		/* 块首一次读取活动快照；编译期换指针不影响本块后续样本 */
		LiveProg *eel = jdsp->eel;
		if (eel && eel->compileSucessfully && eel->codehandleProcess &&
		    eel->input1 && eel->input2)
		{
			for (size_t i = 0; i < n; i++)
			{
				*eel->input1 = jdsp->tmpBuffer[0][i];
				*eel->input2 = jdsp->tmpBuffer[1][i];
				NSEEL_code_execute(eel->codehandleProcess);
				jdsp->tmpBuffer[0][i] = (float)*eel->input1;
				jdsp->tmpBuffer[1][i] = (float)*eel->input2;
			}
		}
	}
	lp_inflight_dec(&jdsp->eelInFlight);
}
