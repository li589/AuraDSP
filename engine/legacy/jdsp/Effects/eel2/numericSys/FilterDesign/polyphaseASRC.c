#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <limits.h>
#include <stdint.h>
#include "polyphaseASRC.h"
#include "../codelet.h"
#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif
// n/d rounding up
static unsigned int iceil(unsigned int n, unsigned int d)
{
	return n / d + ((n % d != 0) ? 1ul : 0ul);
}
// Dot product of two vectors
static float dot(float* a, unsigned int a_length, float* history, float* b, unsigned int b_last_index)
{
	float dotprod = 0.0f;
	unsigned int i = 0;
	if (a_length > b_last_index)
	{
		for (; i < (a_length - b_last_index - 1); i++)
			dotprod += a[i] * history[b_last_index + i];
	}
	for (; i < a_length; i++)
		dotprod += a[i] * b[(i + 1UL + b_last_index) - a_length];
	return dotprod;
}
static void dotStereo(float* a, unsigned int a_length, float* history1, float* history2, float* b1, float* b2, unsigned int b_last_index, float *dotprod1, float *dotprod2)
{
	*dotprod1 = 0.0f;
	*dotprod2 = 0.0f;
	unsigned int i = 0;
	if (a_length > b_last_index)
	{
		for (; i < (a_length - b_last_index - 1); i++)
		{
			*dotprod1 += a[i] * history1[b_last_index + i];
			*dotprod2 += a[i] * history2[b_last_index + i];
		}
	}
	for (; i < a_length; i++)
	{
		*dotprod1 += a[i] * b1[(i + 1UL + b_last_index) - a_length];
		*dotprod2 += a[i] * b2[(i + 1UL + b_last_index) - a_length];
	}
}
// Shift b into a
static void src_shiftin(float* a, int a_length, float* b, int b_length)
{
	if (b_length > a_length)
		memcpy(a, &b[b_length - a_length], a_length * sizeof(float));
	else
	{
		for (int i = 0; i < (a_length - b_length); i++)
			a[i] = a[i + b_length];
		for (int i = 0; i < b_length; i++)
			a[i + a_length - b_length] = b[i];
	}
}
static void src_shiftinStereo(float* a1, float* a2, int a_length, float* b1, float* b2, int b_length)
{
	if (b_length > a_length)
	{
		memcpy(a1, &b1[b_length - a_length], a_length * sizeof(float));
		memcpy(a2, &b2[b_length - a_length], a_length * sizeof(float));
	}
	else
	{
		for (int i = 0; i < (a_length - b_length); i++)
		{
			a1[i] = a1[i + b_length];
			a2[i] = a2[i + b_length];
		}
		for (int i = 0; i < b_length; i++)
		{
			a1[i + a_length - b_length] = b1[i];
			a2[i + a_length - b_length] = b2[i];
		}
	}
}
static double sincFx(double x)
{
	if (x == 0.0)
		return 1.0;
	else
		return sin(x * M_PI) / (x * M_PI);
}
#include <float.h>
extern void fhtbitReversalTbl(unsigned *dst, unsigned int n);
static void LLdiscreteHartley(double *A, const unsigned int nPoints, const double *sinTab)
{
	unsigned int i, j, n, n2, theta_inc, nptDiv2;
	double alpha, beta;
	// FHT - stage 1 and 2 (2 and 4 points)
	for (i = 0; i < nPoints; i += 4)
	{
		const double	x0 = A[i];
		const double	x1 = A[i + 1];
		const double	x2 = A[i + 2];
		const double	x3 = A[i + 3];
		const double	y0 = x0 + x1;
		const double	y1 = x0 - x1;
		const double	y2 = x2 + x3;
		const double	y3 = x2 - x3;
		A[i] = y0 + y2;
		A[i + 2] = y0 - y2;
		A[i + 1] = y1 + y3;
		A[i + 3] = y1 - y3;
	}
	// FHT - stage 3 (8 points)
	for (i = 0; i < nPoints; i += 8)
	{
		alpha = A[i];
		beta = A[i + 4];
		A[i] = alpha + beta;
		A[i + 4] = alpha - beta;
		alpha = A[i + 2];
		beta = A[i + 6];
		A[i + 2] = alpha + beta;
		A[i + 6] = alpha - beta;
		alpha = A[i + 1];
		const double beta1 = 0.70710678118654752440084436210485*(A[i + 5] + A[i + 7]);
		const double beta2 = 0.70710678118654752440084436210485*(A[i + 5] - A[i + 7]);
		A[i + 1] = alpha + beta1;
		A[i + 5] = alpha - beta1;
		alpha = A[i + 3];
		A[i + 3] = alpha + beta2;
		A[i + 7] = alpha - beta2;
	}
	n = 16;
	n2 = 8;
	theta_inc = nPoints >> 4;
	nptDiv2 = nPoints >> 2;
	while (n <= nPoints)
	{
		for (i = 0; i < nPoints; i += n)
		{
			unsigned int theta = theta_inc;
			const unsigned int n4 = n2 >> 1;
			alpha = A[i];
			beta = A[i + n2];
			A[i] = alpha + beta;
			A[i + n2] = alpha - beta;
			alpha = A[i + n4];
			beta = A[i + n2 + n4];
			A[i + n4] = alpha + beta;
			A[i + n2 + n4] = alpha - beta;
			for (j = 1; j < n4; j++)
			{
				double	sinval = sinTab[theta];
				double	cosval = sinTab[theta + nptDiv2];
				double	alpha1 = A[i + j];
				double	alpha2 = A[i - j + n2];
				double	beta1 = A[i + j + n2] * cosval + A[i - j + n] * sinval;
				double	beta2 = A[i + j + n2] * sinval - A[i - j + n] * cosval;
				theta += theta_inc;
				A[i + j] = alpha1 + beta1;
				A[i + j + n2] = alpha1 - beta1;
				A[i - j + n2] = alpha2 + beta2;
				A[i - j + n] = alpha2 - beta2;
			}
		}
		n <<= 1;
		n2 <<= 1;
		theta_inc >>= 1;
	}
}
static void fhtsinHalfTbl(double *dst, unsigned int n)
{
	const double twopi_over_n = (2.0 * M_PI) / n;
	for (unsigned int i = 0; i < n >> 1; ++i)
		dst[i] = sin(twopi_over_n * i);
}

/* [PATCHED-AuraDSP P-060] Checked construction: publish a filter only after
 * every allocation and coefficient transform succeeds. */
static int src_mul_size(size_t a, size_t b, size_t *out)
{
	if (b != 0 && a > SIZE_MAX / b)
		return 0;
	*out = a * b;
	return 1;
}

static unsigned int src_next_pow2(unsigned int value)
{
	unsigned int power = 1;
	if (value == 0)
		return 0;
	while (power < value)
	{
		if (power > 0x40000000u)
			return 0;
		power <<= 1;
	}
	return power;
}

int psrc_is_valid(const SRCResampler *filter)
{
	return filter && filter->pfb && filter->interpolation != 0 &&
		filter->decimation != 0 && filter->num_phases == filter->interpolation &&
		filter->taps_per_phase != 0 && filter->phase_index < filter->interpolation &&
		filter->phase_index_step == filter->decimation % filter->interpolation &&
		(filter->history_length == 0 || filter->history != NULL);
}

int psrc_generate(SRCResampler *filter, unsigned int interpolation,
                  unsigned int decimation, int tap, double cutoff_freq,
                  char minphase)
{
	SRCResampler out;
	unsigned int *mBitRev = NULL;
	double *mSineTab = NULL;
	double *timeData = NULL;
	double *freqData = NULL;
	float *pfb = NULL;
	float *history = NULL;
	size_t num_taps;
	size_t pfb_size;
	size_t bytes;
	unsigned int filterLength = 0;
	memset(&out, 0, sizeof(out));

	if (!filter || interpolation == 0 || decimation == 0 || tap <= 1 ||
		!isfinite(cutoff_freq) || cutoff_freq <= 0.0 || cutoff_freq > 1.0 ||
		(size_t)tap > SIZE_MAX / (size_t)interpolation)
		goto fail;
	/* [PATCHED-AuraDSP P-060] The interpolator can have the larger phase
	 * count even when the reduced numerator is below the controller cap. */
	if (minphase && interpolation > AURADSP_ASRC_MINPHASE_MAX_PHASES)
		minphase = 0;
	num_taps = (size_t)tap * (size_t)interpolation;
	if (num_taps > INT_MAX)
		goto fail;

	out.num_phases = interpolation;
	out.interpolation = interpolation;
	out.decimation = decimation;
	out.taps_per_phase = iceil((unsigned int)num_taps, interpolation);
	if ((size_t)out.taps_per_phase > SIZE_MAX / (size_t)interpolation)
		goto fail;
	pfb_size = (size_t)out.taps_per_phase * (size_t)interpolation;
	if (pfb_size > INT_MAX || !src_mul_size(pfb_size, sizeof(float), &bytes))
		goto fail;

	if (minphase)
	{
		unsigned int hLen;
		const unsigned int m = (unsigned int)num_taps - 1;
		double ratio = (double)(tap / 2) / (double)num_taps;
		double g = 1.0;
		double gain, re, im, eR;
		const double threshdB = -200.0;
		const double clipThresh = pow(10.0, threshdB / 20.0);
		const double logThreshold = log(clipThresh);
		int i, symIdx;
		ratio = cutoff_freq * ratio;
		if (interpolation < decimation)
		{
			g = (double)interpolation / (double)decimation;
			ratio *= g;
		}
		if (num_taps > UINT_MAX / 100u)
			goto fail;
		filterLength = src_next_pow2((unsigned int)(num_taps * 100u));
		hLen = (unsigned int)pfb_size;
		if (filterLength == 0 || filterLength > INT_MAX || hLen > filterLength ||
			filterLength > SIZE_MAX / sizeof(unsigned int) ||
			filterLength > SIZE_MAX / sizeof(double))
			goto fail;
		mBitRev = (unsigned int *)malloc(filterLength * sizeof(unsigned int));
		mSineTab = (double *)malloc((filterLength >> 1) * sizeof(double));
		timeData = (double *)malloc(filterLength * sizeof(double));
		freqData = (double *)malloc(filterLength * sizeof(double));
		if (!mBitRev || !mSineTab || !timeData || !freqData)
			goto fail;
		fhtbitReversalTbl(mBitRev, filterLength);
		fhtsinHalfTbl(mSineTab, filterLength);
		for (i = 0; i < (int)hLen; i++)
			timeData[mBitRev[i]] = cutoff_freq * g *
				((sincFx(2.0 * ratio * (i - m / 2.0))) *
				(0.5 - 0.5 * cos(2.0 * M_PI * (double)i / (double)(num_taps - 1))));
		for (i = (int)hLen; i < (int)filterLength; i++)
			timeData[mBitRev[i]] = 0.0;
		LLdiscreteHartley(timeData, filterLength, mSineTab);
		if (fabs(timeData[0]) < clipThresh)
			freqData[0] = logThreshold;
		else
			freqData[0] = log(fabs(timeData[0]));
		for (int j = 1; j < (int)filterLength; j++)
		{
			symIdx = (int)filterLength - j;
			const double lR = timeData[j] + timeData[symIdx];
			const double lI = timeData[j] - timeData[symIdx];
			const double mag = hypot(lR, lI) * 0.5;
			const double logV = mag < clipThresh ? logThreshold : log(mag);
			freqData[mBitRev[j]] = logV;
			freqData[mBitRev[symIdx]] = logV;
		}
		LLdiscreteHartley(freqData, filterLength, mSineTab);
		gain = 1.0 / (double)filterLength;
		timeData[0] = freqData[0] * gain;
		const unsigned int halfLen = filterLength >> 1;
		timeData[mBitRev[halfLen]] = freqData[halfLen] * gain;
		for (i = 1; i < (int)halfLen; i++)
		{
			timeData[mBitRev[i]] = (freqData[i] + freqData[filterLength - i]) * gain;
			timeData[mBitRev[filterLength - i]] = 0.0;
		}
		LLdiscreteHartley(timeData, filterLength, mSineTab);
		freqData[0] = exp(timeData[0]);
		for (i = 1; i < (int)filterLength; i++)
		{
			re = (timeData[i] + timeData[filterLength - i]) * 0.5;
			im = (timeData[i] - timeData[filterLength - i]) * 0.5;
			eR = exp(re);
			re = eR * cos(im);
			im = eR * sin(im);
			freqData[mBitRev[i]] = re + im;
			freqData[mBitRev[filterLength - i]] = re - im;
		}
		LLdiscreteHartley(freqData, filterLength, mSineTab);
	}

	pfb = (float *)malloc(bytes);
	if (!pfb)
		goto fail;
	if (minphase)
	{
		const double gain = 1.0 / (double)filterLength;
		for (unsigned int phase = 0; phase < interpolation; phase++)
			for (unsigned int tapIndex = 0; tapIndex < out.taps_per_phase; tapIndex++)
				pfb[phase * out.taps_per_phase + out.taps_per_phase - 1 - tapIndex] =
					(float)(freqData[tapIndex * interpolation + phase] * gain);
	}
	else
	{
		const unsigned int m = (unsigned int)num_taps - 1;
		double ratio = (double)(tap / 2) / (double)num_taps;
		double g = 1.0;
		ratio = cutoff_freq * ratio;
		if (interpolation < decimation)
		{
			g = (double)interpolation / (double)decimation;
			ratio *= g;
		}
		for (unsigned int phase = 0; phase < interpolation; phase++)
			for (unsigned int tapIndex = 0; tapIndex < out.taps_per_phase; tapIndex++)
			{
				const unsigned int idx = tapIndex * interpolation + phase;
				pfb[phase * out.taps_per_phase + out.taps_per_phase - 1 - tapIndex] =
					(float)(cutoff_freq * g *
					((sincFx(2.0 * ratio * (idx - m / 2.0))) *
					(0.5 - 0.5 * cos(2.0 * M_PI * (double)idx / (double)(num_taps - 1)))));
			}
	}
	out.pfb = pfb;
	out.history_length = out.taps_per_phase - 1;
	out.phase_index = 0;
	out.input_deficit = 0;
	out.phase_index_step = decimation % interpolation;
	if (out.history_length != 0)
	{
		if (!src_mul_size(out.history_length, sizeof(float), &bytes))
			goto fail;
		history = (float *)malloc(bytes);
		if (!history)
			goto fail;
		memset(history, 0, bytes);
	}
	out.history = history;
	*filter = out;
	free(mBitRev);
	free(mSineTab);
	free(timeData);
	free(freqData);
	return 1;

fail:
	free(mBitRev);
	free(mSineTab);
	free(timeData);
	free(freqData);
	free(pfb);
	free(history);
	if (filter)
		memset(filter, 0, sizeof(*filter));
	return 0;
}

int psrc_clone(SRCResampler *filterDest, SRCResampler *filterSrc)
{
	SRCResampler out;
	float *pfb = NULL;
	float *history = NULL;
	size_t pfb_count;
	size_t bytes;
	memset(&out, 0, sizeof(out));
	if (!filterDest || !filterSrc || filterDest == filterSrc ||
		!psrc_is_valid(filterSrc) ||
		(size_t)filterSrc->taps_per_phase > SIZE_MAX / (size_t)filterSrc->interpolation)
		goto fail;
	pfb_count = (size_t)filterSrc->taps_per_phase * (size_t)filterSrc->interpolation;
	if (!src_mul_size(pfb_count, sizeof(float), &bytes))
		goto fail;
	pfb = (float *)malloc(bytes);
	if (!pfb)
		goto fail;
	memcpy(pfb, filterSrc->pfb, bytes);
	if (filterSrc->history_length != 0)
	{
		if (!src_mul_size(filterSrc->history_length, sizeof(float), &bytes))
			goto fail;
		history = (float *)malloc(bytes);
		if (!history)
			goto fail;
		memcpy(history, filterSrc->history, bytes);
	}
	out = *filterSrc;
	out.pfb = pfb;
	out.history = history;
	*filterDest = out;
	return 1;

fail:
	free(pfb);
	free(history);
	if (filterDest)
		memset(filterDest, 0, sizeof(*filterDest));
	return 0;
}

unsigned int psrc_filt(SRCResampler *filter, float *x, unsigned int count, float *y)
{
	unsigned int phase;
	unsigned int i;
	unsigned int output_length = 0;
	if (!psrc_is_valid(filter) || !x || !y || count > INT_MAX)
		return 0;
	phase = filter->phase_index;
	i = filter->input_deficit;
	while (i < count)
	{
		y[output_length++] = dot(&filter->pfb[phase * filter->taps_per_phase],
			filter->taps_per_phase, filter->history, x, i);
		i += (phase + filter->decimation) / filter->interpolation;
		phase = (phase + filter->phase_index_step) % filter->interpolation;
	}
	filter->input_deficit = i - count;
	filter->phase_index = phase;
	if (filter->history_length != 0)
		src_shiftin(filter->history, filter->history_length, x, count);
	return output_length;
}

unsigned int psrc_filt_stereo(SRCResampler *filter[2], float *x1, float *x2,
                              unsigned int count, float *y1, float *y2)
{
	unsigned int phase;
	unsigned int i;
	unsigned int output_length = 0;
	if (!filter || !filter[0] || !filter[1] || !x1 || !x2 || !y1 || !y2 ||
		!psrc_is_valid(filter[0]) || !psrc_is_valid(filter[1]) || count > INT_MAX ||
		filter[0]->interpolation != filter[1]->interpolation ||
		filter[0]->decimation != filter[1]->decimation ||
		filter[0]->taps_per_phase != filter[1]->taps_per_phase ||
		filter[0]->history_length != filter[1]->history_length ||
		filter[0]->phase_index != filter[1]->phase_index ||
		filter[0]->input_deficit != filter[1]->input_deficit)
		return 0;
	phase = filter[0]->phase_index;
	i = filter[0]->input_deficit;
	while (i < count)
	{
		dotStereo(&filter[0]->pfb[phase * filter[0]->taps_per_phase],
			filter[0]->taps_per_phase, filter[0]->history, filter[1]->history,
			x1, x2, i, &y1[output_length], &y2[output_length]);
		output_length++;
		i += (phase + filter[0]->decimation) / filter[0]->interpolation;
		phase = (phase + filter[0]->phase_index_step) % filter[0]->interpolation;
	}
	filter[0]->input_deficit = i - count;
	filter[0]->phase_index = phase;
	filter[1]->input_deficit = i - count;
	filter[1]->phase_index = phase;
	if (filter[0]->history_length != 0)
		src_shiftinStereo(filter[0]->history, filter[1]->history,
			filter[0]->history_length, x1, x2, count);
	return output_length;
}

void psrc_free(SRCResampler *filter)
{
	if (!filter)
		return;
	free(filter->pfb);
	free(filter->history);
	memset(filter, 0, sizeof(*filter));
}
