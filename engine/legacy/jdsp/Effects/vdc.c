#include <string.h>
#include <stdlib.h>
#include <errno.h>
#include <math.h>
#include <float.h>
#include "../jdsp_header.h"
#ifdef _WIN32
#include <intrin.h>
#endif
double SOS_DF2Process(DirectForm2 *df2, double x1)
{
	double w1 = x1 - df2->a1*df2->v1L - df2->a2*df2->v2L;
	double y1 = df2->b0*w1 + df2->b1*df2->v1L + df2->b2*df2->v2L;
	df2->v2L = df2->v1L;
	df2->v1L = w1;
	return y1;
}
void SOS_DF2_StereoProcess(DirectForm2 *df2, double x1, double x2, double *Out_y1, double *Out_y2)
{
	double w1 = x1 - df2->a1*df2->v1L - df2->a2*df2->v2L;
	double y1 = df2->b0*w1 + df2->b1*df2->v1L + df2->b2*df2->v2L;
	df2->v2L = df2->v1L;
	df2->v1L = w1;
	*Out_y1 = y1;
	double w2 = x2 - df2->a1*df2->v1R - df2->a2*df2->v2R;
	double y2 = df2->b0*w2 + df2->b1*df2->v1R + df2->b2*df2->v2R;
	df2->v2R = df2->v1R;
	df2->v1R = w2;
	*Out_y2 = y2;
}
/* [PATCHED-AuraDSP B1-b] 改迭代实现：原版按字符递归（深度=剩余串长），
 * 大 VDC 文件（实测 ~107KB，1600 段 SOS）即栈溢出崩溃（countChars 从
 * SR_48000 标记起递归到串尾）。语义不变：统计 s 中 c 的出现次数。 */
int countChars(char* s, char c)
{
	int n = 0;
	for (; *s; ++s)
		if (*s == c)
			n++;
	return n;
}
int get_doubleVDC(char *val, double *F)
{
	char *eptr;
	errno = 0;
	double f = strtod(val, &eptr);
	if (eptr != val && errno != ERANGE)
	{
		*F = f;
		return 1;
	}
	return 0;
}
int DDCParser(char *DDCString, DirectForm2 **ptrdf441, DirectForm2 **ptrdf48)
{
	char *fs44_1 = strstr(DDCString, "SR_44100");
	char *fs48 = strstr(DDCString, "SR_48000");
	if (!fs44_1 || !fs48)
		return 0;
	int numberCount = (countChars(fs48, ',') + 1);
	int sosCount = numberCount / 5;
	if (!sosCount)
		return 0;
	DirectForm2 *df441 = (DirectForm2*)malloc(sosCount * sizeof(DirectForm2));
	DirectForm2 *df48 = (DirectForm2*)malloc(sosCount * sizeof(DirectForm2));
	memset(df441, 0, sosCount * sizeof(DirectForm2));
	memset(df48, 0, sosCount * sizeof(DirectForm2));
	double number;
	int i = 0;
	int counter = 0;
	int b0b1b2a1a2 = 0;
	char *startingPoint = fs44_1 + 9;
	while (counter < numberCount)
	{
		if (get_doubleVDC(startingPoint, &number))
		{
			double val = strtod(startingPoint, &startingPoint);
			counter++;
			if (!b0b1b2a1a2)
				df441[i].b0 = val;
			else if (b0b1b2a1a2 == 1)
				df441[i].b1 = val;
			else if (b0b1b2a1a2 == 2)
				df441[i].b2 = val;
			else if (b0b1b2a1a2 == 3)
				df441[i].a1 = -val;
			else if (b0b1b2a1a2 == 4)
			{
				df441[i].a2 = -val;
				i++;
			}
			b0b1b2a1a2++;
			if (b0b1b2a1a2 == 5)
				b0b1b2a1a2 = 0;
		}
		else
			startingPoint++;
	}
	i = 0;
	counter = 0;
	b0b1b2a1a2 = 0;
	startingPoint = fs48 + 9;
	while (counter < numberCount)
	{
		if (get_doubleVDC(startingPoint, &number))
		{
			double val = strtod(startingPoint, &startingPoint);
			counter++;
			if (!b0b1b2a1a2)
				df48[i].b0 = val;
			else if (b0b1b2a1a2 == 1)
				df48[i].b1 = val;
			else if (b0b1b2a1a2 == 2)
				df48[i].b2 = val;
			else if (b0b1b2a1a2 == 3)
				df48[i].a1 = -val;
			else if (b0b1b2a1a2 == 4)
			{
				df48[i].a2 = -val;
				i++;
			}
			b0b1b2a1a2++;
			if (b0b1b2a1a2 == 5)
				b0b1b2a1a2 = 0;
		}
		else
			startingPoint++;
	}
	*ptrdf441 = df441;
	*ptrdf48 = df48;
	return sosCount;
}
void complexMultiplicationRI(double *zReal, double *zImag, double xReal, double xImag, double yReal, double yImag)
{
	*zReal = xReal * yReal - xImag * yImag;
	*zImag = xReal * yImag + xImag * yReal;
}
void complexDivisionRI(double *zReal, double *zImag, double xReal, double xImag, double yReal, double yImag)
{
	*zReal = (xReal * yReal + xImag * yImag) / (yReal * yReal + yImag * yImag);
	*zImag = (xImag * yReal - xReal * yImag) / (yReal * yReal + yImag * yImag);
}
// Analytical magnitude response of digital filters
void DigitalFilterMagnitudeResponsedB(DirectForm2 *IIR, int section, double *magnitude, int NumPts)
{
	double Arg;
	double z1Real, z1Imag, z2Real, z2Imag, HofZReal, HofZImag, DenomReal, DenomImag, tmpReal, tmpImag;
	for (int j = 0; j < NumPts; j++)
	{
		Arg = M_PI * (double)j / (double)NumPts;
		z1Real = cos(Arg), z1Imag = -sin(Arg);
		complexMultiplicationRI(&z2Real, &z2Imag, z1Real, z1Imag, z1Real, z1Imag);
		HofZReal = 1.0, HofZImag = 0.0;
		tmpReal = IIR[section].b0 + IIR[section].b1 * z1Real + IIR[section].b2 * z2Real;
		tmpImag = IIR[section].b1 * z1Imag + IIR[section].b2 * z2Imag;
		complexMultiplicationRI(&HofZReal, &HofZImag, HofZReal, HofZImag, tmpReal, tmpImag);
		DenomReal = 1.0 + IIR[section].a1 * z1Real + IIR[section].a2 * z2Real;
		DenomImag = IIR[section].a1 * z1Imag + IIR[section].a2 * z2Imag;
		if (sqrt(DenomReal * DenomReal + DenomImag * DenomImag) < DBL_EPSILON)
			magnitude[j] = 0.0;
		else
		{
			complexDivisionRI(&HofZReal, &HofZImag, HofZReal, HofZImag, DenomReal, DenomImag);
			magnitude[j] = 20.0 * log10(sqrt(HofZReal * HofZReal + HofZImag * HofZImag));
		}
	}
}
// DDC resampler
void designPeakingFilter(double dbGain, double centreFreq, double fs, double dBandwidthOrQOrS, double *b0, double *b1, double *b2, double *a1, double *a2)
{
	if (centreFreq <= DBL_EPSILON || fs <= DBL_EPSILON)
		return;
	const double at1d3 = atanh(1.0 / 3.0);
	double lingain = pow(10.0, dbGain / 40.0);
	double omega = (6.2831853071795862 * centreFreq) / fs;
	double num3 = sin(omega);
	double cs = cos(omega);
	double alpha = num3 * sinh((at1d3 * dBandwidthOrQOrS * omega) / num3);
	double B0 = 1.0 + (alpha * lingain);
	double B1 = -2.0 * cs;
	double B2 = 1.0 - (alpha * lingain);
	double A0 = 1.0 + (alpha / lingain);
	double A1 = -2.0 * cs;
	double A2 = 1.0 - (alpha / lingain);
	*b0 = B0 / A0;
	*b1 = B1 / A0;
	*b2 = B2 / A0;
	*a1 = A1 / A0;
	*a2 = A2 / A0;
}
int PeakingFilterResampler(DirectForm2 *inputIIR, double inFs, DirectForm2 **resampledIIR, double outFs, int sosCount)
{
	const int filterTestLength = 32768;
	double *magnitude = (double*)malloc(filterTestLength * sizeof(double));
	int i;
	int outSOSCount = 0;
	double *cell[3];
	for (i = 0; i < 3; i++)
		cell[i] = (double*)malloc(sosCount * sizeof(double));
	for (i = 0; i < sosCount; i++)
	{
		DigitalFilterMagnitudeResponsedB(inputIIR, i, magnitude, filterTestLength);
		double absoluteMax = fabs(magnitude[0]);
		double centreFreq = 0.0;
		int index = 0;
		for (int c = 1; c < filterTestLength; c++)
		{
			if (fabs(magnitude[c]) > absoluteMax)
			{
				absoluteMax = fabs(magnitude[c]);
				index = c;
				centreFreq = round(c * (inFs / filterTestLength / 2.0));
			}
		}
		if (centreFreq < DBL_EPSILON)
			centreFreq = DBL_EPSILON;
		if (fabs(inputIIR[i].b1) < DBL_EPSILON)
		{
			if (inputIIR[i].b1 < 0.0)
				inputIIR[i].b1 = -DBL_EPSILON;
			else
				inputIIR[i].b1 = DBL_EPSILON;
		}
		double omega = (6.2831853071795862 * centreFreq) / inFs;
		double A0 = (-2.0 * cos(omega)) / inputIIR[i].b1;
		double lingain = pow(10.0, magnitude[index] / 40.0);
		double num3 = sin(omega);
		double bandwidth = ((asinh(((A0 - 1.0) * lingain) / num3) * num3) / omega) / 0.34657359027997264;
		if (bandwidth > 98.8 - DBL_EPSILON)
			bandwidth = 98.8;
		if (centreFreq < outFs - DBL_EPSILON)
			outSOSCount++;
		cell[0][i] = magnitude[index];
		cell[1][i] = centreFreq;
		cell[2][i] = bandwidth;
	}
	free(magnitude);
	/* [PATCHED-AuraDSP B1-b] 原实现此处连续两次 malloc（第一次结果被
	 * 第二次覆盖）→ 每次非 44.1/48k 直采频率都泄漏 outSOSCount 个
	 * DirectForm2；删掉丢失引用的第一次分配。 */
	DirectForm2 *temp = (DirectForm2*)malloc(outSOSCount * sizeof(DirectForm2));
	memset(temp, 0, outSOSCount * sizeof(DirectForm2));
	for (i = 0; i < outSOSCount; i++)
		designPeakingFilter(cell[0][i], cell[1][i], outFs, cell[2][i], &temp[i].b0, &temp[i].b1, &temp[i].b2, &temp[i].a1, &temp[i].a2);
	for (i = 0; i < 3; i++)
		free(cell[i]);
	*resampledIIR = temp;
	return outSOSCount;
}
/* [PATCHED-AuraDSP B1-b] 影子视图 + 原子换指针（替代原「持 jdsp_lock
 * 原地换 sosPointer/usedSOSCount」）。设计同 B1-a liveprog / P-006 mEQ：
 *   - AURA_DDC_SLOTS(3) 个预分配视图槽，jdsp->ddcActive 指向活动视图；
 *   - 控制线程解析出新 SOS 数组后装填非活动槽并原子换指针；RT 块首读一次
 *     指针即得 {sosPointer, usedSOSCount} 一致对，块内不碰换出视图；
 *   - 在途守卫双条件任一满足即可复用换下的槽：
 *       a) ddcInFlight == 0——无在途 DDCProcess（覆盖音频停流时
 *          ddcProcCount 冻结导致连续加载全部「引擎忙」的可用性洞）；
 *       b) ddcProcCount >= retiredAt——换下后跑满 1 个音频块；
 *   - 皆不满足时有界等待 500ms 墙钟，仍无槽返回 -4（上层映射「引擎忙」），
 *     绝不退化到活动视图原地改写（UAF）；
 *   - stage_ddc 的 lock 标志置 0：RT 不再为 ddc 取锁。
 */
#define kDdcSlots AURA_DDC_SLOTS
#define kDdcSlotWaitMs 500

static long ddc_inflight_inc(volatile long *p)
{
#ifdef _WIN32
	return _InterlockedIncrement(p);
#else
	return __sync_add_and_fetch((long*)p, 1);
#endif
}
static long ddc_inflight_dec(volatile long *p)
{
#ifdef _WIN32
	return _InterlockedDecrement(p);
#else
	return __sync_sub_and_fetch((long*)p, 1);
#endif
}
static long ddc_inflight_load(volatile long *p)
{
#ifdef _WIN32
	return _InterlockedCompareExchange(p, 0, 0);
#else
	return __sync_val_compare_and_swap((long*)p, 0, 0);
#endif
}
static double ddc_now_ms(void)
{
#ifdef _WIN32
	return (double)GetTickCount64();
#else
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1000000.0;
#endif
}
static void ddc_sleep_ms(unsigned int ms)
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
void DDCConstructor(JamesDSPLib *jdsp)
{
	jdsp->vdcFl.oldFile = 0;
	for (int i = 0; i < kDdcSlots; ++i)
	{
		jdsp->ddcSlots[i].sosPointer = 0;
		jdsp->ddcSlots[i].usedSOSCount = 0;
		jdsp->ddcSlots[i].retiredAt = 0;
	}
	jdsp->ddcActive = &jdsp->ddcSlots[0];
	jdsp->ddcProcCount = 0;
	jdsp->ddcInFlight = 0;
}
void DDCDestructor(JamesDSPLib *jdsp)
{
	for (int i = 0; i < kDdcSlots; ++i)
	{
		if (jdsp->ddcSlots[i].sosPointer)
		{
			free(jdsp->ddcSlots[i].sosPointer);
			jdsp->ddcSlots[i].sosPointer = 0;
		}
		jdsp->ddcSlots[i].usedSOSCount = 0;
	}
	if (jdsp->vdcFl.oldFile)
	{
		free(jdsp->vdcFl.oldFile);
		jdsp->vdcFl.oldFile = 0;
	}
	jdsp->ddcActive = 0;
}
/* 选编译目标视图：非活动 + 在途守卫通过（双条件任一满足）。 */
static DDCView *DDCPickSlot(JamesDSPLib *jdsp)
{
	const long inFlight = ddc_inflight_load(&jdsp->ddcInFlight);
	for (int i = 0; i < kDdcSlots; ++i)
	{
		DDCView *s = &jdsp->ddcSlots[i];
		if (s == jdsp->ddcActive)
			continue;
		if (inFlight != 0 && jdsp->ddcProcCount < s->retiredAt)
			continue;
		return s;
	}
	return 0;
}
/* 解析 inStr 构建新 SOS 数组并原子换入。返回 1=成功；0=解析失败
 * （活动视图不变，旧校正继续生效）；-4=引擎忙（无可用视图槽）。
 * 槽内旧数组在复用本槽时才释放——彼时在途守卫已保证无 RT 引用。 */
int DDCRefresh(JamesDSPLib *jdsp, char *inStr)
{
	if (!inStr)
		return 0;
	DirectForm2 *df441 = 0, *df48 = 0;
	int sosCount = DDCParser(inStr, &df441, &df48);
	if (!sosCount)
	{
		free(df441);
		free(df48);
		return 0;
	}
	DDCView *target = DDCPickSlot(jdsp);
	if (!target)
	{
		const double deadline = ddc_now_ms() + kDdcSlotWaitMs;
		for (;;)
		{
			ddc_sleep_ms(1);
			target = DDCPickSlot(jdsp);
			if (target)
				break;
			if (ddc_now_ms() >= deadline)
			{
				free(df441);
				free(df48);
				return -4;
			}
		}
	}
	DirectForm2 *chosen;
	if (jdsp->fs == 44100.0f && df441)
	{
		chosen = df441;
		free(df48);
	}
	else if (jdsp->fs == 48000.0f && df48)
	{
		chosen = df48;
		free(df441);
	}
	else
	{
		DirectForm2 *dfResampled;
		int resampledSOSCount = PeakingFilterResampler(df48, 48000.0, &dfResampled, jdsp->fs, sosCount);
		chosen = dfResampled;
		sosCount = resampledSOSCount;
		free(df441);
		free(df48);
	}
	/* 装填目标视图（守卫已保证无在途 RT 引用其旧数组，先释放） */
	if (target->sosPointer)
		free(target->sosPointer);
	target->sosPointer = chosen;
	target->usedSOSCount = sosCount;
	target->retiredAt = 0;
	DDCView *prev = jdsp->ddcActive;
	/* 原子换指针（x86-64 对齐指针存即原子；RT 块首只读一次） */
	jdsp->ddcActive = target;
	if (prev && prev != target)
		prev->retiredAt = jdsp->ddcProcCount + 1;
	return 1;
}
int DDCEnable(JamesDSPLib *jdsp, char enable)
{
	int success = 1;
	if (jdsp->ddcForceRefresh)
	{
		success = DDCRefresh(jdsp, jdsp->vdcFl.oldFile);
		jdsp->ddcForceRefresh = 0;
	}
	DDCView *v = jdsp->ddcActive;
	if (success != 1 || !v || !v->usedSOSCount || !v->sosPointer)
	{
		jdsp->ddcEnabled = 0;
		return success == 1 ? -1 : success;
	}
	else
	{
		if (enable)
			jdsp->ddcEnabled = 1;
		return 1;
	}
}
void DDCDisable(JamesDSPLib *jdsp)
{
	jdsp->ddcEnabled = 0;
}
int DDCStringParser(JamesDSPLib *jdsp, char *newStr)
{
	/* B1-b：不再持 jdsp_lock——RT 改为块首读一次 ddcActive 快照
	 * （见 DDCProcess），解析全程在控制线程，换指针原子完成。 */
	if (jdsp->vdcFl.oldFile)
	{
		if (!strcmp(jdsp->vdcFl.oldFile, newStr))
			return 0;
	}
	int success = DDCRefresh(jdsp, newStr);
	if (success != 1)
	{
		/* 失败保留旧视图（活动 DDC 继续生效——与 B1-a liveprog 一致：
		 * 加载失败不影响正在跑的校正）；忙（-4）原样透传区别文案。 */
		if (jdsp->vdcFl.oldFile)
		{
			free(jdsp->vdcFl.oldFile);
			jdsp->vdcFl.oldFile = 0;
		}
		return success == 0 ? -1 : success;
	}
	if (jdsp->vdcFl.oldFile)
		free(jdsp->vdcFl.oldFile);
	size_t stLe = strlen(newStr);
	jdsp->vdcFl.oldFile = (char*)malloc(stLe + 1);
	strncpy(jdsp->vdcFl.oldFile, newStr, stLe);
	jdsp->vdcFl.oldFile[stLe] = '\0';
	return 1;
}
void DDCProcess(JamesDSPLib *jdsp, size_t n)
{
	/* B1-b：在途守卫双计数（同 B1-a liveprog）——RT 单写者，每块必过
	 * （stage_ddc 恒在链中），与 ddcEnabled 无关。 */
	jdsp->ddcProcCount++;
	ddc_inflight_inc(&jdsp->ddcInFlight);
	if (jdsp->ddcEnabled)
	{
		/* 块首一次读取活动视图；解析期换指针不影响本块后续样本 */
		DDCView *v = jdsp->ddcActive;
		if (v && v->usedSOSCount && v->sosPointer)
		{
			for (size_t i = 0; i < n; i++)
			{
				double sampleOutL = (double)jdsp->tmpBuffer[0][i], sampleOutR = (double)jdsp->tmpBuffer[1][i];
				for (int j = 0; j < v->usedSOSCount; j++)
					SOS_DF2_StereoProcess(&v->sosPointer[j], sampleOutL, sampleOutR, &sampleOutL, &sampleOutR);
				jdsp->tmpBuffer[0][i] = (float)sampleOutL;
				jdsp->tmpBuffer[1][i] = (float)sampleOutR;
			}
		}
	}
	ddc_inflight_dec(&jdsp->ddcInFlight);
}
