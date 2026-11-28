#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <time.h>
#include <float.h>
#include <limits.h>
#include "Effects/eel2/dr_flac.h"
#include "Effects/eel2/ns-eel.h"
#include "jdsp_header.h"
#define TAG "EffectDSPMain"

/* [PATCHED-AuraDSP P-022 D7] ASRC 多相 FIR 抽头数——两条初始化路径必须一致。
 *
 * 原来 JamesDSPInit 用 64、JamesDSPSetSampleRate（热切）用 32，两处都是函数内
 * 局部 `const unsigned int asrc_taps`，谁也看不出对方。后果：同一个设备
 * (a) 冷启动直接以 96k 起来、和 (b) 先以 48k 起来再热切到 96k，走的是不同
 * 阶数的抗镜像/抗混叠滤波器——过渡带宽度差一倍、群延迟差一倍，音色会不一样。
 * 抽成一处常量后这个分叉不可能再出现。
 *
 * 取值 64（原 init 路径的值）：init 是默认/质量优先路径，热切的 32 无任何注释
 * 说明动机，按历史遗留处理。64 taps 在 48k 工作域只需 ~64·2 MAC/样本，
 * 32→64 的代价在 ASRC 已启用的场景（本就非常见采样率）不构成理由。
 *
 * 注：Windows 桌面端采用流重启/驱动重建架构（auradsp_create），不暴露
 * 运行时热切接口（S-2 架构取舍）；热切路径 `JamesDSPSetSampleRate` 仅供
 * Android AudioEffect 驱动场景调用。抽头数统一为 64 可确保两端跨平台代码
 * 滤波器阶数一致，消除因冷启动与热重置路径分叉导致的群延迟和频响差异。 */
#define AURADSP_ASRC_TAPS 64u
// Range: 0x800000, 0x7fffff
int32_t i32_from_p24_big_endian(const uint8_t *packed24)
{
	return (packed24[2] << 8) | (packed24[1] << 16) | (packed24[0] << 24);
}
int32_t i32_from_p24_little_endian(const uint8_t *packed24)
{
	return (packed24[0] << 8) | (packed24[1] << 16) | (packed24[2] << 24);
}
void p24_from_i32_big_endian(int32_t ival, uint8_t *packed24)
{
	uint8_t *dst = packed24;
	*dst++ = ival >> 16;
	*dst++ = ival >> 8;
	*dst++ = ival;
}
void p24_from_i32_little_endian(int32_t ival, uint8_t *packed24)
{
	uint8_t *dst = packed24;
	*dst++ = ival;
	*dst++ = ival >> 8;
	*dst++ = ival >> 16;
}
int32_t clamp24_from_float(float f)
{
	static const float scale = (float)(1 << 23);
	float limpos = 0x7fffff / scale;
	float limneg = -0x800000 / scale;
	if (f <= limneg)
		return -0x800000;
	else if (f >= limpos)
		return 0x7fffff;
	f *= scale;
	/* integer conversion is through truncation (though int to float is not).
	 * ensure that we round to nearest, ties away from 0.
	 */
	return f > 0 ? f + 0.5f : f - 0.5f;
}
double crossPlatformCurTime(void)
{
#ifdef WIN32
	DWORD t;

	t = GetTickCount();
	return (double)t * 0.001;
#else
	struct timeval tv;

	gettimeofday(&tv, NULL);
	return tv.tv_sec + tv.tv_usec * 0.000001;
#endif
}
double getProcTime(int flen, int num, double dur)
{
	int pos;
	double t_start, t_diff;
	int counter = 0.0;
	double proc_time;

	int xlen = 2048 * 2048;
	float *x = (float *)malloc(sizeof(float) * xlen);
	float lin = (float)pow(10.0, -100.0 / 20.0);	// 0.00001 = -100dB
	float mul = (float)pow(lin, 1.0 / (double)xlen);
	x[0] = 1.0;
	for (int n = 1; n < xlen; n++)
		x[n] = -mul * x[n - 1];

	int hlen = flen * num;
	float *h = (float *)malloc(sizeof(float) * hlen);
	lin = (float)pow(10.0, -60.0 / 20.0);	// 0.001 = -60dB
	mul = (float)pow(lin, 1.0 / (double)hlen);
	h[0] = 1.0;
	for (int n = 1; n < hlen; n++)
		h[n] = mul * h[n - 1];

	float *y = (float *)malloc(sizeof(float) * flen);

	FFTConvolver1x1 filter;
	FFTConvolver1x1Init(&filter);
	FFTConvolver1x1LoadImpulseResponse(&filter, flen, h, hlen);

	t_diff = 0.0;
	t_start = crossPlatformCurTime();
	pos = 0;
	while (t_diff < dur)
	{
		FFTConvolver1x1Process(&filter, &x[pos], y, flen);
		pos += flen;
		if (pos >= xlen)
			pos = 0;
		counter++;
		t_diff = crossPlatformCurTime() - t_start;
	}
	FFTConvolver1x1Free(&filter);
	free(x);
	free(h);
	free(y);
	return t_diff / (double)counter;
}
char benchmarkCompletionFlag = 0;
double convbench_c0[MAX_BENCHMARK] = { 2.4999999e-05f,4.9999999e-05f,9.9999997e-05f,0.0002f,0.0005f,0.001f,0.0021f,0.0057f,0.0126f,0.0293f };
double convbench_c1[MAX_BENCHMARK] = { 3.1249999e-06f,6.2499998e-06f,1.2500000e-05f,2.4999999e-05f,4.9999999e-05f,9.9999997e-05f,0.0002f,0.0004f,0.0009f,0.0019f };
void JamesDSP_Load_benchmark(double *_c0, double *_c1)
{
	memcpy(convbench_c0, _c0, sizeof(convbench_c0));
	memcpy(convbench_c1, _c1, sizeof(convbench_c1));
	benchmarkCompletionFlag = 1;
}
void JamesDSP_Save_benchmark(double *_c0, double *_c1)
{
	memcpy(_c0, convbench_c0, sizeof(convbench_c0));
	memcpy(_c1, convbench_c1, sizeof(convbench_c1));
}
void JamesDSP_Start_benchmark()
{
	const int sflen_start = 64;
	int s, m;
	int sflen_best = sflen_start;
	int mflen_best = 256;
	int counter = 0;
	double _c0[MAX_BENCHMARK];
	double _c1[MAX_BENCHMARK];
	for (s = 0; s < MAX_BENCHMARK; s++)
	{
		int sflen = sflen_start << s;
		int num = 1;
		double tau_1 = getProcTime(sflen, num, 1.0);
		counter++;
		num = 16;
		double tau_16 = getProcTime(sflen, num, 1.0);
		counter++;
		_c1[s] = (tau_16 - tau_1) / 15.0;
		_c0[s] = tau_1 - convbench_c1[s];
	}
	JamesDSP_Load_benchmark(_c0, _c1);
#ifdef DEBUG
	__android_log_print(ANDROID_LOG_INFO, TAG, "Benchmark done");
#endif
}
void *convBench(void *arg)
{
	size_t sleepMs = 30000; // 30 second after library being loaded
#ifdef _WIN32
	Sleep(sleepMs);
#else
	usleep(sleepMs * 1000ULL);
#endif
#ifdef DEBUG
	__android_log_print(ANDROID_LOG_INFO, TAG, "Benchmark start");
#endif
	JamesDSP_Start_benchmark();
	pthread_exit(NULL);
	return 0;
}
int selectConvPartitions(JamesDSPLib *jdsp, unsigned int impulseLengthActual, unsigned int *seg2Len)
{
	double tau_s, tau_m;
	int mflen_best = 256;
	int num_s, num_m;
	int latency = jdsp->blockSize;
	int type_best, begin_m, end_m;
	int s = (int)log2(latency) - 6;
	if (s < 0)
	{
		printf("Latency must not smaller than 64\n");
		return 1;
	}
	double cpu_load;
	double cpu_load_best = 1e12;
	// performance prediction with 2 segment lengths
	begin_m = 1;
	end_m = MAX_BENCHMARK - s;
	for (int m = begin_m; m < end_m; m++)
	{
		int mflen = latency << m;
		num_s = 2 * mflen / latency;
		num_m = (int)ceil((impulseLengthActual - num_s * latency) / (double)mflen);
		if (num_m < 1)
			num_m = 1;
		tau_s = convbench_c0[s] + convbench_c1[s] * num_s;
		tau_m = convbench_c0[s + m] + convbench_c1[s + m] * num_m;
		cpu_load = 400.0 * (tau_s * mflen / latency + tau_m) * jdsp->fs / (double)mflen;
		if (cpu_load < cpu_load_best)
		{
			cpu_load_best = cpu_load;
			mflen_best = mflen;
			type_best = 2;
		}
	}
	// performance prediction with 1 segment length
	num_s = (int)ceil(impulseLengthActual / (double)latency);
	tau_s = convbench_c0[s] + convbench_c1[s] * num_s;
	cpu_load = 400.0 * tau_s * jdsp->fs / (double)latency;
	if (cpu_load < cpu_load_best)
	{
		cpu_load_best = cpu_load;
		type_best = 1;
	}
	*seg2Len = mflen_best;
	return type_best;
}
void JamesDSPGlobalMemoryAllocation()
{
	benchmarkCompletionFlag = 0;
	NSEEL_start();
#ifdef JAMESDSP_REFERENCE_IMPL
	pthread_t benchmarkThread;
	pthread_create(&benchmarkThread, NULL, convBench, 0);
#endif
}
void JamesDSPGlobalMemoryDeallocation()
{
	NSEEL_quit();
}
unsigned int next_pow_2(unsigned int x)
{
	if (x <= 1) return 1;
	if (x > 0x80000000u) return 0;
	x--;
	x |= x >> 1;
	x |= x >> 2;
	x |= x >> 4;
	x |= x >> 8;
	x |= x >> 16;
	return ++x;
}
/* [PATCHED-AuraDSP P-060] One checked layout is shared by init, reallocation
 * and sample-rate changes. D/I are ASRC work-domain lengths; both stereo work
 * partitions get max(B,D,I), while only the two ring partitions stay pow2(I). */
static int jdsp_size_mul(size_t a, size_t b, size_t *out)
{
	if (b != 0 && a > SIZE_MAX / b)
		return 0;
	*out = a * b;
	return 1;
}

static int jdsp_block_layout(float fs, float trueSampleRate, char enableASRC,
                             size_t blockSizeMax, size_t *scratch,
                             size_t *ringSize)
{
	if (!scratch || !ringSize || blockSizeMax == 0 || blockSizeMax > UINT_MAX ||
		!isfinite(fs) || !isfinite(trueSampleRate) || fs <= 0.0f ||
		trueSampleRate <= 0.0f)
		return 0;
	if (!enableASRC)
	{
		*scratch = blockSizeMax;
		*ringSize = 0;
		return 1;
	}
	{
		const double ratio = (double)fs / (double)trueSampleRate;
		const double decimated = ceil((double)blockSizeMax * ratio);
		const double interpolated = ceil(decimated / ratio);
		size_t d, i;
		unsigned int ring;
		if (!isfinite(ratio) || ratio <= 0.0 || !isfinite(decimated) ||
			!isfinite(interpolated) || decimated < 1.0 ||
			interpolated < 1.0 || decimated > (double)UINT_MAX ||
			interpolated > (double)UINT_MAX)
			return 0;
		d = (size_t)decimated;
		i = (size_t)interpolated;
		*scratch = blockSizeMax;
		if (d > *scratch) *scratch = d;
		if (i > *scratch) *scratch = i;
		ring = next_pow_2((unsigned int)i);
		if (ring == 0)
			return 0;
		*ringSize = ring;
	}
	return 1;
}

static float *jdsp_create_block_storage(float fs, float trueSampleRate,
                                        char enableASRC, size_t blockSizeMax,
                                        float *parts[6], size_t *scratch,
                                        size_t *ringSize)
{
	size_t count;
	size_t bytes;
	float *storage;
	if (!jdsp_block_layout(fs, trueSampleRate, enableASRC, blockSizeMax,
		scratch, ringSize))
		return NULL;
	if (enableASRC)
	{
		size_t work;
		if (!jdsp_size_mul(*scratch, 4, &work) ||
			!jdsp_size_mul(*ringSize, 2, &count))
			return NULL;
		if (work > SIZE_MAX - count)
			return NULL;
		count += work;
	}
	else
	{
		if (!jdsp_size_mul(blockSizeMax, 2, &count))
			return NULL;
	}
	if (!jdsp_size_mul(count, sizeof(float), &bytes))
		return NULL;
	storage = (float *)malloc(bytes);
	if (!storage)
		return NULL;
	parts[0] = storage;
	parts[1] = storage + *scratch;
	if (enableASRC)
	{
		parts[2] = parts[1] + *scratch;
		parts[3] = parts[2] + *scratch;
		parts[4] = parts[3] + *scratch;
		parts[5] = parts[4] + *ringSize;
	}
	else
	{
		parts[2] = parts[3] = parts[4] = parts[5] = NULL;
	}
	return storage;
}

static void jdsp_install_block_storage(JamesDSPLib *jdsp, size_t blockSizeMax,
                                       float *storage, float *parts[6],
                                       size_t scratch, size_t ringSize)
{
	float *oldStorage = jdsp->tmpBuffer[0];
	for (int i = 0; i < 6; ++i)
		jdsp->tmpBuffer[i] = parts[i];
	jdsp->blockSizeMax = blockSizeMax;
	jdsp->asrcScratchSize = scratch;
	jdsp->pw2BlockMemSize = ringSize;
	free(oldStorage);
	(void)storage;
}

static void jdsp_invalidate_block_storage(JamesDSPLib *jdsp)
{
	/* Keep the old base alive for final destruction, but no interior pointer
	 * may be reused after a failed replacement. */
	for (int i = 1; i < 6; ++i)
		jdsp->tmpBuffer[i] = NULL;
	jdsp->blockSizeMax = 0;
	jdsp->asrcScratchSize = 0;
	jdsp->pw2BlockMemSize = 0;
}

int JamesDSPReallocateBlock(JamesDSPLib *jdsp, size_t n)
{
	float *parts[6] = { NULL, NULL, NULL, NULL, NULL, NULL };
	float *storage;
	size_t scratch, ringSize;
	if (!jdsp || n == 0)
		return 0;
	storage = jdsp_create_block_storage(jdsp->fs, jdsp->trueSampleRate,
		jdsp->enableASRC, n, parts, &scratch, &ringSize);
	if (!storage)
	{
		jdsp_invalidate_block_storage(jdsp);
		return 0;
	}
	jdsp_install_block_storage(jdsp, n, storage, parts, scratch, ringSize);
	return 1;
}
void JamesDSPRefreshConvolutions(JamesDSPLib *jdsp, char refreshAll)
{
#ifdef DEBUG
	__android_log_print(ANDROID_LOG_INFO, TAG, "Buffer size changed, update convolution object to maximize performance");
#endif
	if (jdsp->impulseResponseStorage.impulseResponse)
		Convolver1DLoadImpulseResponse(jdsp, jdsp->impulseResponseStorage.impulseResponse, jdsp->impulseResponseStorage.impChannels, jdsp->impulseResponseStorage.impulseLengthActual, 0);
	jdsp->crossfeedForceRefresh = 1;
	CrossfeedEnable(jdsp, jdsp->crossfeedEnabled);
	if (refreshAll)
	{
		jdsp->arbMagForceRefresh = 1;
		ArbitraryResponseEqualizerEnable(jdsp, jdsp->arbitraryMagEnabled);
		jdsp->equalizerForceRefresh = 1;
		MultimodalEqualizerEnable(jdsp, jdsp->equalizerEnabled);
	}
}
void jdsp_lock(JamesDSPLib *jdsp)
{
	if (jdsp->isMutexSuccess)
		pthread_mutex_lock(&jdsp->m_in_processing);
}
void jdsp_unlock(JamesDSPLib *jdsp)
{
	if (jdsp->isMutexSuccess)
		pthread_mutex_unlock(&jdsp->m_in_processing);
}
 /* [PATCHED-AuraDSP P-004] stage 封装：enabled 判断收进 stage，表项恒 on；
  * 输出级（postGain+limiter）从内联代码抽成函数供表驱动复用 */
 /* [PATCHED-AuraDSP P-010] 每效果输出增益门 + 自动增益补偿。
  * 三个 helper 全部 RT 安全（纯乘加，无分配无锁）：
  *   stage_rms          —— tmpBuffer 立体声块 RMS（自动补偿的输入/输出计量）
  *   stage_apply_fx_gain—— 效果处理完后：按 fxOutGain 线性增益乘回；
  *                          fxAutoGain 开时用平滑 RMS 比补偿输出响度回到输入。
  * fx 索引：0=tube 1=comp 2=bass 3=eq。 */
 static double stage_rms(JamesDSPLib *jdsp, size_t n)
 {
 	double acc = 0.0;
 	for (size_t i = 0; i < n; ++i)
 	{
 		double l = (double)jdsp->tmpBuffer[0][i];
 		double r = (double)jdsp->tmpBuffer[1][i];
 		acc += l * l + r * r;
 	}
 	return sqrt(acc / (2.0 * (double)n));
 }
 static void stage_apply_fx_gain(JamesDSPLib *jdsp, size_t n, int fx, double rin)
 {
 	float g = jdsp->fxOutGain[fx];
 	if (jdsp->fxAutoGain[fx])
 	{
 		double rout = stage_rms(jdsp, n);
 		/* 指数平滑：输入/输出各 5% 每块，补偿增益 10%——避免 pumping */
 		jdsp->fxAGIn[fx]  = (float)(jdsp->fxAGIn[fx]  + (rin - jdsp->fxAGIn[fx])  * 0.05);
 		jdsp->fxAGOut[fx] = (float)(jdsp->fxAGOut[fx] + (rout - jdsp->fxAGOut[fx]) * 0.05);
 		double desired = 1.0;
 		if (jdsp->fxAGIn[fx] > 1e-6 && jdsp->fxAGOut[fx] > 1e-6)
 			desired = (double)jdsp->fxAGIn[fx] / jdsp->fxAGOut[fx];
 		if (desired < 0.25) desired = 0.25;   /* ±12dB 补偿上限 */
 		if (desired > 4.0)  desired = 4.0;
 		jdsp->fxAGComp[fx] = (float)(jdsp->fxAGComp[fx] + (desired - jdsp->fxAGComp[fx]) * 0.1);
 		g *= jdsp->fxAGComp[fx];
 	}
 	if (g != 1.0f)
 	{
 		for (size_t i = 0; i < n; ++i)
 		{
 			jdsp->tmpBuffer[0][i] *= g;
 			jdsp->tmpBuffer[1][i] *= g;
 		}
 	}
 }
 static void stage_tube(JamesDSPLib *jdsp, size_t n, const AuraStageGates *gates)
 {
 	/* [PATCHED-AuraDSP P-020 B4] 门控取值：gates 非空且该字段 >=0 时用调用级值，
 	 * 否则沿用全局开关。RT 只读，绝不写回全局字段（lost update 根因）。 */
 	const char on = (gates && gates->tube >= 0) ? (char)gates->tube
 	                                            : (char)(jdsp->tubeEnabled != 0);
 	if (on)
 	{
 		double rin = jdsp->fxAutoGain[0] ? stage_rms(jdsp, n) : 0.0;
 		VacuumTubeProcess(jdsp, n);
 		stage_apply_fx_gain(jdsp, n, 0, rin);
 	}
 }
 static void stage_comp(JamesDSPLib *jdsp, size_t n, const AuraStageGates *gates)
 {
 	/* [PATCHED-AuraDSP P-018 B1-c] 恒调 CompressorProcess：在途守卫双计数
 	 * （compInFlight/compProcCount）须每块必走——停用期间块边界也要放行
 	 * 影子槽复用（compEnabled 门控已移入 CompressorProcess 内部）；
 	 * 输入 RMS 计量与输出增益/自动补偿仅在启用时执行（与原语义一致）。
 	 * [PATCHED-AuraDSP P-020 B4] enabled 作为参数下传（不再靠 RT 改写
 	 * jdsp->compEnabled 来表达「本次调用停用」）。 */
 	const char enabled = (gates && gates->comp >= 0) ? (char)gates->comp
 	                                                 : (char)(jdsp->compEnabled != 0);
 	double rin = (enabled && jdsp->fxAutoGain[1]) ? stage_rms(jdsp, n) : 0.0;
 	CompressorProcess(jdsp, n, enabled != 0);
 	if (enabled)
 		stage_apply_fx_gain(jdsp, n, 1, rin);
 }
 static void stage_bass(JamesDSPLib *jdsp, size_t n, const AuraStageGates *gates)
 {
 	const char on = (gates && gates->bass >= 0) ? (char)gates->bass
 	                                            : (char)(jdsp->bassBoostEnabled != 0);
 	if (on)
 	{
 		double rin = jdsp->fxAutoGain[2] ? stage_rms(jdsp, n) : 0.0;
 		BassBoostProcess(jdsp, n);
 		stage_apply_fx_gain(jdsp, n, 2, rin);
 	}
 }
 static void stage_eq(JamesDSPLib *jdsp, size_t n, const AuraStageGates *gates)
 {
 	const char on = (gates && gates->eq >= 0) ? (char)gates->eq
 	                                          : (char)(jdsp->equalizerEnabled != 0);
 	if (on)
 	{
 		double rin = jdsp->fxAutoGain[3] ? stage_rms(jdsp, n) : 0.0;
 		MultimodalEqualizerProcess(jdsp, n);
 		stage_apply_fx_gain(jdsp, n, 3, rin);
 	}
 }
static void stage_arbmag(JamesDSPLib *jdsp, size_t n, const AuraStageGates *gates)
{
	const char on = (gates && gates->arbmag >= 0) ? (char)gates->arbmag
	                                              : (char)(jdsp->arbitraryMagEnabled != 0);
	if (on)
	{
		double rin = jdsp->fxAutoGain[4] ? stage_rms(jdsp, n) : 0.0;
		ArbitraryResponseEqualizerProcess(jdsp, n);
		stage_apply_fx_gain(jdsp, n, 4, rin);
	}
}
static void stage_conv(JamesDSPLib *jdsp, size_t n, const AuraStageGates *gates)
{
	(void)gates;
	if (!jdsp->convolverEnabled)
		return;
	if (!jdsp->conv.process)
		return;
	/* [PATCHED-AuraDSP P-005] 干湿混合：先留干信号，卷积后按系数混合 */
	if (jdsp->auraConvMixUsed && jdsp->auraConvScratch)
	{
		memcpy(jdsp->auraConvScratch, jdsp->tmpBuffer[0], n * sizeof(float));
		memcpy(jdsp->auraConvScratch + n, jdsp->tmpBuffer[1], n * sizeof(float));
		jdsp->conv.process(jdsp, n);
		for (size_t i = 0; i < n; ++i)
		{
			float dryL = jdsp->auraConvScratch[i];
			float dryR = jdsp->auraConvScratch[n + i];
			float wetL = jdsp->tmpBuffer[0][i];
			float wetR = jdsp->tmpBuffer[1][i];
			jdsp->tmpBuffer[0][i] = dryL * jdsp->auraConvDry + wetL * jdsp->auraConvWet;
			jdsp->tmpBuffer[1][i] = dryR * jdsp->auraConvDry + wetR * jdsp->auraConvWet;
		}
		return;
	}
	jdsp->conv.process(jdsp, n);
}
static void stage_ddc(JamesDSPLib *jdsp, size_t n, const AuraStageGates *gates)
{
	/* [PATCHED-AuraDSP P-017 B1-b] enabled 判断内移 DDCProcess：每块必过本
	 * stage 推进在途守卫计数（停用期间块边界也要放行影子视图复用）。 */
	(void)gates;
	DDCProcess(jdsp, n);
}
static void stage_liveprog(JamesDSPLib *jdsp, size_t n, const AuraStageGates *gates)
{
	/* [PATCHED-AuraDSP P-016 B1] enabled 判断内移 LiveProgProcess：每块必过本
	 * stage 推进在途守卫计数（停用期间块边界也要放行影子槽复用）。 */
	(void)gates;
	LiveProgProcess(jdsp, n);
}
static void stage_crossfeed(JamesDSPLib *jdsp, size_t n, const AuraStageGates *gates)
{
	(void)gates;
	if (jdsp->crossfeedEnabled)
		CrossfeedProcess(jdsp, n);
}
static void stage_stereo(JamesDSPLib *jdsp, size_t n, const AuraStageGates *gates)
{
	(void)gates;
	if (jdsp->sterEnhEnabled)
		StereoEnhancementProcess(jdsp, n);
}
static void stage_reverb(JamesDSPLib *jdsp, size_t n, const AuraStageGates *gates)
{
	(void)gates;
	/* [PATCHED-AuraDSP P-033] ReverbProcess 每块必进推进在途守卫计数；
	 * enabled 与 gain 处理在内部与此处协同 */
	if (jdsp->reverbEnabled)
	{
		double rin = jdsp->fxAutoGain[5] ? stage_rms(jdsp, n) : 0.0;
		ReverbProcess(jdsp, n);
		stage_apply_fx_gain(jdsp, n, 5, rin);
	}
	else
	{
		ReverbProcess(jdsp, n);
	}
}
static void stage_output(JamesDSPLib *jdsp, size_t n, const AuraStageGates *gates)
{
	/* [PATCHED-AuraDSP P-020 B4] limiter 门控可被调用级覆盖（多声道链 Category B
	 * 需要「跑 postGain 但不跑 vendor limiter」，因为 MC 侧另有
	 * limiter_process_mc 承担 lookahead/link/mask）。 */
	const char limOn = (gates && gates->limiter >= 0) ? (char)gates->limiter
	                                                  : (char)(jdsp->limiterEnabled != 0);
	for (size_t i = 0; i < n; i++)
	{
		float xL = jdsp->tmpBuffer[0][i] * jdsp->postGain * jdsp->postGainCh[0];
		float xR = jdsp->tmpBuffer[1][i] * jdsp->postGain * jdsp->postGainCh[1];
		/* [PATCHED-AuraDSP P-012] limiter.enable=0 时跳过包络增益（只做 postGain） */
		float gR = 1.0f;
		float rect1 = fabsf(xL);
		float rect2 = fabsf(xR);
		if (limOn)
		{
			float maxLR = max(rect1, rect2);
			if (maxLR < jdsp->limiter.threshold)
				maxLR = jdsp->limiter.threshold;
			if (maxLR > jdsp->limiter.envOverThreshold)
				jdsp->limiter.envOverThreshold = maxLR;
			else
				jdsp->limiter.envOverThreshold = maxLR + jdsp->limiter.relCoef * (jdsp->limiter.envOverThreshold - maxLR);
			gR = jdsp->limiter.threshold / jdsp->limiter.envOverThreshold;
		}
		rect1 = xL * gR;
		rect2 = xR * gR;
		jdsp->tmpBuffer[0][i] = rect1;
		jdsp->tmpBuffer[1][i] = rect2;
	}
}

static const struct
{
	const char *id;
	JDSPStageFn fn;
	char lock;
} kAuraStages[] = {
	{"tube", stage_tube, 0},
	/* [PATCHED-AuraDSP P-018 B1-c] comp lock 1→0：控制侧已改影子构建 + 原子换
	 * 指针（dynamic.c CompressorCommit + CompSlot 双缓冲），RT 块首读一次
	 * compActive 即得一致快照，无需再与任何控制路径互斥；保留锁只会在
	 * FFTCompanderInit 全量重算期间无谓阻塞 RT（Z13 只修了数据竞争，
	 * 没修等待时长——参数频调时 RT 反复卡在 EnterCriticalSection）。
	 * stage_comp 的 enabled 门控随之移入 CompressorProcess：在途计数
	 * （compInFlight/compProcCount）须每块必走，停用期间块边界也要放行
	 * 影子槽复用。 */
	{"comp", stage_comp, 0},
	{"bass", stage_bass, 0},
	{"eq", stage_eq, 0},
	/* [PATCHED-AuraDSP P-048] arbmag lock 0→1：L-03 主卷积原位刷新竞态。
	 * vendor 的 ArbitraryResponseEqualizerStringParser 会对 arbMag.conv 做
	 * 原位 RefreshImpulseResponse，Enable(forceRefresh) 更会 Free + Load
	 * （释放后使用 ⇒ UAF），而 RT 的 stage_arbmag 正在同一对象上跑
	 * FFTConvolver2x2Process。修法是控制侧刷新时同持 jdsp_lock、RT 侧
	 * stage_arbmag 也取 jdsp_lock（仓库既有约定：控制侧结构变更路径必须
	 * 同持 jdsp_lock）。刷新耗时亚毫秒级，不产生可闻卡顿。
	 * 注：离散多声道路径不走 vendor 链的 arbmag（改用逐声道池），故该锁
	 * 只影响立体声 / 矩阵 / 双耳路径。 */
	{"arbmag", stage_arbmag, 1},
	{"convolver", stage_conv, 1},
	/* [PATCHED-AuraDSP P-017 B1-b] ddc lock 1→0：控制侧已改影子视图 + 原子换
	 * 指针（vdc.c），RT 块首读一次 ddcActive 即得 {sosPointer, count}
	 * 一致对，无需再与任何控制路径互斥。 */
	{"ddc", stage_ddc, 0},
	/* [PATCHED-AuraDSP P-016 B1] liveprog lock 1→0：控制侧已改影子 VM 编译 +
	 * 原子换指针（liveprogWrapper.c），RT 块首只读一次 eel 快照指针，
	 * 无需再与任何控制路径互斥；保留锁只会在 EEL 编译/DDC 解析/
	 * JamesDSPSetSampleRate 持锁时无谓阻塞 RT。 */
	{"liveprog", stage_liveprog, 0},
	{"crossfeed", stage_crossfeed, 0},
	{"stereo", stage_stereo, 0},
	{"reverb", stage_reverb, 0},
	{"output", stage_output, 0},
};
#define kAuraStageCount (sizeof(kAuraStages) / sizeof(kAuraStages[0]))

/* 重建处理链：ids=NULL 用默认序；否则逗号分隔 id 列表（必须恰好包含
 * 全部 stage 各一次，集合校验失败返回 -1 且保持原表）。 */
int JamesDSPRebuildChain(JamesDSPLib *jdsp, const char *ids)
{
	int used[kAuraStageCount];
	for (unsigned int i = 0; i < kAuraStageCount; ++i)
		used[i] = 0;
	int len = 0;
	JDSPChainItem tmp[64];
	if (!ids)
	{
		for (unsigned int i = 0; i < kAuraStageCount; ++i)
		{
			tmp[i].fn = kAuraStages[i].fn;
			tmp[i].lock = kAuraStages[i].lock;
			tmp[i].stageIdx = (unsigned char)i;
		}
		len = (int)kAuraStageCount;
	}
	else
	{
		char *txt = (char *)malloc(strlen(ids) + 1);
		if (!txt)
			return -1;
		strcpy(txt, ids);
		char *cur = txt;
		/* [PATCHED-AuraDSP P-004] 烟囱抓回：循环上限不能是 stage 数
		 * （多出的尾部项会静默逃过集合校验），容量放大、解析后校验
		 * 项数与集合双重把关 */
		while (cur && len < 64)
		{
			char *comma = strchr(cur, ',');
			if (comma)
				*comma = 0;
			int found = -1;
			for (unsigned int i = 0; i < kAuraStageCount; ++i)
				if (!strcmp(cur, kAuraStages[i].id))
				{
					found = (int)i;
					break;
				}
			if (found < 0 || used[found])
			{
				free(txt);
				return -1;
			}
			used[found] = 1;
			tmp[len].fn = kAuraStages[found].fn;
			tmp[len].lock = kAuraStages[found].lock;
			tmp[len].stageIdx = (unsigned char)found;
			++len;
			cur = comma ? comma + 1 : ((void *)0);
		}
		free(txt);
		if (len != (int)kAuraStageCount)
			return -1;
		for (unsigned int i = 0; i < kAuraStageCount; ++i)
			if (!used[i])
				return -1;
	}
	for (int i = 0; i < len; ++i)
		jdsp->chain[i] = tmp[i];
	jdsp->chainLen = len;
	return 0;
}

/* [PATCHED-AuraDSP P-013] 上层 id 列表 → vendor stage id 列表。
 *
 * 背景：App 的「处理顺序」页下发的是**全量**效果器 id（19 个，含 gate/filter/
 * dyneq/bassmono/haas/exciter/loudness 等自研 stage，它们在引擎自己的
 * process_stereo_chain 里，不归 vendor 链管）。原实现把这份原样喂给
 * JamesDSPRebuildChain，而后者只认 kAuraStages 的 12 个 id 且要求「恰好各
 * 一次」——于是任何来自 App 的 graph.order 都必然 found<0 返回 -1，
 * 用户拖拽的顺序被**静默丢弃**，引擎永远跑默认序（UI 显示与实际处理不一致）。
 *
 * 本函数在两者之间补上丢失的那层：保序抽取已知 id、去重、丢未知，
 * 并保证 output 收尾。过滤后若集合仍不完整（缺 vendor stage），由
 * JamesDSPRebuildChain 按原语义拒绝——那种情况确实是调用方数据有问题。 */
int JamesDSPFilterVendorOrder(const char *in, char *out, int out_size)
{
	if (!in || !out || out_size < 64)
		return 0;
	int used[kAuraStageCount];
	for (unsigned int i = 0; i < kAuraStageCount; ++i)
		used[i] = 0;
	int written = 0;
	const char *cur = in;
	while (cur && *cur)
	{
		const char *comma = strchr((const char*)cur, ',');
		int len = comma ? (int)(comma - cur) : (int)strlen(cur);
		/* 去掉首尾空白，容忍 "a, b" 写法 */
		while (len > 0 && (*cur == ' ' || *cur == '\t'))
		{
			cur++;
			len--;
		}
		while (len > 0 && (cur[len - 1] == ' ' || cur[len - 1] == '\t' ||
		                   cur[len - 1] == '\r' || cur[len - 1] == '\n'))
			len--;
		for (unsigned int i = 0; i < kAuraStageCount; ++i)
		{
			if ((int)strlen(kAuraStages[i].id) != len ||
			    strncmp(cur, kAuraStages[i].id, (size_t)len))
				continue;
			/* output 的位置由本函数钉死在末尾，输入里出现也一律跳过，
			 * 否则它会被静默吞掉、过滤结果只剩 11 个 id 而被整体拒绝。 */
			if (!used[i] && strcmp(kAuraStages[i].id, "output") != 0)
			{
				used[i] = 1;
				if (written && written + 1 < out_size)
					out[written++] = ',';
				if (written + len < out_size)
				{
					memcpy(out + written, cur, (size_t)len);
					written += len;
				}
			}
			break;
		}
		cur = comma ? comma + 1 : ((void *)0);
	}
	/* output 恒在末尾（与 App 侧 _apply 的约定一致） */
	if (written && written + 1 < out_size)
		out[written++] = ',';
	if (written + 6 < out_size)
	{
		memcpy(out + written, "output", 6);
		written += 6;
	}
	out[written] = 0;
	return written;
}

// Process（P-004 表驱动 + M3.5-c 节点电平采样）
void JamesDSPProcess(JamesDSPLib *jdsp, size_t n)
{
	for (int i = 0; i < jdsp->chainLen; ++i)
	{
		if (jdsp->chain[i].lock)
			jdsp_lock(jdsp);
		jdsp->chain[i].fn(jdsp, n, (const AuraStageGates *)0); /* B4：全链一律用全局开关 */
		if (jdsp->chain[i].lock)
			jdsp_unlock(jdsp);
		/* [PATCHED-AuraDSP P-023 M3.5-c] 采样 stage 输出峰值 */
		float maxL = 0.0f, maxR = 0.0f;
		for (size_t s = 0; s < n; ++s)
		{
			float aL = fabsf(jdsp->tmpBuffer[0][s]);
			float aR = fabsf(jdsp->tmpBuffer[1][s]);
			if (aL > maxL) maxL = aL;
			if (aR > maxR) maxR = aR;
		}
		unsigned char sidx = jdsp->chain[i].stageIdx;
		if (sidx < 16)
		{
			jdsp->stagePeakL[sidx] = maxL;
			jdsp->stagePeakR[sidx] = maxR;
		}
	}
}
void JamesDSPProcessCheckBenchmarkReady(JamesDSPLib *jdsp, size_t n)
{
	/* [PATCHED-AuraDSP P-004] 链体表驱动（与 JamesDSPProcess 同表） */
	for (int i = 0; i < jdsp->chainLen; ++i)
	{
		if (jdsp->chain[i].lock)
			jdsp_lock(jdsp);
		jdsp->chain[i].fn(jdsp, n, (const AuraStageGates *)0); /* B4：全链一律用全局开关 */
		if (jdsp->chain[i].lock)
			jdsp_unlock(jdsp);
		/* [PATCHED-AuraDSP P-023 M3.5-c] 采样 stage 输出峰值 */
		float maxL = 0.0f, maxR = 0.0f;
		for (size_t s = 0; s < n; ++s)
		{
			float aL = fabsf(jdsp->tmpBuffer[0][s]);
			float aR = fabsf(jdsp->tmpBuffer[1][s]);
			if (aL > maxL) maxL = aL;
			if (aR > maxR) maxR = aR;
		}
		unsigned char sidx = jdsp->chain[i].stageIdx;
		if (sidx < 16)
		{
			jdsp->stagePeakL[sidx] = maxL;
			jdsp->stagePeakR[sidx] = maxR;
		}
	}
	if (benchmarkCompletionFlag == 1)
	{
#ifdef DEBUG
		__android_log_print(ANDROID_LOG_INFO, TAG, "Benchmark flag == 1, refreshing convolutions");
#endif
		JamesDSPRefreshConvolutions(jdsp, 0);
		jdsp->processInternal = JamesDSPProcess;
	}
}
size_t iabs(size_t value)
{
	return value < 0 ? 0 - value : value;
}
void sample_ratio(unsigned long long numerator, unsigned long long denominator, unsigned long long *num, unsigned long long *denom)
{
	/* [PATCHED-AuraDSP P-060] Euclid avoids a linear scan to the larger rate. */
	unsigned long long a = numerator;
	unsigned long long b = denominator;
	if (!num || !denom || a == 0 || b == 0)
	{
		if (num) *num = 0;
		if (denom) *denom = 0;
		return;
	}
	while (b != 0)
	{
		const unsigned long long remainder = a % b;
		a = b;
		b = remainder;
	}
	*num = numerator / a;
	*denom = denominator / a;
}
void RingBuffer_Init(RingBuffer *fifo)
{
	fifo->in = fifo->out = 0;
}
uint32_t RingBuffering(RingBuffer *fifo, const float *buffer, const float *in, uint32_t lenIn, float *out, uint32_t lenOut, uint32_t size)
{
	lenIn = min(lenIn, size - (fifo->in - fifo->out));
	// First put the data starting from fifo->in to buffer end
	uint32_t l_In = min(lenIn, size - (fifo->in & (size - 1)));
	memcpy(buffer + (fifo->in & (size - 1)), in, l_In * sizeof(float));
	// Then put the rest (if any) at the beginning of the buffer
	memcpy(buffer, in + l_In, (lenIn - l_In) * sizeof(float));
	fifo->in += lenIn;
	lenOut = min(lenOut, fifo->in - fifo->out);
	unsigned int lenOut_2 = min(lenOut, fifo->in - fifo->out);
	// First get the data from fifo->out until the end of the buffer
	uint32_t l_Out = min(lenOut, size - (fifo->out & (size - 1)));
	memcpy(out, buffer + (fifo->out & (size - 1)), l_Out * sizeof(float));
	// Then get the rest (if any) from the beginning of the buffer
	memcpy(out + l_Out, buffer, (lenOut - l_Out) * sizeof(float));
	fifo->out += lenOut;
	if (fifo->in > size || fifo->out > size)
	{
		fifo->in = fifo->in - size;
		fifo->out = fifo->out - size;
	}
	return lenOut;
}
uint32_t RingBufferingStereo(RingBuffer *fifo[2], const float *buffer1, const float *buffer2, const float *in1, const float *in2, uint32_t lenIn, float *out1, float *out2, uint32_t lenOut, uint32_t size)
{
	lenIn = min(lenIn, size - (fifo[0]->in - fifo[0]->out));
	// First put the data starting from fifo[0]->in to buffer end
	uint32_t l_In = min(lenIn, size - (fifo[0]->in & (size - 1)));
	memcpy(buffer1 + (fifo[0]->in & (size - 1)), in1, l_In * sizeof(float));
	memcpy(buffer2 + (fifo[0]->in & (size - 1)), in2, l_In * sizeof(float));
	// Then put the rest (if any) at the beginning of the buffer
	memcpy(buffer1, in1 + l_In, (lenIn - l_In) * sizeof(float));
	memcpy(buffer2, in2 + l_In, (lenIn - l_In) * sizeof(float));
	fifo[0]->in += lenIn;
	lenOut = min(lenOut, fifo[0]->in - fifo[0]->out);
	unsigned int lenOut_2 = min(lenOut, fifo[0]->in - fifo[0]->out);
	// First get the data from fifo[0]->out until the end of the buffer
	uint32_t l_Out = min(lenOut, size - (fifo[0]->out & (size - 1)));
	memcpy(out1, buffer1 + (fifo[0]->out & (size - 1)), l_Out * sizeof(float));
	memcpy(out2, buffer2 + (fifo[0]->out & (size - 1)), l_Out * sizeof(float));
	// Then get the rest (if any) from the beginning of the buffer
	memcpy(out1 + l_Out, buffer1, (lenOut - l_Out) * sizeof(float));
	memcpy(out2 + l_Out, buffer2, (lenOut - l_Out) * sizeof(float));
	fifo[0]->out += lenOut;
	if (fifo[0]->in > size || fifo[0]->out > size)
	{
		fifo[0]->in = fifo[0]->in - size;
		fifo[0]->out = fifo[0]->out - size;
	}
	return lenOut;
}
static int jdsp_asrc_filters_valid(const JamesDSPLib *jdsp)
{
	return psrc_is_valid(&jdsp->asrc[0].polyphaseDecimator) &&
		psrc_is_valid(&jdsp->asrc[1].polyphaseDecimator) &&
		psrc_is_valid(&jdsp->asrc[0].polyphaseInterpolator) &&
		psrc_is_valid(&jdsp->asrc[1].polyphaseInterpolator);
}

static int JamesDSPBlockBuffersReady(const JamesDSPLib *jdsp, size_t n)
{
	if (!jdsp || n == 0 || n > jdsp->blockSizeMax ||
		!jdsp->tmpBuffer[0] || !jdsp->tmpBuffer[1])
		return 0;
	if (!jdsp->enableASRC)
		return 1;
	return n <= UINT_MAX && n <= jdsp->asrcScratchSize &&
		jdsp->tmpBuffer[2] && jdsp->tmpBuffer[3] &&
		jdsp->tmpBuffer[4] && jdsp->tmpBuffer[5] &&
		jdsp->pw2BlockMemSize >= 1 &&
		(jdsp->pw2BlockMemSize & (jdsp->pw2BlockMemSize - 1)) == 0 &&
		jdsp_asrc_filters_valid(jdsp);
}

static int jdsp_prepare_process_block(JamesDSPLib *jdsp, size_t n)
{
	if (!jdsp)
		return 0;
	/* [PATCHED-AuraDSP P-060] RT entrypoints never grow storage. Capacity is
	 * prepared by init/control code; an oversized block fails to digital zero. */
	if (n == 0 || jdsp->blockSizeMax < n)
		return 0;
	return JamesDSPBlockBuffersReady(jdsp, n);
}

static void jdsp_zero_work(JamesDSPLib *jdsp, size_t n)
{
	if (jdsp && jdsp->tmpBuffer[0] && jdsp->tmpBuffer[1] &&
		n <= jdsp->asrcScratchSize)
	{
		memset(jdsp->tmpBuffer[0], 0, n * sizeof(float));
		memset(jdsp->tmpBuffer[1], 0, n * sizeof(float));
	}
}

int InitIntegerASRCHandler(IntegerASRCHandler *asrc, unsigned long long workingFs,
                           unsigned long long inFs, unsigned int polyphaseFIRTaps,
                           char minphase, SRCResampler *inst1,
                           SRCResampler *inst2)
{
	IntegerASRCHandler next;
	unsigned long long num, denom;
	double ratio;
	double minimumInputBufLen;
	memset(&next, 0, sizeof(next));
	if (!asrc || workingFs == 0 || inFs == 0 || polyphaseFIRTaps == 0 ||
		polyphaseFIRTaps > INT_MAX)
		return 0;
	ratio = (double)workingFs / (double)inFs;
	minimumInputBufLen = ceil((double)inFs / (double)workingFs);
	if (!isfinite(ratio) || ratio <= 0.0 || !isfinite(minimumInputBufLen) ||
		minimumInputBufLen < 1.0 || minimumInputBufLen > (double)UINT_MAX)
		return 0;
	sample_ratio(workingFs, inFs, &num, &denom);
	if (num == 0 || denom == 0 || num > UINT_MAX || denom > UINT_MAX)
		return 0;
	/* [PATCHED-AuraDSP P-060] Min-phase FHT workspace grows with the reduced
	 * numerator. 256 keeps 147/160 (44.1/48, 88.2/96, 176.4/192) on the
	 * existing path, while 1000/1001 and coprime near-neighbors use linear
	 * phase instead of a ~192 MiB temporary FHT. */
	if ((workingFs == num && inFs == denom) ||
		num > AURADSP_ASRC_MINPHASE_MAX_PHASES ||
		denom > AURADSP_ASRC_MINPHASE_MAX_PHASES)
		minphase = 0;
	next.calculatedLatencyWholeSystem = (unsigned int)minimumInputBufLen;
	if (!inst1)
	{
		if (!psrc_generate(&next.polyphaseDecimator, (unsigned int)num,
			(unsigned int)denom, polyphaseFIRTaps, 0.99, minphase))
			goto fail;
	}
	else if (!psrc_clone(&next.polyphaseDecimator, inst1))
		goto fail;
	if (!inst2)
	{
		if (!psrc_generate(&next.polyphaseInterpolator, (unsigned int)denom,
			(unsigned int)num, polyphaseFIRTaps, 0.99, minphase))
			goto fail;
	}
	else if (!psrc_clone(&next.polyphaseInterpolator, inst2))
		goto fail;
	RingBuffer_Init(&next.intermediateRing);
	*asrc = next;
	return 1;

fail:
	psrc_free(&next.polyphaseDecimator);
	psrc_free(&next.polyphaseInterpolator);
	return 0;
}

void FreeIntegerASRCHandler(IntegerASRCHandler *asrc)
{
	if (!asrc)
		return;
	psrc_free(&asrc->polyphaseDecimator);
	psrc_free(&asrc->polyphaseInterpolator);
	memset(asrc, 0, sizeof(*asrc));
}

unsigned int DoASRC_fwd(JamesDSPLib *jdsp, size_t n)
{
	SRCResampler *ptr[2];
	unsigned int curDecimatedLen;
	if (!JamesDSPBlockBuffersReady(jdsp, n) || n > UINT_MAX)
		return 0;
	ptr[0] = &jdsp->asrc[0].polyphaseDecimator;
	ptr[1] = &jdsp->asrc[1].polyphaseDecimator;
	curDecimatedLen = psrc_filt_stereo(ptr, jdsp->tmpBuffer[0],
		jdsp->tmpBuffer[1], (unsigned int)n, jdsp->tmpBuffer[2],
		jdsp->tmpBuffer[3]);
	if (curDecimatedLen > jdsp->asrcScratchSize)
	{
		jdsp_zero_work(jdsp, n);
		return 0;
	}
	for (unsigned int i = 0; i < curDecimatedLen; i++)
	{
		jdsp->tmpBuffer[0][i] = jdsp->tmpBuffer[2][i];
		jdsp->tmpBuffer[1][i] = jdsp->tmpBuffer[3][i];
	}
	return curDecimatedLen;
}

void DoASRC_bwd(JamesDSPLib *jdsp, unsigned int curDecimatedLen, size_t n)
{
	SRCResampler *ptr[2];
	RingBuffer *ptr2[2];
	unsigned int curInterpolatedLen;
	if (!JamesDSPBlockBuffersReady(jdsp, n) ||
		curDecimatedLen > jdsp->asrcScratchSize)
	{
		jdsp_zero_work(jdsp, n);
		return;
	}
	ptr[0] = &jdsp->asrc[0].polyphaseInterpolator;
	ptr[1] = &jdsp->asrc[1].polyphaseInterpolator;
	curInterpolatedLen = psrc_filt_stereo(ptr, jdsp->tmpBuffer[0],
		jdsp->tmpBuffer[1], curDecimatedLen, jdsp->tmpBuffer[2],
		jdsp->tmpBuffer[3]);
	if (curInterpolatedLen > jdsp->asrcScratchSize)
	{
		jdsp_zero_work(jdsp, n);
		return;
	}
	ptr2[0] = &jdsp->asrc[0].intermediateRing;
	ptr2[1] = &jdsp->asrc[1].intermediateRing;
	RingBufferingStereo(ptr2, jdsp->tmpBuffer[4], jdsp->tmpBuffer[5],
		jdsp->tmpBuffer[2], jdsp->tmpBuffer[3], curInterpolatedLen,
		jdsp->tmpBuffer[0], jdsp->tmpBuffer[1], (unsigned int)n,
		jdsp->pw2BlockMemSize);
}
/* [PATCHED-AuraDSP P-060] Failed/absent work storage produces digital zero,
 * never a read or write through stale interior partitions. */
static void jdsp_zero_s16(int16_t *y1, int16_t *y2, size_t n)
{
	for (size_t i = 0; i < n; ++i)
	{
		if (y1) y1[i] = 0;
		if (y2) y2[i] = 0;
	}
}
static void jdsp_zero_s16_interleaved(int16_t *y, size_t n)
{
	for (size_t i = 0; i < n; ++i)
		if (y) { y[i << 1] = 0; y[(i << 1) + 1] = 0; }
}
static void jdsp_zero_s32(int32_t *y1, int32_t *y2, size_t n)
{
	for (size_t i = 0; i < n; ++i)
	{
		if (y1) y1[i] = 0;
		if (y2) y2[i] = 0;
	}
}
static void jdsp_zero_s32_interleaved(int32_t *y, size_t n)
{
	for (size_t i = 0; i < n; ++i)
		if (y) { y[i << 1] = 0; y[(i << 1) + 1] = 0; }
}
static void jdsp_zero_float(float *y1, float *y2, size_t n)
{
	for (size_t i = 0; i < n; ++i)
	{
		if (y1) y1[i] = 0.0f;
		if (y2) y2[i] = 0.0f;
	}
}
static void jdsp_zero_float_interleaved(float *y, size_t n)
{
	for (size_t i = 0; i < n; ++i)
		if (y) { y[i << 1] = 0.0f; y[(i << 1) + 1] = 0.0f; }
}
static void jdsp_zero_p24(uint8_t *y1, uint8_t *y2, size_t n)
{
	for (size_t i = 0; i < n; ++i)
	{
		if (y1) { y1[i * 3] = 0; y1[i * 3 + 1] = 0; y1[i * 3 + 2] = 0; }
		if (y2) { y2[i * 3] = 0; y2[i * 3 + 1] = 0; y2[i * 3 + 2] = 0; }
	}
}
static void jdsp_zero_p24_interleaved(uint8_t *y, size_t n)
{
	for (size_t i = 0; i < n; ++i)
		if (y)
		{
			y[(i << 1) * 3] = 0;
			y[(i << 1) * 3 + 1] = 0;
			y[(i << 1) * 3 + 2] = 0;
			y[((i << 1) + 1) * 3] = 0;
			y[((i << 1) + 1) * 3 + 1] = 0;
			y[((i << 1) + 1) * 3 + 2] = 0;
		}
}

void pint16(JamesDSPLib *jdsp, int16_t *x1, int16_t *x2, int16_t *y1, int16_t *y2, size_t n)
{
	if (!jdsp_prepare_process_block(jdsp, n))
	{
		jdsp_zero_s16(y1, y2, n);
		return;
	}
	if (jdsp->blockSize != n)
	{
		jdsp->blockSize = n;
	}
	static const float scale = (float)(1UL << 15UL);
	static const float offset = (float)(3 << (22 - 15));
	/* zero = (0x10f << 22) =  0x43c00000 (not directly used) */
	static const int32_t limneg = (0x10f << 22) /*zero*/ - 32768; /* 0x43bf8000 */
	static const int32_t limpos = (0x10f << 22) /*zero*/ + 32767; /* 0x43c07fff */
	union {
		float f;
		int32_t i;
	} u;
	for (size_t i = 0; i < n; i++)
	{
		jdsp->tmpBuffer[0][i] = x1[i] / scale;
		jdsp->tmpBuffer[1][i] = x2[i] / scale;
	}
	if (jdsp->enableASRC)
	{
		unsigned int curDecimatedLen = DoASRC_fwd(jdsp, n);
		jdsp->processInternal(jdsp, curDecimatedLen);
		DoASRC_bwd(jdsp, curDecimatedLen, n);
	}
	else
		jdsp->processInternal(jdsp, n);
	for (size_t i = 0; i < n; i++)
	{
		u.f = jdsp->tmpBuffer[0][i] + offset;
		if (u.i < limneg)
			u.i = -32768;
		else if (u.i > limpos)
			u.i = 32767;
		y1[i] = u.i;
		u.f = jdsp->tmpBuffer[1][i] + offset;
		if (u.i < limneg)
			u.i = -32768;
		else if (u.i > limpos)
			u.i = 32767;
		y2[i] = u.i;
	}
}
void pint16Multiplexed(JamesDSPLib *jdsp, int16_t *x, int16_t *y, size_t n)
{
	if (!jdsp_prepare_process_block(jdsp, n))
	{
		jdsp_zero_s16_interleaved(y, n);
		return;
	}
	if (jdsp->blockSize != n)
	{
		jdsp->blockSize = n;
	}
	static const float offset = (float)(3 << (22 - 15));
	/* zero = (0x10f << 22) =  0x43c00000 (not directly used) */
	static const int32_t limneg = (0x10f << 22) /*zero*/ - 32768; /* 0x43bf8000 */
	static const int32_t limpos = (0x10f << 22) /*zero*/ + 32767; /* 0x43c07fff */
	union {
		float f;
		int32_t i;
	} u;
	for (size_t i = 0; i < n; i++)
	{
		jdsp->tmpBuffer[0][i] = x[i << 1] * 0.000030517578125f;
		jdsp->tmpBuffer[1][i] = x[(i << 1) + 1] * 0.000030517578125f;
	}
	if (jdsp->enableASRC)
	{
		unsigned int curDecimatedLen = DoASRC_fwd(jdsp, n);
		jdsp->processInternal(jdsp, curDecimatedLen);
		DoASRC_bwd(jdsp, curDecimatedLen, n);
	}
	else
		jdsp->processInternal(jdsp, n);
	for (size_t i = 0; i < n; i++)
	{
		u.f = jdsp->tmpBuffer[0][i] + offset;
		if (u.i < limneg)
			u.i = -32768;
		else if (u.i > limpos)
			u.i = 32767;
		y[i << 1] = (int16_t)u.i;
		u.f = jdsp->tmpBuffer[1][i] + offset;
		if (u.i < limneg)
			u.i = -32768;
		else if (u.i > limpos)
			u.i = 32767;
		y[(i << 1) + 1] = (int16_t)u.i;
	}
}
void pint32(JamesDSPLib *jdsp, int32_t *x1, int32_t *x2, int32_t *y1, int32_t *y2, size_t n)
{
	if (!jdsp_prepare_process_block(jdsp, n))
	{
		jdsp_zero_s32(y1, y2, n);
		return;
	}
	if (jdsp->blockSize != n)
	{
		jdsp->blockSize = n;
	}
	static const float scale = (float)(1UL << 31UL);
	for (size_t i = 0; i < n; i++)
	{
		jdsp->tmpBuffer[0][i] = (float)((double)x1[i] / scale);
		jdsp->tmpBuffer[1][i] = (float)((double)x2[i] / scale);
	}
	if (jdsp->enableASRC)
	{
		unsigned int curDecimatedLen = DoASRC_fwd(jdsp, n);
		jdsp->processInternal(jdsp, curDecimatedLen);
		DoASRC_bwd(jdsp, curDecimatedLen, n);
	}
	else
		jdsp->processInternal(jdsp, n);
	float f;
	for (size_t i = 0; i < n; i++)
	{
		if (jdsp->tmpBuffer[0][i] <= -1.0f)
			y1[i] = INT32_MIN;
		else if (jdsp->tmpBuffer[0][i] >= 1.0f)
			y1[i] = INT32_MAX;
		else
		{
			f = jdsp->tmpBuffer[0][i] * scale;
			y1[i] = (int32_t)(f > 0 ? f + 0.5f : f - 0.5f);
		}
		if (jdsp->tmpBuffer[1][i] <= -1.0f)
			y2[i] = INT32_MIN;
		else if (jdsp->tmpBuffer[1][i] >= 1.0f)
			y2[i] = INT32_MAX;
		else
		{
			f = jdsp->tmpBuffer[1][i] * scale;
			y2[i] = (int32_t)(f > 0 ? f + 0.5f : f - 0.5f);
		}
	}
}
void pint32Multiplexed(JamesDSPLib *jdsp, int32_t *x, int32_t *y, size_t n)
{
	if (!jdsp_prepare_process_block(jdsp, n))
	{
		jdsp_zero_s32_interleaved(y, n);
		return;
	}
	if (jdsp->blockSize != n)
	{
		jdsp->blockSize = n;
	}
	static const float scale = (float)(1UL << 31UL);
	for (size_t i = 0; i < n; i++)
	{
		jdsp->tmpBuffer[0][i] = (float)((double)x[i << 1] / scale);
		jdsp->tmpBuffer[1][i] = (float)((double)x[(i << 1) + 1] / scale);
	}
	if (jdsp->enableASRC)
	{
		unsigned int curDecimatedLen = DoASRC_fwd(jdsp, n);
		jdsp->processInternal(jdsp, curDecimatedLen);
		DoASRC_bwd(jdsp, curDecimatedLen, n);
	}
	else
		jdsp->processInternal(jdsp, n);
	float f;
	for (size_t i = 0; i < n; i++)
	{
		if (jdsp->tmpBuffer[0][i] <= -1.0f)
			y[i << 1] = INT32_MIN;
		else if (jdsp->tmpBuffer[0][i] >= 1.0f)
			y[i << 1] = INT32_MAX;
		else
		{
			f = jdsp->tmpBuffer[0][i] * scale;
			y[i << 1] = (int32_t)(f > 0 ? f + 0.5f : f - 0.5f);
		}
		if (jdsp->tmpBuffer[1][i] <= -1.0f)
			y[(i << 1) + 1] = INT32_MIN;
		else if (jdsp->tmpBuffer[1][i] >= 1.0f)
			y[(i << 1) + 1] = INT32_MAX;
		else
		{
			f = jdsp->tmpBuffer[1][i] * scale;
			y[(i << 1) + 1] = (int32_t)(f > 0 ? f + 0.5f : f - 0.5f);
		}
	}
}
void pint8_24(JamesDSPLib *jdsp, int32_t *x1, int32_t *x2, int32_t *y1, int32_t *y2, size_t n)
{
	if (!jdsp_prepare_process_block(jdsp, n))
	{
		jdsp_zero_s32(y1, y2, n);
		return;
	}
	if (jdsp->blockSize != n)
	{
		jdsp->blockSize = n;
	}
	static const float scale = (float)(1 << 23);
	float limpos = 0x7fffff / scale;
	float limneg = -0x800000 / scale;
	for (size_t i = 0; i < n; i++)
	{
		jdsp->tmpBuffer[0][i] = (float)((double)x1[i] / scale);
		jdsp->tmpBuffer[1][i] = (float)((double)x2[i] / scale);
	}
	if (jdsp->enableASRC)
	{
		unsigned int curDecimatedLen = DoASRC_fwd(jdsp, n);
		jdsp->processInternal(jdsp, curDecimatedLen);
		DoASRC_bwd(jdsp, curDecimatedLen, n);
	}
	else
		jdsp->processInternal(jdsp, n);
	float f;
	for (size_t i = 0; i < n; i++)
	{
		f = jdsp->tmpBuffer[0][i] * scale;
		y1[i] = (int32_t)(f > 0 ? f + 0.5f : f - 0.5f);
		f = jdsp->tmpBuffer[1][i] * scale;
		y2[i] = (int32_t)(f > 0 ? f + 0.5f : f - 0.5f);
	}
}
void pint8_24Multiplexed(JamesDSPLib *jdsp, int32_t *x, int32_t *y, size_t n)
{
	if (!jdsp_prepare_process_block(jdsp, n))
	{
		jdsp_zero_s32_interleaved(y, n);
		return;
	}
	if (jdsp->blockSize != n)
	{
		jdsp->blockSize = n;
	}
	static const float scale = (float)(1 << 23);
	float limpos = 0x7fffff / scale;
	float limneg = -0x800000 / scale;
	for (size_t i = 0; i < n; i++)
	{
		jdsp->tmpBuffer[0][i] = (float)((double)x[i << 1] / scale);
		jdsp->tmpBuffer[1][i] = (float)((double)x[(i << 1) + 1] / scale);
	}
	if (jdsp->enableASRC)
	{
		unsigned int curDecimatedLen = DoASRC_fwd(jdsp, n);
		jdsp->processInternal(jdsp, curDecimatedLen);
		DoASRC_bwd(jdsp, curDecimatedLen, n);
	}
	else
		jdsp->processInternal(jdsp, n);
	float f;
	for (size_t i = 0; i < n; i++)
	{
		f = jdsp->tmpBuffer[0][i] * scale;
		y[i << 1] = (int32_t)(f > 0 ? f + 0.5f : f - 0.5f);
		f = jdsp->tmpBuffer[1][i] * scale;
		y[(i << 1) + 1] = (int32_t)(f > 0 ? f + 0.5f : f - 0.5f);
	}
}
void pintp24(JamesDSPLib *jdsp, uint8_t *x1, uint8_t *x2, uint8_t *y1, uint8_t *y2, size_t n)
{
	if (!jdsp_prepare_process_block(jdsp, n))
	{
		jdsp_zero_p24(y1, y2, n);
		return;
	}
	if (jdsp->blockSize != n)
	{
		jdsp->blockSize = n;
	}
	static const float scale = 1.0f / (float)(1UL << 31);
	for (size_t i = 0; i < n; i++)
	{
		jdsp->tmpBuffer[0][i] = jdsp->i32_from_p24(x1 + i * 3) * scale;
		jdsp->tmpBuffer[1][i] = jdsp->i32_from_p24(x2 + i * 3) * scale;
	}
	if (jdsp->enableASRC)
	{
		unsigned int curDecimatedLen = DoASRC_fwd(jdsp, n);
		jdsp->processInternal(jdsp, curDecimatedLen);
		DoASRC_bwd(jdsp, curDecimatedLen, n);
	}
	else
		jdsp->processInternal(jdsp, n);
	for (size_t i = 0; i < n; i++)
	{
		jdsp->p24_from_i32(clamp24_from_float(jdsp->tmpBuffer[0][i]), y1 + i * 3);
		jdsp->p24_from_i32(clamp24_from_float(jdsp->tmpBuffer[1][i]), y2 + i * 3);
	}
}
void pintp24Multiplexed(JamesDSPLib *jdsp, uint8_t *x, uint8_t *y, size_t n)
{
	if (!jdsp_prepare_process_block(jdsp, n))
	{
		jdsp_zero_p24_interleaved(y, n);
		return;
	}
	if (jdsp->blockSize != n)
	{
		jdsp->blockSize = n;
	}
	static const float scale = 1.0f / (float)(1UL << 31);
	for (size_t i = 0; i < n; i++)
	{
		jdsp->tmpBuffer[0][i] = jdsp->i32_from_p24(x + (i << 1) * 3) * scale;
		jdsp->tmpBuffer[1][i] = jdsp->i32_from_p24(x + ((i << 1) + 1) * 3) * scale;
	}
	if (jdsp->enableASRC)
	{
		unsigned int curDecimatedLen = DoASRC_fwd(jdsp, n);
		jdsp->processInternal(jdsp, curDecimatedLen);
		DoASRC_bwd(jdsp, curDecimatedLen, n);
	}
	else
		jdsp->processInternal(jdsp, n);
	for (size_t i = 0; i < n; i++)
	{
		jdsp->p24_from_i32(clamp24_from_float(jdsp->tmpBuffer[0][i]), y + (i << 1) * 3);
		jdsp->p24_from_i32(clamp24_from_float(jdsp->tmpBuffer[1][i]), y + ((i << 1) + 1) * 3);
	}
}
void pfloat32(JamesDSPLib *jdsp, float *x1, float *x2, float *y1, float *y2, size_t n)
{
	if (!jdsp_prepare_process_block(jdsp, n))
	{
		jdsp_zero_float(y1, y2, n);
		return;
	}
	if (jdsp->blockSize != n)
	{
		jdsp->blockSize = n;
	}
	for (size_t i = 0; i < n; i++)
	{
		jdsp->tmpBuffer[0][i] = x1[i];
		jdsp->tmpBuffer[1][i] = x2[i];
	}
	if (jdsp->enableASRC)
	{
		unsigned int curDecimatedLen = DoASRC_fwd(jdsp, n);
		jdsp->processInternal(jdsp, curDecimatedLen);
		DoASRC_bwd(jdsp, curDecimatedLen, n);
	}
	else
		jdsp->processInternal(jdsp, n);
	for (size_t i = 0; i < n; i++)
	{
		y1[i] = jdsp->tmpBuffer[0][i];
		y2[i] = jdsp->tmpBuffer[1][i];
	}
}
void pfloat32Multiplexed(JamesDSPLib *jdsp, float *x, float *y, size_t n)
{
	if (!jdsp_prepare_process_block(jdsp, n))
	{
		jdsp_zero_float_interleaved(y, n);
		return;
	}
	/* [PATCHED-AuraDSP P-060] Convolver FIFOs accept any block within the
	 * control-prepared capacity; RT block changes never rebuild or allocate. */
	jdsp->blockSize = n;
	for (size_t i = 0; i < n; i++)
	{
		jdsp->tmpBuffer[0][i] = x[i << 1];
		jdsp->tmpBuffer[1][i] = x[(i << 1) + 1];
	}
	if (jdsp->enableASRC)
	{
		unsigned int curDecimatedLen = DoASRC_fwd(jdsp, n);
		jdsp->processInternal(jdsp, curDecimatedLen);
		DoASRC_bwd(jdsp, curDecimatedLen, n);
	}
	else
		jdsp->processInternal(jdsp, n);
	for (size_t i = 0; i < n; i++)
	{
		y[i << 1] = jdsp->tmpBuffer[0][i];
		y[(i << 1) + 1] = jdsp->tmpBuffer[1][i];
	}
}
extern void JamesDSPOfflineResampling(float const *in, float *out, size_t lenIn, size_t lenOut, int channels, double src_ratio);
/* [PATCHED-AuraDSP P-021 B5] 多声道声道对选择：仅跑 ids 指定的阶段子集（默认顺序），
 * 镜像 processFloatMultiplexd 的块长/ASRC/交织处理。用于双声道效果器
 * （comp/eq/arbmag）在多声道下按掩码对选中声道对独立处理。 */
static int stage_selected(const char *ids, const char *id)
{
	const size_t l = strlen(id);
	const char *p = ids;
	while ((p = strstr(p, id)) != NULL)
	{
		const int prevOk = (p == ids) || p[-1] == ',';
		const int nextOk = (p[l] == 0) || p[l] == ',';
		if (prevOk && nextOk)
			return 1;
		p += l;
	}
	return 0;
}
void JamesDSPProcessMultiplexedStageSet(JamesDSPLib *jdsp, float *x, float *y,
                                        size_t n, const char *ids, char samplePeaks,
                                        const AuraStageGates *gates)
{
	if (!jdsp_prepare_process_block(jdsp, n))
	{
		jdsp_zero_float_interleaved(y, n);
		return;
	}
	jdsp->blockSize = n;
	for (size_t i = 0; i < n; i++)
	{
		jdsp->tmpBuffer[0][i] = x[i << 1];
		jdsp->tmpBuffer[1][i] = x[(i << 1) + 1];
	}
	if (jdsp->enableASRC)
	{
		unsigned int curDecimatedLen = DoASRC_fwd(jdsp, n);
		for (int ci = 0; ci < jdsp->chainLen; ++ci)
		{
			const unsigned int sidx = jdsp->chain[ci].stageIdx;
			if (sidx >= kAuraStageCount || !stage_selected(ids, kAuraStages[sidx].id))
				continue;
			/* [PATCHED-AuraDSP P-024 Z13] honoring per-stage lock 标志：
			 * 与 JamesDSPProcess 的 chain 表锁语义对齐。此前本路径
			 * （引擎唯一 RT 入口）完全忽略该标志，comp/convolver/ddc/
			 * liveprog 的控制侧重置与 RT 处理零互斥。 */
			const char stageLock = jdsp->chain[ci].lock;
			if (stageLock)
				jdsp_lock(jdsp);
			jdsp->chain[ci].fn(jdsp, curDecimatedLen, gates); /* B4 */
			if (stageLock)
				jdsp_unlock(jdsp);
			if (samplePeaks && sidx < 16)
			{
				float maxL = 0.0f, maxR = 0.0f;
				for (unsigned int s = 0; s < curDecimatedLen; ++s)
				{
					float aL = fabsf(jdsp->tmpBuffer[0][s]);
					float aR = fabsf(jdsp->tmpBuffer[1][s]);
					if (aL > maxL) maxL = aL;
					if (aR > maxR) maxR = aR;
				}
				jdsp->stagePeakL[sidx] = maxL;
				jdsp->stagePeakR[sidx] = maxR;
			}
		}
		DoASRC_bwd(jdsp, curDecimatedLen, n);
	}
	else
	{
		for (int ci = 0; ci < jdsp->chainLen; ++ci)
		{
			const unsigned int sidx = jdsp->chain[ci].stageIdx;
			if (sidx >= kAuraStageCount || !stage_selected(ids, kAuraStages[sidx].id))
				continue;
			/* [PATCHED-AuraDSP P-024 Z13] 同 ASRC 分支：honoring per-stage lock */
			const char stageLock = jdsp->chain[ci].lock;
			if (stageLock)
				jdsp_lock(jdsp);
			jdsp->chain[ci].fn(jdsp, n, gates); /* B4：调用级门控覆盖 */
			if (stageLock)
				jdsp_unlock(jdsp);
			if (samplePeaks && sidx < 16)
			{
				float maxL = 0.0f, maxR = 0.0f;
				for (size_t s = 0; s < n; ++s)
				{
					float aL = fabsf(jdsp->tmpBuffer[0][s]);
					float aR = fabsf(jdsp->tmpBuffer[1][s]);
					if (aL > maxL) maxL = aL;
					if (aR > maxR) maxR = aR;
				}
				jdsp->stagePeakL[sidx] = maxL;
				jdsp->stagePeakR[sidx] = maxR;
			}
		}
	}
	for (size_t i = 0; i < n; i++)
	{
		y[i << 1] = jdsp->tmpBuffer[0][i];
		y[(i << 1) + 1] = jdsp->tmpBuffer[1][i];
	}
}
// Binary blobs
extern const int hrtfLenPerChannel;
extern const int hrtfFs;
extern const int compressedLen_jdspImp;
extern const unsigned char jdspImp[7172];
extern const int compressedLen_CCConv;
extern const double ccconv1Gain;
extern const double ccconv2Gain;
extern const double ccconv3Gain;
extern const double ccconv4Gain;
extern const unsigned char CCConv[202119];
typedef struct
{
	float *blobs[4][3];
	float *hrtf[4];
	int blobLen;
	int frameLen;
} JamesDSPBlobBank;

static int jdsp_prepare_blob(double targetFs, JamesDSPBlobBank *bank)
{
	const int channelsBlobsShort = 4;
	float *(*newBlobs)[3];
	float **newHrtf;
	float *tmpBuf = NULL;
	float *pFrameImpulse = NULL;
	float *surround1 = NULL;
	float *surround2 = NULL;
	float *crossfeed = NULL;
	drflac *pFlac = NULL;
	size_t totalSmps, copySize, sampleCount, bytes;
	int outLen, i, newBlobLen = 0, newFrameLen = 0;
	double ratio;
	if (!bank || !isfinite(targetFs) || targetFs <= 0.0)
		return 0;
	memset(bank, 0, sizeof(*bank));
	newBlobs = bank->blobs;
	newHrtf = bank->hrtf;
	ratio = targetFs / (double)hrtfFs;
	{
		const double resampledLen = ceil(hrtfLenPerChannel * ratio);
		if (!isfinite(resampledLen) || resampledLen > INT_MAX)
			goto fail;
		outLen = (int)resampledLen;
	}
	if (outLen <= 0 || (size_t)outLen > SIZE_MAX / (channelsBlobsShort * sizeof(float)))
		goto fail;
	bytes = (size_t)outLen * channelsBlobsShort * sizeof(float);
	for (i = 0; i < 3; i++)
	{
		for (int c = 0; c < 4; c++)
		{
			newBlobs[c][i] = (float *)malloc((size_t)outLen * sizeof(float));
			if (!newBlobs[c][i]) goto fail;
		}
	}
	newBlobLen = outLen;
	tmpBuf = (float *)malloc(bytes);
	if (!tmpBuf) goto fail;
	memset(tmpBuf, 0, bytes);

	pFlac = drflac_open_memory((void *)jdspImp, compressedLen_jdspImp, 0);
	if (!pFlac || pFlac->channels == 0 ||
		pFlac->totalPCMFrameCount > SIZE_MAX / (size_t)pFlac->channels)
		goto fail;
	totalSmps = pFlac->totalPCMFrameCount * (size_t)pFlac->channels;
	if (totalSmps > SIZE_MAX / sizeof(float)) goto fail;
	pFrameImpulse = (float *)malloc(totalSmps * sizeof(float));
	if (!pFrameImpulse) goto fail;
	sampleCount = pFlac->totalPCMFrameCount;
	if (drflac_read_pcm_frames_f32(pFlac, totalSmps, pFrameImpulse) !=
		(size_t)pFlac->totalPCMFrameCount)
		goto fail;
	drflac_close(pFlac); pFlac = NULL;
	copySize = ((size_t)hrtfLenPerChannel << 2) * sizeof(float);
	if (totalSmps < copySize * 3 / sizeof(float)) goto fail;
	surround1 = (float *)malloc(copySize);
	surround2 = (float *)malloc(copySize);
	crossfeed = (float *)malloc(copySize);
	if (!surround1 || !surround2 || !crossfeed) goto fail;
	memcpy(surround1, pFrameImpulse, copySize);
	memcpy(surround2, pFrameImpulse + (hrtfLenPerChannel << 2), copySize);
	memcpy(crossfeed, pFrameImpulse + ((hrtfLenPerChannel << 2) << 1), copySize);
	free(pFrameImpulse); pFrameImpulse = NULL;

	{
		float *ptr[4] = { newBlobs[0][0], newBlobs[1][0], newBlobs[2][0], newBlobs[3][0] };
		JamesDSPOfflineResampling(crossfeed, tmpBuf, hrtfLenPerChannel, outLen, channelsBlobsShort, ratio);
		channel_splitFloat(tmpBuf, outLen, ptr, channelsBlobsShort);
	}
	free(crossfeed); crossfeed = NULL;
	memset(tmpBuf, 0, bytes);
	{
		float *ptr[4] = { newBlobs[0][1], newBlobs[1][1], newBlobs[2][1], newBlobs[3][1] };
		JamesDSPOfflineResampling(surround1, tmpBuf, hrtfLenPerChannel, outLen, channelsBlobsShort, ratio);
		channel_splitFloat(tmpBuf, outLen, ptr, channelsBlobsShort);
	}
	free(surround1); surround1 = NULL;
	memset(tmpBuf, 0, bytes);
	{
		float *ptr[4] = { newBlobs[0][2], newBlobs[1][2], newBlobs[2][2], newBlobs[3][2] };
		JamesDSPOfflineResampling(surround2, tmpBuf, hrtfLenPerChannel, outLen, channelsBlobsShort, ratio);
		channel_splitFloat(tmpBuf, outLen, ptr, channelsBlobsShort);
	}
	free(surround2); surround2 = NULL;
	free(tmpBuf); tmpBuf = NULL;
	free(pFrameImpulse); pFrameImpulse = NULL;

	pFlac = drflac_open_memory((void *)CCConv, compressedLen_CCConv, 0);
	if (!pFlac || pFlac->channels == 0 || pFlac->sampleRate <= 0 ||
		pFlac->totalPCMFrameCount > SIZE_MAX / (size_t)pFlac->channels)
		goto fail;
	ratio = targetFs / (double)pFlac->sampleRate;
	totalSmps = pFlac->totalPCMFrameCount * (size_t)pFlac->channels;
	if (totalSmps > SIZE_MAX / sizeof(float)) goto fail;
	pFrameImpulse = (float *)malloc(totalSmps * sizeof(float));
	if (!pFrameImpulse) goto fail;
	sampleCount = pFlac->totalPCMFrameCount;
	if (drflac_read_pcm_frames_f32(pFlac, totalSmps, pFrameImpulse) !=
		(size_t)pFlac->totalPCMFrameCount)
		goto fail;
	drflac_close(pFlac); pFlac = NULL;
	{
		const double resampledLen = ceil((double)sampleCount * ratio);
		if (!isfinite(resampledLen) || resampledLen > INT_MAX || sampleCount > INT_MAX)
			goto fail;
		outLen = (int)resampledLen;
	}
	if (outLen <= 0 ||
		(size_t)outLen > SIZE_MAX / (channelsBlobsShort * sizeof(float)))
		goto fail;
	bytes = (size_t)outLen * channelsBlobsShort * sizeof(float);
	for (i = 0; i < 4; i++)
	{
		newHrtf[i] = (float *)malloc((size_t)outLen * sizeof(float));
		if (!newHrtf[i]) goto fail;
	}
	newFrameLen = outLen;
	tmpBuf = (float *)malloc(bytes);
	if (!tmpBuf) goto fail;
	memset(tmpBuf, 0, bytes);
	JamesDSPOfflineResampling(pFrameImpulse, tmpBuf, (int)sampleCount, outLen, channelsBlobsShort, ratio);
	free(pFrameImpulse); pFrameImpulse = NULL;
	channel_splitFloat(tmpBuf, outLen, newHrtf, channelsBlobsShort);
	free(tmpBuf); tmpBuf = NULL;
	for (i = 0; i < outLen; i++)
	{
		newHrtf[0][i] = (float)((double)newHrtf[0][i] * ccconv1Gain);
		newHrtf[1][i] = (float)((double)newHrtf[1][i] * ccconv2Gain);
		newHrtf[2][i] = (float)((double)newHrtf[2][i] * ccconv3Gain);
		newHrtf[3][i] = (float)((double)newHrtf[3][i] * ccconv4Gain);
	}

	bank->blobLen = newBlobLen;
	bank->frameLen = newFrameLen;
	return 1;

fail:
	if (pFlac) drflac_close(pFlac);
	free(tmpBuf); free(pFrameImpulse);
	free(surround1); free(surround2); free(crossfeed);
	for (i = 0; i < 3; i++)
		for (int c = 0; c < 4; c++)
			free(newBlobs[c][i]);
	for (i = 0; i < 4; i++) free(newHrtf[i]);
	memset(bank, 0, sizeof(*bank));
	return 0;
}

static void jdsp_free_blob_bank(JamesDSPBlobBank *bank)
{
	if (!bank) return;
	for (int i = 0; i < 3; i++)
		for (int c = 0; c < 4; c++)
			free(bank->blobs[c][i]);
	for (int i = 0; i < 4; i++) free(bank->hrtf[i]);
	memset(bank, 0, sizeof(*bank));
}

static void jdsp_commit_blob_bank(JamesDSPLib *jdsp, JamesDSPBlobBank *bank)
{
	for (int i = 0; i < 3; i++)
	{
		free(jdsp->blobsCh1[i]); free(jdsp->blobsCh2[i]);
		free(jdsp->blobsCh3[i]); free(jdsp->blobsCh4[i]);
		jdsp->blobsCh1[i] = bank->blobs[0][i];
		jdsp->blobsCh2[i] = bank->blobs[1][i];
		jdsp->blobsCh3[i] = bank->blobs[2][i];
		jdsp->blobsCh4[i] = bank->blobs[3][i];
	}
	for (int i = 0; i < 4; i++)
	{
		free(jdsp->hrtfblobsResampled[i]);
		jdsp->hrtfblobsResampled[i] = bank->hrtf[i];
	}
	jdsp->blobsResampledLen = bank->blobLen;
	jdsp->frameLenSVirResampled = bank->frameLen;
	memset(bank, 0, sizeof(*bank));
}

int JamesDSPRefreshBlob(JamesDSPLib *jdsp, double targetFs)
{
	JamesDSPBlobBank bank;
	memset(&bank, 0, sizeof(bank));
	if (!jdsp || !jdsp_prepare_blob(targetFs, &bank))
		return 0;
	jdsp_commit_blob_bank(jdsp, &bank);
	return 1;
}
// Init JamesDSP
int JamesDSPInit(JamesDSPLib *jdsp, int n, float sample_rate)
{
	float *parts[6] = { NULL, NULL, NULL, NULL, NULL, NULL };
	float *storage;
	size_t scratch, ringSize;
	char enableASRC;
	float workFs;
	if (!jdsp || n <= 0 || !isfinite(sample_rate) ||
		floor(sample_rate) != sample_rate ||
		sample_rate < 8000.0f || sample_rate > 192000.0f)
		return 0;
	memset(jdsp, 0, sizeof(JamesDSPLib));
	// Endianness detection
	unsigned int x = 1;
	if ((((char *)&x)[0]) == 1)
	{
		jdsp->i32_from_p24 = i32_from_p24_little_endian;
		jdsp->p24_from_i32 = p24_from_i32_little_endian;
	}
	else
	{
		jdsp->i32_from_p24 = i32_from_p24_big_endian;
		jdsp->p24_from_i32 = p24_from_i32_big_endian;
	}
	//
	/* [PATCHED-AuraDSP P-062] Nested vendor setters require a recursive mutex. */
	if (aura_mutex_init_recursive(&jdsp->m_in_processing) != 0)
		jdsp->isMutexSuccess = 0;
	else
		jdsp->isMutexSuccess = 1;
	// Init buffer (capacity is published only after allocation succeeds)
	jdsp->blockSize = n;
	// Function pointer
	jdsp->processInt16Deinterleaved = pint16;
	jdsp->processInt32Deinterleaved = pint32;
	jdsp->processFloatDeinterleaved = pfloat32;
	jdsp->processInt16Multiplexd = pint16Multiplexed;
	jdsp->processInt32Multiplexd = pint32Multiplexed;
	jdsp->processFloatMultiplexd = pfloat32Multiplexed;
	jdsp->processInt8_24Multiplexd = pint8_24Multiplexed;
	jdsp->processInt24PackedMultiplexd = pintp24Multiplexed;
	jdsp->processInt8_24Deinterleaved = pint8_24;
	jdsp->processInt24PackedDeinterleaved = pintp24;
	jdsp->processInternal = JamesDSPProcessCheckBenchmarkReady;
	/* [PATCHED-AuraDSP P-004] 默认处理序 */
	JamesDSPRebuildChain(jdsp, (void *)0);
	//
	/* [PATCHED-AuraDSP P-022 D7] 抽头数见文件头 AURADSP_ASRC_TAPS（与热切路径共用） */
	char isminphase = 1;
	enableASRC = (sample_rate < 44100.0f || sample_rate > 48000.0f);
	jdsp->trueSampleRate = sample_rate;
	if (enableASRC)
	{
		int roundedRate = (int)sample_rate;
		if (((roundedRate % 48000 == 0) || (48000 % roundedRate == 0)) && roundedRate != 48000)
			workFs = 48000.0f;
		else if (((roundedRate % 44100 == 0) || (44100 % roundedRate == 0)) && roundedRate != 44100)
			workFs = 44100.0f;
		else
			workFs = 48000.0f;
	}
	else
		workFs = sample_rate;
	jdsp->fs = workFs;
	jdsp->enableASRC = enableASRC;
	if (enableASRC)
	{
		int asrcReady;
		asrcReady = InitIntegerASRCHandler(&jdsp->asrc[0], (unsigned long long)jdsp->fs,
			(unsigned long long)jdsp->trueSampleRate, AURADSP_ASRC_TAPS,
			isminphase, 0, 0);
		if (!asrcReady)
			goto init_fail;
		asrcReady = InitIntegerASRCHandler(&jdsp->asrc[1], (unsigned long long)jdsp->fs,
			(unsigned long long)jdsp->trueSampleRate, AURADSP_ASRC_TAPS,
			isminphase, &jdsp->asrc[0].polyphaseDecimator,
			&jdsp->asrc[0].polyphaseInterpolator);
		if (!asrcReady)
			goto init_fail;
	}
	storage = jdsp_create_block_storage(jdsp->fs, jdsp->trueSampleRate,
		jdsp->enableASRC, (size_t)n, parts, &scratch, &ringSize);
	if (!storage)
		goto init_fail;
	jdsp_install_block_storage(jdsp, (size_t)n, storage, parts, scratch, ringSize);
	// Init IO control
	JLimiterInit(jdsp);
	JLimiterSetCoefficients(jdsp, -(double)(FLT_EPSILON * 10.0f), 100.0);
	jdsp->limiterEnabled = 1; /* [PATCHED-AuraDSP P-012] 默认开，与上游行为一致 */
	jdsp->postGain = 1.0f;
	jdsp->postGainCh[0] = 1.0f; /* [PATCHED-AuraDSP P-037] */
	jdsp->postGainCh[1] = 1.0f;
	jdsp->numChannels = 2; /* [PATCHED-AuraDSP P-038] 默认双声道，后续由宿主按布局同步 */
	// Init effect
	LiveProgConstructor(jdsp);
	CompressorConstructor(jdsp);
	CompressorDisable(jdsp);
	BassBoostConstructor(jdsp);
	BassBoostDisable(jdsp);
	ReverbConstructor(jdsp);
	ReverbDisable(jdsp);
	StereoEnhancementConstructor(jdsp);
	StereoEnhancementDisable(jdsp);
	VacuumTubeDisable(jdsp);
	LiveProgDisable(jdsp);
	DDCConstructor(jdsp);
	DDCDisable(jdsp);
	CrossfeedConstructor(jdsp);
	CrossfeedDisable(jdsp);
	Convolver1DConstructor(jdsp);
	ArbitraryResponseEqualizerConstructor(jdsp);
	ArbitraryResponseEqualizerDisable(jdsp);
	MultimodalEqualizerConstructor(jdsp);
	MultimodalEqualizerDisable(jdsp);
	// Init binary blobs, random number generator
	jdsp->rndstate[0] = time(0);
	for (int i = 0; i < 3; i++)
	{
		jdsp->blobsCh1[i] = 0;
		jdsp->blobsCh2[i] = 0;
		jdsp->blobsCh3[i] = 0;
		jdsp->blobsCh4[i] = 0;
		for (int j = 0; j < ((n > 1) ? (n / (i + 1)) : (128)); j++)
			randXorshift(jdsp->rndstate);
	}
	if (!JamesDSPRefreshBlob(jdsp, (double)jdsp->fs))
		goto init_fail;
	jdsp->rndstate[1] = (uint64_t)(randXorshift(jdsp->rndstate) * 2.0);
#ifdef DEBUG
	__android_log_print(ANDROID_LOG_INFO, TAG, "Printing benchmark data start");
	for (int s = 0; s < MAX_BENCHMARK; s++)
		__android_log_print(ANDROID_LOG_INFO, TAG, "%1.7lf,%1.7lf", convbench_c0[s], convbench_c1[s]);
	__android_log_print(ANDROID_LOG_INFO, TAG, "Printing benchmark data end");
#endif
	return 1;

init_fail:
	StereoEnhancementDestructor(jdsp);
	CompressorDestructor(jdsp);
	LiveProgDestructor(jdsp);
	DDCDestructor(jdsp);
	CrossfeedDestructor(jdsp);
	Convolver1DDestructor(jdsp);
	ArbitraryResponseEqualizerDestructor(jdsp);
	MultimodalEqualizerDestructor(jdsp);
	if (jdsp->enableASRC)
	{
		FreeIntegerASRCHandler(&jdsp->asrc[0]);
		FreeIntegerASRCHandler(&jdsp->asrc[1]);
	}
	free(jdsp->tmpBuffer[0]);
	for (int i = 0; i < 6; ++i)
		jdsp->tmpBuffer[i] = NULL;
	if (jdsp->isMutexSuccess)
		pthread_mutex_destroy(&jdsp->m_in_processing);
	memset(jdsp, 0, sizeof(JamesDSPLib));
	return 0;
}
void JamesDSPSetPostGain(JamesDSPLib *jdsp, double pGaindB)
{
	if (pGaindB < -15.0f)
		pGaindB = -15.0f;
	if (pGaindB > 15.0f)
		pGaindB = 15.0f;
	jdsp->postGain = db2magf(pGaindB);
}
/* [PATCHED-AuraDSP P-037] stereo/matrix/binaural 逐声道补偿 (ch=0 FL, ch=1 FR) */
void JamesDSPSetPostGainCh(JamesDSPLib *jdsp, int ch, double pGaindB)
{
	if (ch < 0 || ch >= 2) return;
	if (pGaindB < -15.0f) pGaindB = -15.0f;
	if (pGaindB > 15.0f) pGaindB = 15.0f;
	jdsp->postGainCh[ch] = db2magf(pGaindB);
}
/* [PATCHED-AuraDSP P-010] 每效果输出增益门（线性）与自动补偿开关。
 * 控制线程调用；fx 越界忽略。切态重置平滑状态避免从旧值爬坡。 */
void JamesDSPSetFxOutGain(JamesDSPLib *jdsp, int fx, double linGain)
{
	/* [PATCHED-AuraDSP P-033] fx=5=reverb（WP1：vendor 路径 outgain/autogain） */
	if (fx < 0 || fx > 5) return;
	jdsp->fxOutGain[fx] = (float)linGain;
}
void JamesDSPSetFxAutoGain(JamesDSPLib *jdsp, int fx, int on)
{
	if (fx < 0 || fx > 5) return;
	jdsp->fxAutoGain[fx] = on ? 1 : 0;
	if (on)
	{
		jdsp->fxAGIn[fx] = 0.0f;
		jdsp->fxAGOut[fx] = 0.0f;
		jdsp->fxAGComp[fx] = 1.0f;
	}
}
void JamesDSPInitFxGains(JamesDSPLib *jdsp)
{
	for (int i = 0; i < 6; ++i)
	{
		jdsp->fxOutGain[i] = 1.0f;
		jdsp->fxAutoGain[i] = 0;
		jdsp->fxAGIn[i] = 0.0f;
		jdsp->fxAGOut[i] = 0.0f;
		jdsp->fxAGComp[i] = 1.0f;
	}
}
int JamesDSPGetMutexStatus(JamesDSPLib *jdsp)
{
	return jdsp->isMutexSuccess;
}
void JamesDSPSetSampleRate(JamesDSPLib *jdsp, float new_sample_rate, int forceRefresh)
{
	IntegerASRCHandler nextAsrc[2];
	JamesDSPBlobBank nextBlobs;
	float *parts[6] = { NULL, NULL, NULL, NULL, NULL, NULL };
	float *storage = NULL;
	size_t scratch, ringSize;
	char nextEnableASRC;
	float nextFs;
	int locked = 0;
	if (!jdsp || !isfinite(new_sample_rate) ||
		floor(new_sample_rate) != new_sample_rate || new_sample_rate < 8000.0f ||
		new_sample_rate > 192000.0f || jdsp->trueSampleRate == new_sample_rate)
		return;
	memset(nextAsrc, 0, sizeof(nextAsrc));
	memset(&nextBlobs, 0, sizeof(nextBlobs));
	/* [PATCHED-AuraDSP P-022 D7] 抽头数见文件头 AURADSP_ASRC_TAPS（与 init 路径共用） */
	nextEnableASRC = (new_sample_rate < 44100.0f || new_sample_rate > 48000.0f);
	if (nextEnableASRC)
	{
		int asrcReady;
		int roundedRate = (int)new_sample_rate;
		if (((roundedRate % 48000 == 0) || (48000 % roundedRate == 0)) && roundedRate != 48000)
			nextFs = 48000.0f;
		else if (((roundedRate % 44100 == 0) || (44100 % roundedRate == 0)) && roundedRate != 44100)
			nextFs = 44100.0f;
		else
			nextFs = 48000.0f;
		asrcReady = InitIntegerASRCHandler(&nextAsrc[0], (unsigned long long)nextFs,
			(unsigned long long)new_sample_rate, AURADSP_ASRC_TAPS, 1, 0, 0);
		if (!asrcReady)
			goto rate_fail;
		asrcReady = InitIntegerASRCHandler(&nextAsrc[1], (unsigned long long)nextFs,
			(unsigned long long)new_sample_rate, AURADSP_ASRC_TAPS, 1,
			&nextAsrc[0].polyphaseDecimator, &nextAsrc[0].polyphaseInterpolator);
		if (!asrcReady)
			goto rate_fail;
	}
	else
		nextFs = new_sample_rate;

	/* [PATCHED-AuraDSP P-060] Build replacement filters, storage and blob bank
	 * outside the RT-facing lock; failure leaves the old state fully usable. */
	storage = jdsp_create_block_storage(nextFs, new_sample_rate, nextEnableASRC,
		jdsp->blockSizeMax, parts, &scratch, &ringSize);
	if (!storage)
		goto rate_fail;
	if (!jdsp_prepare_blob(nextFs, &nextBlobs))
		goto rate_fail;
	jdsp_lock(jdsp);
	locked = 1;
	jdsp_commit_blob_bank(jdsp, &nextBlobs);
	if (jdsp->enableASRC)
	{
		FreeIntegerASRCHandler(&jdsp->asrc[0]);
		FreeIntegerASRCHandler(&jdsp->asrc[1]);
	}
	jdsp->asrc[0] = nextAsrc[0];
	jdsp->asrc[1] = nextAsrc[1];
	jdsp_install_block_storage(jdsp, jdsp->blockSizeMax, storage, parts,
		scratch, ringSize);
	jdsp->trueSampleRate = new_sample_rate;
	jdsp->fs = nextFs;
	jdsp->enableASRC = nextEnableASRC;
	if (forceRefresh)
	{
		BassBoostSetParam(jdsp, jdsp->dbb.maxGain);
		jdsp->ddcForceRefresh = 1;
		DDCEnable(jdsp, jdsp->ddcEnabled);
		jdsp->crossfeedForceRefresh = 1;
		CrossfeedEnable(jdsp, jdsp->crossfeedEnabled);
		jdsp->arbMagForceRefresh = 1;
		ArbitraryResponseEqualizerEnable(jdsp, jdsp->arbitraryMagEnabled);
		jdsp->equalizerForceRefresh = 1;
		MultimodalEqualizerEnable(jdsp, jdsp->equalizerEnabled);
		jdsp->compForceRefresh = 1;
		CompressorEnable(jdsp, jdsp->compEnabled);
		StereoEnhancementRefresh(jdsp);
	}
	jdsp_unlock(jdsp);
	return;

rate_fail:
	FreeIntegerASRCHandler(&nextAsrc[0]);
	FreeIntegerASRCHandler(&nextAsrc[1]);
	free(storage);
	jdsp_free_blob_bank(&nextBlobs);
	if (locked) jdsp_unlock(jdsp);
}
void JamesDSPFree(JamesDSPLib *jdsp)
{
	if (!jdsp) return;
	jdsp_lock(jdsp);
	StereoEnhancementDestructor(jdsp);
	CompressorDestructor(jdsp);
	LiveProgDestructor(jdsp);
	DDCDestructor(jdsp);
	CrossfeedDestructor(jdsp);
	ReverbDestructor(jdsp);
	Convolver1DDestructor(jdsp);
	ArbitraryResponseEqualizerDestructor(jdsp);
	MultimodalEqualizerDestructor(jdsp);
	if (jdsp->tmpBuffer[0])
		free(jdsp->tmpBuffer[0]);
	for (int i = 0; i < 6; ++i)
		jdsp->tmpBuffer[i] = NULL;
	jdsp->blockSize = 0;
	jdsp->blockSizeMax = 0;
	jdsp->asrcScratchSize = 0;
	jdsp->pw2BlockMemSize = 0;
	int i;
	if (jdsp->blobsCh1[0])
	{
		for (i = 0; i < 3; i++)
		{
			free(jdsp->blobsCh1[i]);
			free(jdsp->blobsCh2[i]);
			free(jdsp->blobsCh3[i]);
			free(jdsp->blobsCh4[i]);
		}
	}
	if (jdsp->hrtfblobsResampled[0])
	{
		for (i = 0; i < 4; i++)
			free(jdsp->hrtfblobsResampled[i]);
	}
	if (jdsp->impulseResponseStorage.impulseResponse)
		free(jdsp->impulseResponseStorage.impulseResponse);
	if (jdsp->enableASRC)
	{
		FreeIntegerASRCHandler(&jdsp->asrc[0]);
		FreeIntegerASRCHandler(&jdsp->asrc[1]);
	}
	/* [PATCHED-AuraDSP P-062] Unlock before destroy; destroying a locked mutex
	 * and then unlocking it is undefined on POSIX. */
	jdsp_unlock(jdsp);
	if (jdsp->isMutexSuccess)
	{
		pthread_mutex_destroy(&jdsp->m_in_processing);
		jdsp->isMutexSuccess = 0;
	}
}