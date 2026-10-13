#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <float.h>
#include "../jdsp_header.h"
void VTInit(VacuumTube *tb, double fs)
{
	tb->pregain = 1.0f;
	tb->postgain = 1.0f;
	tb->needOversample = 0;
	if (fs >= 30000.0 && fs < 65000.0)
	{
		oversample_makeSmp(&tb->smp[0], 2);
		oversample_makeSmp(&tb->smp[1], 2);
		tb->needOversample = 1;
	}
	else if (fs >= 20000.0 && fs < 30000.0)
	{
		oversample_makeSmp(&tb->smp[0], 3);
		oversample_makeSmp(&tb->smp[1], 3);
		tb->needOversample = 1;
	}
	else if (fs >= 14000.0 && fs < 20000.0)
	{
		oversample_makeSmp(&tb->smp[0], 4);
		oversample_makeSmp(&tb->smp[1], 4);
		tb->needOversample = 1;
	}
	else if (fs < 14000.0)
	{
		oversample_makeSmp(&tb->smp[0], 5);
		oversample_makeSmp(&tb->smp[1], 5);
		tb->needOversample = 1;
	}
	memset(tb->subband, 0, sizeof(tb->subband));
	/* [PATCHED-AuraDSP 2026-10-13 P-011] Tape 阻尼状态每次 Enable 清零；
	 * character/drywet/outcomp 故意不碰（开关不丢用户值，由引擎 apply_tube 推送）。 */
	tb->tapeLp[0] = 0.0f;
	tb->tapeLp[1] = 0.0f;
	init6BandsCrossover(&tb->subband[0], fs, 300.0, 950.0, 2200.0, 4000.0, 6000.0);
	init6BandsCrossover(&tb->subband[1], fs, 300.0, 950.0, 2200.0, 4000.0, 6000.0);
}
void VTProcess(VacuumTube *tb, float *x1, float *x2, float *out1, float *out2, size_t n)
{
	float upsample[2][5];
	double bandCh1[6], bandCh2[6];
	/* [PATCHED-AuraDSP 2026-10-13 P-011] 音色调度（纯查表+乘加，RT 安全）：
	 * Triode(0)=旧行为逐位一致；Pentode(1)=谐波更猛+静态 trim 防响度跳变；
	 * Tape(2)=谐波减半+湿信号一阶 HF 阻尼。drywet/outcomp 在两条输出路径统一应用。 */
	float hwMul, trim, lpCoef;
	if (tb->character == 1)       { hwMul = 1.8f; trim = 1.00f; lpCoef = 0.0f; }
	else if (tb->character == 2)  { hwMul = 0.5f; trim = 1.05f; lpCoef = 0.5f; }
	else                          { hwMul = 1.0f; trim = 1.0f;  lpCoef = 0.0f; }
	const float hwOS = 0.2f * hwMul;
	const float hwD = 0.25f * hwMul;
	const float compLin = (float)pow(10.0, (double)tb->outcomp * 0.05);
	const float wetK = tb->drywet;
	const float dryK = 1.0f - wetK;
	if (tb->needOversample)
	{
		for (size_t i = 0; i < n; i++)
		{
			char state1[6] = { 0 };
			char state2[6] = { 0 };
			oversample_stepupSmp(&tb->smp[0], x1[i] * tb->pregain, upsample[0]);
			oversample_stepupSmp(&tb->smp[1], x2[i] * tb->pregain, upsample[1]);
			for (int j = 0; j < tb->smp[0].factor; j++)
			{
				process6BandsCrossover(&tb->subband[0], upsample[0][j], &bandCh1[0], &bandCh1[1], &bandCh1[2], &bandCh1[3], &bandCh1[4], &bandCh1[5]);
				process6BandsCrossover(&tb->subband[1], upsample[1][j], &bandCh2[0], &bandCh2[1], &bandCh2[2], &bandCh2[3], &bandCh2[4], &bandCh2[5]);
				bandCh1[1] = -bandCh1[1];
				bandCh1[3] = -bandCh1[3];
				bandCh1[5] = -bandCh1[5];
				bandCh2[1] = -bandCh2[1];
				bandCh2[3] = -bandCh2[3];
				bandCh2[5] = -bandCh2[5];
				double allpassCh1 = bandCh1[1] + bandCh1[2] + bandCh1[3] + bandCh1[4];
				double harmonic2Ch1 = bandCh1[1] * bandCh1[1];
				double harmonic3Ch1 = bandCh1[2] * bandCh1[2];
				double harmonic4Ch1 = bandCh1[3] * bandCh1[3];
				double harmonic5Ch1 = bandCh1[4] * bandCh1[4];
				double allpassCh2 = bandCh2[1] + bandCh2[2] + bandCh2[3] + bandCh2[4];
				double harmonic2Ch2 = bandCh2[1] * bandCh2[1];
				double harmonic3Ch2 = bandCh2[2] * bandCh2[2];
				double harmonic4Ch2 = bandCh2[3] * bandCh2[3];
				double harmonic5Ch2 = bandCh2[4] * bandCh2[4];
			upsample[0][j] = (float)(bandCh1[0] + (harmonic2Ch1 + harmonic3Ch1 + harmonic4Ch1 + harmonic5Ch1) * hwOS + allpassCh1 + bandCh1[5]);
			upsample[1][j] = (float)(bandCh2[0] + (harmonic2Ch2 + harmonic3Ch2 + harmonic4Ch2 + harmonic5Ch2) * hwOS + allpassCh2 + bandCh2[5]);
		}
		/* [PATCHED-AuraDSP 2026-10-13 P-011] wet 整形：trim→Tape阻尼→补偿→干湿混合（dry 取原始输入）。 */
		float w1 = oversample_stepdownSmpFloat(&tb->smp[0], upsample[0]) * tb->postgain * trim;
		float w2 = oversample_stepdownSmpFloat(&tb->smp[1], upsample[1]) * tb->postgain * trim;
		if (lpCoef > 0.0f)
		{
			tb->tapeLp[0] += lpCoef * (w1 - tb->tapeLp[0]);
			tb->tapeLp[1] += lpCoef * (w2 - tb->tapeLp[1]);
			w1 = tb->tapeLp[0];
			w2 = tb->tapeLp[1];
		}
		w1 *= compLin;
		w2 *= compLin;
		out1[i] = x1[i] * dryK + w1 * wetK;
		out2[i] = x2[i] * dryK + w2 * wetK;
		}
	}
	else
	{
		for (size_t j = 0; j < n; j++)
		{
			process6BandsCrossover(&tb->subband[0], x1[j] * tb->pregain, &bandCh1[0], &bandCh1[1], &bandCh1[2], &bandCh1[3], &bandCh1[4], &bandCh1[5]);
			process6BandsCrossover(&tb->subband[1], x2[j] * tb->pregain, &bandCh2[0], &bandCh2[1], &bandCh2[2], &bandCh2[3], &bandCh2[4], &bandCh2[5]);
			bandCh1[1] = -bandCh1[1];
			bandCh1[3] = -bandCh1[3];
			bandCh1[5] = -bandCh1[5];
			bandCh2[1] = -bandCh2[1];
			bandCh2[3] = -bandCh2[3];
			bandCh2[5] = -bandCh2[5];
			double allpassCh1 = bandCh1[1] + bandCh1[2] + bandCh1[3] + bandCh1[4];
			double harmonic2Ch1 = bandCh1[1] * bandCh1[1];
			double harmonic3Ch1 = bandCh1[2] * bandCh1[2];
			double harmonic4Ch1 = bandCh1[3] * bandCh1[3];
			double harmonic5Ch1 = bandCh1[4] * bandCh1[4];
			double allpassCh2 = bandCh2[1] + bandCh2[2] + bandCh2[3] + bandCh2[4];
			double harmonic2Ch2 = bandCh2[1] * bandCh2[1];
			double harmonic3Ch2 = bandCh2[2] * bandCh2[2];
			double harmonic4Ch2 = bandCh2[3] * bandCh2[3];
			double harmonic5Ch2 = bandCh2[4] * bandCh2[4];
		out1[j] = (float)(bandCh1[0] + (harmonic2Ch1 + harmonic3Ch1 + harmonic4Ch1 + harmonic5Ch1) * hwD + allpassCh1 + bandCh1[5]) * tb->postgain;
		out2[j] = (float)(bandCh2[0] + (harmonic2Ch2 + harmonic3Ch2 + harmonic4Ch2 + harmonic5Ch2) * hwD + allpassCh2 + bandCh2[5]) * tb->postgain;
		/* [PATCHED-AuraDSP 2026-10-13 P-011] wet 整形（与过采样分支同构）：trim→Tape阻尼→补偿→干湿混合。 */
		{
			float w1 = out1[j] * trim;
			float w2 = out2[j] * trim;
			if (lpCoef > 0.0f)
			{
				tb->tapeLp[0] += lpCoef * (w1 - tb->tapeLp[0]);
				tb->tapeLp[1] += lpCoef * (w2 - tb->tapeLp[1]);
				w1 = tb->tapeLp[0];
				w2 = tb->tapeLp[1];
			}
			w1 *= compLin;
			w2 *= compLin;
			out1[j] = x1[j] * dryK + w1 * wetK;
			out2[j] = x2[j] * dryK + w2 * wetK;
		}
		}
	}
}
void VacuumTubeEnable(JamesDSPLib *jdsp)
{
	VTInit(&jdsp->tube, jdsp->fs);
	jdsp->tubeEnabled = 1;
}
void VacuumTubeDisable(JamesDSPLib *jdsp)
{
	jdsp->tubeEnabled = 0;
}
void VacuumTubeSetGain(JamesDSPLib *jdsp, double dbGain)
{
	if (dbGain > 12.0)
		dbGain = 12.0;
	if (dbGain < -3.0)
		dbGain = -3.0;
	jdsp->tube.pregain = db2magf(dbGain);
	jdsp->tube.postgain = 1.0f / jdsp->tube.pregain;
}
/* [PATCHED-AuraDSP 2026-10-13 P-011] 电子管音色/混合/补偿 setter。
 * 控制线程调用、RT 只读；x86 对齐 int/float 单字写无撕裂（与 pregain 同模式）。 */
void VacuumTubeSetCharacter(JamesDSPLib *jdsp, int character)
{
	if (character < 0)
		character = 0;
	if (character > 2)
		character = 2;
	jdsp->tube.character = character;
}
void VacuumTubeSetDryWet(JamesDSPLib *jdsp, float mix)
{
	if (mix < 0.0f)
		mix = 0.0f;
	if (mix > 1.0f)
		mix = 1.0f;
	jdsp->tube.drywet = mix;
}
void VacuumTubeSetOutComp(JamesDSPLib *jdsp, double db)
{
	if (db < -12.0)
		db = -12.0;
	if (db > 12.0)
		db = 12.0;
	jdsp->tube.outcomp = (float)db;
}
void VacuumTubeProcess(JamesDSPLib *jdsp, size_t n)
{
	VTProcess(&jdsp->tube, jdsp->tmpBuffer[0], jdsp->tmpBuffer[1], jdsp->tmpBuffer[0], jdsp->tmpBuffer[1], n);
}