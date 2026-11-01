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
		/* [PATCHED-AuraDSP P-049] 抗混叠低通改用固定绝对截止 21 kHz，而不是按 Nyquist
		 * 取比例。按比例（0.95）时截止随工作率漂移：44.1k 为 20.95k、
		 * 48k 为 22.8k，20 kHz 处分别为 -0.94 / -0.02 dB（差 0.92 dB），
		 * 与「同一预设跨采样率一致」的目标冲突。固定 21 kHz 后两率在
		 * 20 kHz 为 -0.83 / -0.96 dB（差 0.13 dB）；首个镜像 24.1k /
		 * 28k 分别仍有 -62 / -129 dB 抑制。
		 * 低采样率分支（<44.1k）不在引擎工作域，但仍钳到 0.95 以免
		 * 截止越过输入 Nyquist。只改 2x 分支：工作域只可能是 44.1/48k。 */
		double cutoffRatio = 21000.0 / (fs * 0.5);
		if (cutoffRatio > 0.95) cutoffRatio = 0.95;
		oversample_makeSmpCutoff(&tb->smp[0], 2, cutoffRatio);
		oversample_makeSmpCutoff(&tb->smp[1], 2, cutoffRatio);
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
	/* [PATCHED-AuraDSP P-011 2026-10-13] Tape 阻尼状态每次 Enable 清零；
	 * character/drywet/outcomp 故意不碰（开关不丢用户值，由引擎 apply_tube 推送）。 */
	tb->tapeLp[0] = 0.0f;
	tb->tapeLp[1] = 0.0f;
	memset(tb->dryDelay, 0, sizeof(tb->dryDelay));
	tb->dryPos[0] = 0;
	tb->dryPos[1] = 0;
	init6BandsCrossover(&tb->subband[0], fs, 300.0, 950.0, 2200.0, 4000.0, 6000.0);
	init6BandsCrossover(&tb->subband[1], fs, 300.0, 950.0, 2200.0, 4000.0, 6000.0);
}
void VTProcess(VacuumTube *tb, float *x1, float *x2, float *out1, float *out2, size_t n)
{
	float upsample[2][5];
	double bandCh1[6], bandCh2[6];
	/* [PATCHED-AuraDSP P-011 2026-10-13] 音色调度（纯查表+乘加，RT 安全）：
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
		/* [PATCHED-AuraDSP P-011 2026-10-13] wet 整形：trim→Tape阻尼→补偿→干湿混合（dry 取原始输入）。 */
		float w1 = oversample_stepdownSmpFloat(&tb->smp[0], upsample[0]) * tb->postgain * trim;
		float w2 = oversample_stepdownSmpFloat(&tb->smp[1], upsample[1]) * tb->postgain * trim;
		/* [A-12] 干声与过采样湿声主峰（约 10 样本）对齐，避免 drywet<1 梳状。 */
		float dry1 = x1[i], dry2 = x2[i];
		if (wetK > 0.0f && wetK < 1.0f)
		{
			const int kDryDelay = 10;
			int p0 = tb->dryPos[0] & 31;
			int p1 = tb->dryPos[1] & 31;
			dry1 = tb->dryDelay[0][(p0 + 32 - kDryDelay) & 31];
			dry2 = tb->dryDelay[1][(p1 + 32 - kDryDelay) & 31];
			tb->dryDelay[0][p0] = x1[i];
			tb->dryDelay[1][p1] = x2[i];
			tb->dryPos[0] = (p0 + 1) & 31;
			tb->dryPos[1] = (p1 + 1) & 31;
		}
		if (lpCoef > 0.0f)
		{
			tb->tapeLp[0] += lpCoef * (w1 - tb->tapeLp[0]);
			tb->tapeLp[1] += lpCoef * (w2 - tb->tapeLp[1]);
			w1 = tb->tapeLp[0];
			w2 = tb->tapeLp[1];
		}
		w1 *= compLin;
		w2 *= compLin;
		out1[i] = dry1 * dryK + w1 * wetK;
		out2[i] = dry2 * dryK + w2 * wetK;
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
		/* [PATCHED-AuraDSP P-011 2026-10-13] wet 整形（与过采样分支同构）：trim→Tape阻尼→补偿→干湿混合。 */
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
/* [PATCHED-AuraDSP P-011 2026-10-13] 电子管音色/混合/补偿 setter。
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