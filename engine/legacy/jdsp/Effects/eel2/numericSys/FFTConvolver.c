#include "FFTConvolver.h"
#include <stdlib.h>
#include <string.h>
#include <float.h>
#include <math.h>
#include <stdint.h>
#include "../ns-eel.h"
#include "codelet.h"
unsigned int upper_power_of_two(unsigned int v)
{
	v--;
	v |= v >> 1;
	v |= v >> 2;
	v |= v >> 4;
	v |= v >> 8;
	v |= v >> 16;
	return ++v;
}

/* [PATCHED-AuraDSP P-061] Validation happens before an existing convolver is
 * freed, so malformed input cannot destroy a working IR. */
#define FFT_CONVOLVER_MAX_BLOCK_SIZE 524288u

static int fft_size_mul(size_t a, size_t b, size_t *out)
{
	if (b != 0 && a > SIZE_MAX / b)
		return 0;
	*out = a * b;
	return 1;
}

static int fft_ir_valid(const float *ir, unsigned int irLen)
{
	if (!ir || irLen == 0)
		return 0;
	for (unsigned int i = 0; i < irLen; ++i)
		if (!isfinite(ir[i]))
			return 0;
	return 1;
}

static int fft_geometry_valid(unsigned int blockSize, unsigned int irLen,
                              unsigned int *roundedBlock,
                              unsigned int *segCount,
                              unsigned int *complexSize)
{
	unsigned int block, count, segSize, fftComplex;
	size_t bytes;
	if (!roundedBlock || !segCount || !complexSize || blockSize == 0 ||
		blockSize > FFT_CONVOLVER_MAX_BLOCK_SIZE || irLen == 0)
		return 0;
	block = upper_power_of_two(blockSize);
	segSize = 2u * block;
	count = irLen / block + ((irLen % block) != 0);
	fftComplex = (segSize >> 1) + 1;
	if (count == 0 || !fft_size_mul(count, sizeof(float *), &bytes) ||
		!fft_size_mul(fftComplex, sizeof(float), &bytes) ||
		!fft_size_mul(segSize, sizeof(float), &bytes))
		return 0;
	*roundedBlock = block;
	*segCount = count;
	*complexSize = fftComplex;
	return 1;
}

static int fft_geometry_matches(unsigned int blockSize, unsigned int irLen,
                                unsigned int roundedBlock,
                                unsigned int storedIrLength)
{
	return irLen == storedIrLength && blockSize != 0 &&
		blockSize <= FFT_CONVOLVER_MAX_BLOCK_SIZE &&
		upper_power_of_two(blockSize) == roundedBlock;
}

static void fft_zero_output(float *output, unsigned int len)
{
	if (output && (size_t)len <= SIZE_MAX / sizeof(float))
		memset(output, 0, (size_t)len * sizeof(float));
}

static void fft_free_table(float ***table, unsigned int count)
{
	if (!table || !*table)
		return;
	for (unsigned int i = 0; i < count; ++i)
		free((*table)[i]);
	free(*table);
	*table = NULL;
}

static void fft_free_ptr(float **ptr)
{
	if (!ptr)
		return;
	free(*ptr);
	*ptr = NULL;
}

static int fft_alloc_table(float ***table, unsigned int count)
{
	if (!table)
		return 0;
	*table = (float **)calloc(count, sizeof(float *));
	return *table != NULL;
}

static int fft_alloc_buffer(float **buffer, unsigned int count)
{
	if (!buffer)
		return 0;
	*buffer = (float *)calloc(count, sizeof(float));
	return *buffer != NULL;
}

static int fft_1x1_ready(const FFTConvolver1x1 *conv)
{
	return conv && conv->_initialized && conv->fft && conv->_blockSize != 0 &&
		conv->_segCount != 0 && conv->_current < conv->_segCount &&
		conv->_inputBufferFill < conv->_blockSize && conv->_inputBuffer &&
		conv->_fftBuffer && conv->_overlap && conv->_segmentsRe &&
		conv->_segmentsIm && conv->_segmentsIRRe && conv->_segmentsIRIm &&
		conv->_preMultiplied[0] && conv->_preMultiplied[1] && conv->bit && conv->sine;
}

static int fft_2x2_ready(const FFTConvolver2x2 *conv)
{
	return conv && conv->_initialized && conv->fft && conv->_blockSize != 0 &&
		conv->_segCount != 0 && conv->_current < conv->_segCount &&
		conv->_inputBufferFill < conv->_blockSize && conv->_inputBuffer[0] &&
		conv->_inputBuffer[1] && conv->_fftBuffer[0] && conv->_fftBuffer[1] &&
		conv->_overlap[0] && conv->_overlap[1] && conv->_segmentsReLeft &&
		conv->_segmentsImLeft && conv->_segmentsReRight && conv->_segmentsImRight &&
		conv->_segmentsLLIRRe && conv->_segmentsLLIRIm &&
		conv->_segmentsRRIRRe && conv->_segmentsRRIRIm &&
		conv->_preMultiplied[0][0] && conv->_preMultiplied[0][1] &&
		conv->_preMultiplied[1][0] && conv->_preMultiplied[1][1] &&
		conv->bit && conv->sine;
}

static int fft_1x2_ready(const FFTConvolver1x2 *conv)
{
	return conv && conv->_initialized && conv->fft && conv->_blockSize != 0 &&
		conv->_segCount != 0 && conv->_current < conv->_segCount &&
		conv->_inputBufferFill < conv->_blockSize && conv->_inputBuffer &&
		conv->_fftBuffer[0] && conv->_fftBuffer[1] && conv->_overlap[0] &&
		conv->_overlap[1] && conv->_segmentsRe && conv->_segmentsIm &&
		conv->_segmentsLLIRRe && conv->_segmentsLLIRIm &&
		conv->_segmentsRRIRRe && conv->_segmentsRRIRIm &&
		conv->_preMultiplied[0][0] && conv->_preMultiplied[0][1] &&
		conv->_preMultiplied[1][0] && conv->_preMultiplied[1][1] &&
		conv->bit && conv->sine;
}

static int fft_2x4x2_ready(const FFTConvolver2x4x2 *conv)
{
	return conv && conv->_initialized && conv->fft && conv->_blockSize != 0 &&
		conv->_segCount != 0 && conv->_current < conv->_segCount &&
		conv->_inputBufferFill < conv->_blockSize && conv->_inputBuffer[0] &&
		conv->_inputBuffer[1] && conv->_fftBuffer[0] && conv->_fftBuffer[1] &&
		conv->_overlap[0] && conv->_overlap[1] && conv->_segmentsReLeft &&
		conv->_segmentsImLeft && conv->_segmentsReRight && conv->_segmentsImRight &&
		conv->_segmentsLLIRRe && conv->_segmentsLLIRIm &&
		conv->_segmentsLRIRRe && conv->_segmentsLRIRIm &&
		conv->_segmentsRLIRRe && conv->_segmentsRLIRIm &&
		conv->_segmentsRRIRRe && conv->_segmentsRRIRIm &&
		conv->_preMultiplied[0][0] && conv->_preMultiplied[0][1] &&
		conv->_preMultiplied[1][0] && conv->_preMultiplied[1][1] &&
		conv->bit && conv->sine;
}
void FFTConvolver1x1Init(FFTConvolver1x1 *conv)
{
	if (conv)
		memset(conv, 0, sizeof(*conv));
}
void FFTConvolver2x4x2Init(FFTConvolver2x4x2 *conv)
{
	if (conv)
		memset(conv, 0, sizeof(*conv));
}
void FFTConvolver2x2Init(FFTConvolver2x2 *conv)
{
	if (conv)
		memset(conv, 0, sizeof(*conv));
}
void FFTConvolver1x2Init(FFTConvolver1x2 *conv)
{
	if (conv)
		memset(conv, 0, sizeof(*conv));
}
void FFTConvolver1x1Free(FFTConvolver1x1 *conv)
{
	if (!conv)
		return;
	conv->_initialized = 0;
	fft_free_table(&conv->_segmentsRe, conv->_segCount);
	fft_free_table(&conv->_segmentsIm, conv->_segCount);
	fft_free_table(&conv->_segmentsIRRe, conv->_segCount);
	fft_free_table(&conv->_segmentsIRIm, conv->_segCount);
	fft_free_ptr(&conv->_preMultiplied[0]);
	fft_free_ptr(&conv->_preMultiplied[1]);
	fft_free_ptr(&conv->_fftBuffer);
	fft_free_ptr(&conv->_overlap);
	fft_free_ptr(&conv->_inputBuffer);
	free(conv->bit);
	free(conv->sine);
	memset(conv, 0, sizeof(*conv));
}
void FFTConvolver2x4x2Free(FFTConvolver2x4x2 *conv)
{
	if (!conv)
		return;
	conv->_initialized = 0;
	fft_free_table(&conv->_segmentsReLeft, conv->_segCount);
	fft_free_table(&conv->_segmentsImLeft, conv->_segCount);
	fft_free_table(&conv->_segmentsReRight, conv->_segCount);
	fft_free_table(&conv->_segmentsImRight, conv->_segCount);
	fft_free_table(&conv->_segmentsLLIRRe, conv->_segCount);
	fft_free_table(&conv->_segmentsLLIRIm, conv->_segCount);
	fft_free_table(&conv->_segmentsLRIRRe, conv->_segCount);
	fft_free_table(&conv->_segmentsLRIRIm, conv->_segCount);
	fft_free_table(&conv->_segmentsRLIRRe, conv->_segCount);
	fft_free_table(&conv->_segmentsRLIRIm, conv->_segCount);
	fft_free_table(&conv->_segmentsRRIRRe, conv->_segCount);
	fft_free_table(&conv->_segmentsRRIRIm, conv->_segCount);
	fft_free_ptr(&conv->_preMultiplied[0][0]);
	fft_free_ptr(&conv->_preMultiplied[0][1]);
	fft_free_ptr(&conv->_preMultiplied[1][0]);
	fft_free_ptr(&conv->_preMultiplied[1][1]);
	fft_free_ptr(&conv->_fftBuffer[0]);
	fft_free_ptr(&conv->_fftBuffer[1]);
	fft_free_ptr(&conv->_overlap[0]);
	fft_free_ptr(&conv->_overlap[1]);
	fft_free_ptr(&conv->_inputBuffer[0]);
	fft_free_ptr(&conv->_inputBuffer[1]);
	free(conv->bit);
	free(conv->sine);
	memset(conv, 0, sizeof(*conv));
}
void FFTConvolver2x2Free(FFTConvolver2x2 *conv)
{
	if (!conv)
		return;
	conv->_initialized = 0;
	fft_free_table(&conv->_segmentsReLeft, conv->_segCount);
	fft_free_table(&conv->_segmentsImLeft, conv->_segCount);
	fft_free_table(&conv->_segmentsReRight, conv->_segCount);
	fft_free_table(&conv->_segmentsImRight, conv->_segCount);
	fft_free_table(&conv->_segmentsLLIRRe, conv->_segCount);
	fft_free_table(&conv->_segmentsLLIRIm, conv->_segCount);
	fft_free_table(&conv->_segmentsRRIRRe, conv->_segCount);
	fft_free_table(&conv->_segmentsRRIRIm, conv->_segCount);
	fft_free_ptr(&conv->_preMultiplied[0][0]);
	fft_free_ptr(&conv->_preMultiplied[0][1]);
	fft_free_ptr(&conv->_preMultiplied[1][0]);
	fft_free_ptr(&conv->_preMultiplied[1][1]);
	fft_free_ptr(&conv->_fftBuffer[0]);
	fft_free_ptr(&conv->_fftBuffer[1]);
	fft_free_ptr(&conv->_overlap[0]);
	fft_free_ptr(&conv->_overlap[1]);
	fft_free_ptr(&conv->_inputBuffer[0]);
	fft_free_ptr(&conv->_inputBuffer[1]);
	free(conv->bit);
	free(conv->sine);
	memset(conv, 0, sizeof(*conv));
}
void FFTConvolver1x2Free(FFTConvolver1x2 *conv)
{
	if (!conv)
		return;
	conv->_initialized = 0;
	fft_free_table(&conv->_segmentsRe, conv->_segCount);
	fft_free_table(&conv->_segmentsIm, conv->_segCount);
	fft_free_table(&conv->_segmentsLLIRRe, conv->_segCount);
	fft_free_table(&conv->_segmentsLLIRIm, conv->_segCount);
	fft_free_table(&conv->_segmentsRRIRRe, conv->_segCount);
	fft_free_table(&conv->_segmentsRRIRIm, conv->_segCount);
	fft_free_ptr(&conv->_preMultiplied[0][0]);
	fft_free_ptr(&conv->_preMultiplied[0][1]);
	fft_free_ptr(&conv->_preMultiplied[1][0]);
	fft_free_ptr(&conv->_preMultiplied[1][1]);
	fft_free_ptr(&conv->_fftBuffer[0]);
	fft_free_ptr(&conv->_fftBuffer[1]);
	fft_free_ptr(&conv->_overlap[0]);
	fft_free_ptr(&conv->_overlap[1]);
	fft_free_ptr(&conv->_inputBuffer);
	free(conv->bit);
	free(conv->sine);
	memset(conv, 0, sizeof(*conv));
}
extern void fhtbitReversalTbl(unsigned *dst, unsigned int n);
extern void fhtsinHalfTblFloat(float *dst, unsigned int n);

/* Shared unchanged IR transform used by every Load/Refresh variant. */
static void fft_fill_ir_segment(const float *ir, unsigned int irLen,
                                unsigned int segmentIndex,
                                unsigned int blockSize, unsigned int segSize,
                                unsigned int complexSize, const unsigned int *bit,
                                float *fftBuffer, float *sine,
                                void (*fft)(float *, const float *),
                                float *segmentRe, float *segmentIm)
{
	const unsigned int remaining = irLen - segmentIndex * blockSize;
	const unsigned int sizeCopy = remaining >= blockSize ? blockSize : remaining;
	for (unsigned int j = 0; j < sizeCopy; ++j)
		fftBuffer[bit[j]] = ir[segmentIndex * blockSize + j];
	for (unsigned int j = sizeCopy; j < segSize; ++j)
		fftBuffer[bit[j]] = 0.0f;
	fft(fftBuffer, sine);
	segmentRe[0] = fftBuffer[0] * 2.0f;
	segmentIm[0] = 0.0f;
	for (unsigned int j = 1; j < complexSize; ++j)
	{
		const unsigned int symIdx = segSize - j;
		segmentRe[j] = fftBuffer[j] + fftBuffer[symIdx];
		segmentIm[j] = fftBuffer[j] - fftBuffer[symIdx];
	}
}
int FFTConvolver1x1LoadImpulseResponse(FFTConvolver1x1 *conv, unsigned int blockSize, const float* ir, unsigned int irLen)
{
	unsigned int roundedBlock, segCount, complexSize;
	if (!conv || !fft_ir_valid(ir, irLen) ||
		!fft_geometry_valid(blockSize, irLen, &roundedBlock, &segCount, &complexSize))
		return 0;
	FFTConvolver1x1Free(conv);
	conv->_blockSize = roundedBlock;
	conv->_segSize = 2u * roundedBlock;
	conv->_segCount = segCount;
	conv->_segCountMinus1 = segCount - 1;
	conv->_fftComplexSize = complexSize;

	if (conv->_segSize == 2) conv->fft = DFT2;
	else if (conv->_segSize == 4) conv->fft = DFT4;
	else if (conv->_segSize == 8) conv->fft = DFT8;
	else if (conv->_segSize == 16) conv->fft = DFT16;
	else if (conv->_segSize == 32) conv->fft = DFT32;
	else if (conv->_segSize == 64) conv->fft = DFT64;
	else if (conv->_segSize == 128) conv->fft = DFT128;
	else if (conv->_segSize == 256) conv->fft = DFT256;
	else if (conv->_segSize == 512) conv->fft = DFT512;
	else if (conv->_segSize == 1024) conv->fft = DFT1024;
	else if (conv->_segSize == 2048) conv->fft = DFT2048;
	else if (conv->_segSize == 4096) conv->fft = DFT4096;
	else if (conv->_segSize == 8192) conv->fft = DFT8192;
	else if (conv->_segSize == 16384) conv->fft = DFT16384;
	else if (conv->_segSize == 32768) conv->fft = DFT32768;
	else if (conv->_segSize == 65536) conv->fft = DFT65536;
	else if (conv->_segSize == 131072) conv->fft = DFT131072;
	else if (conv->_segSize == 262144) conv->fft = DFT262144;
	else if (conv->_segSize == 524288) conv->fft = DFT524288;
	else if (conv->_segSize == 1048576) conv->fft = DFT1048576;
	else goto fail;

	conv->bit = (unsigned int *)calloc(conv->_segSize, sizeof(unsigned int));
	conv->sine = (float *)calloc(conv->_segSize, sizeof(float));
	conv->_fftBuffer = (float *)calloc(conv->_segSize, sizeof(float));
	if (!conv->bit || !conv->sine || !conv->_fftBuffer)
		goto fail;
	fhtbitReversalTbl(conv->bit, conv->_segSize);
	fhtsinHalfTblFloat(conv->sine, conv->_segSize);

	conv->_segmentsRe = (float **)calloc(conv->_segCount, sizeof(float *));
	conv->_segmentsIm = (float **)calloc(conv->_segCount, sizeof(float *));
	if (!conv->_segmentsRe || !conv->_segmentsIm)
		goto fail;
	for (unsigned int i = 0; i < conv->_segCount; ++i)
	{
		conv->_segmentsRe[i] = (float *)calloc(conv->_fftComplexSize, sizeof(float));
		conv->_segmentsIm[i] = (float *)calloc(conv->_fftComplexSize, sizeof(float));
		if (!conv->_segmentsRe[i] || !conv->_segmentsIm[i])
			goto fail;
	}

	conv->_segmentsIRRe = (float **)calloc(conv->_segCount, sizeof(float *));
	conv->_segmentsIRIm = (float **)calloc(conv->_segCount, sizeof(float *));
	if (!conv->_segmentsIRRe || !conv->_segmentsIRIm)
		goto fail;
	for (unsigned int i = 0; i < conv->_segCount; ++i)
	{
		conv->_segmentsIRRe[i] = (float *)calloc(conv->_fftComplexSize, sizeof(float));
		conv->_segmentsIRIm[i] = (float *)calloc(conv->_fftComplexSize, sizeof(float));
		if (!conv->_segmentsIRRe[i] || !conv->_segmentsIRIm[i])
			goto fail;
		const unsigned int remaining = irLen - (i * conv->_blockSize);
		const unsigned int sizeCopy = remaining >= conv->_blockSize ? conv->_blockSize : remaining;
		for (unsigned int j = 0; j < sizeCopy; ++j)
			conv->_fftBuffer[conv->bit[j]] = ir[i * conv->_blockSize + j];
		for (unsigned int j = sizeCopy; j < conv->_segSize; ++j)
			conv->_fftBuffer[conv->bit[j]] = 0.0f;
		conv->fft(conv->_fftBuffer, conv->sine);
		conv->_segmentsIRRe[i][0] = conv->_fftBuffer[0] * 2.0f;
		conv->_segmentsIRIm[i][0] = 0.0f;
		for (unsigned int j = 1; j < conv->_fftComplexSize; ++j)
		{
			const unsigned int symIdx = conv->_segSize - j;
			conv->_segmentsIRRe[i][j] = conv->_fftBuffer[j] + conv->_fftBuffer[symIdx];
			conv->_segmentsIRIm[i][j] = conv->_fftBuffer[j] - conv->_fftBuffer[symIdx];
		}
	}

	conv->_preMultiplied[0] = (float *)calloc(conv->_fftComplexSize, sizeof(float));
	conv->_preMultiplied[1] = (float *)calloc(conv->_fftComplexSize, sizeof(float));
	conv->_overlap = (float *)calloc(conv->_blockSize, sizeof(float));
	conv->_inputBuffer = (float *)calloc(conv->_blockSize, sizeof(float));
	if (!conv->_preMultiplied[0] || !conv->_preMultiplied[1] ||
		!conv->_overlap || !conv->_inputBuffer)
		goto fail;
	conv->_inputBufferFill = 0;
	conv->_current = 0;
	conv->gain = 1.0f / ((float)conv->_segSize * 2.0f);
	conv->_irLength = irLen;
	conv->_initialized = 1;
	return 1;

fail:
	FFTConvolver1x1Free(conv);
	return 0;
}
int FFTConvolver1x1RefreshImpulseResponse(FFTConvolver1x1 *conv, unsigned int blockSize, const float* ir, unsigned int irLen)
{
	unsigned int roundedBlock, segCount, complexSize;
	if (!conv || !fft_ir_valid(ir, irLen) ||
		!fft_geometry_valid(blockSize, irLen, &roundedBlock, &segCount, &complexSize) ||
		!fft_1x1_ready(conv) ||
		!fft_geometry_matches(blockSize, irLen, conv->_blockSize, conv->_irLength))
		return 0;
	// Prepare IR
	for (unsigned int i = 0; i < conv->_segCount; ++i)
	{
		float* segmentRe = conv->_segmentsIRRe[i];
		float* segmentIm = conv->_segmentsIRIm[i];
		const unsigned int remaining = irLen - (i * conv->_blockSize);
		const unsigned int sizeCopy = (remaining >= conv->_blockSize) ? conv->_blockSize : remaining;
		for (unsigned int j = 0; j < sizeCopy; j++)
			conv->_fftBuffer[conv->bit[j]] = ir[i*conv->_blockSize + j];
		for (unsigned int j = sizeCopy; j < conv->_segSize; j++)
			conv->_fftBuffer[conv->bit[j]] = 0.0f;
		conv->fft(conv->_fftBuffer, conv->sine);
		segmentRe[0] = conv->_fftBuffer[0] * 2.0f;
		segmentIm[0] = 0.0f;
		for (unsigned int j = 1; j < conv->_fftComplexSize; j++)
		{
			unsigned int symIdx = conv->_segSize - j;
			segmentRe[j] = conv->_fftBuffer[j] + conv->_fftBuffer[symIdx];
			segmentIm[j] = conv->_fftBuffer[j] - conv->_fftBuffer[symIdx];
		}
	}
	return 1;
}
int FFTConvolver2x4x2LoadImpulseResponse(FFTConvolver2x4x2 *conv, unsigned int blockSize, const float* irLL, const float* irLR, const float* irRL, const float* irRR, unsigned int irLen)
{
	unsigned int roundedBlock, segCount, complexSize;
	if (!conv || !fft_ir_valid(irLL, irLen) || !fft_ir_valid(irLR, irLen) ||
		!fft_ir_valid(irRL, irLen) || !fft_ir_valid(irRR, irLen) ||
		!fft_geometry_valid(blockSize, irLen, &roundedBlock, &segCount, &complexSize))
		return 0;
	FFTConvolver2x4x2Free(conv);
	conv->_blockSize = roundedBlock;
	conv->_segSize = 2u * roundedBlock;
	conv->_segCount = segCount;
	conv->_segCountMinus1 = segCount - 1;
	conv->_fftComplexSize = complexSize;

	if (conv->_segSize == 2) conv->fft = DFT2;
	else if (conv->_segSize == 4) conv->fft = DFT4;
	else if (conv->_segSize == 8) conv->fft = DFT8;
	else if (conv->_segSize == 16) conv->fft = DFT16;
	else if (conv->_segSize == 32) conv->fft = DFT32;
	else if (conv->_segSize == 64) conv->fft = DFT64;
	else if (conv->_segSize == 128) conv->fft = DFT128;
	else if (conv->_segSize == 256) conv->fft = DFT256;
	else if (conv->_segSize == 512) conv->fft = DFT512;
	else if (conv->_segSize == 1024) conv->fft = DFT1024;
	else if (conv->_segSize == 2048) conv->fft = DFT2048;
	else if (conv->_segSize == 4096) conv->fft = DFT4096;
	else if (conv->_segSize == 8192) conv->fft = DFT8192;
	else if (conv->_segSize == 16384) conv->fft = DFT16384;
	else if (conv->_segSize == 32768) conv->fft = DFT32768;
	else if (conv->_segSize == 65536) conv->fft = DFT65536;
	else if (conv->_segSize == 131072) conv->fft = DFT131072;
	else if (conv->_segSize == 262144) conv->fft = DFT262144;
	else if (conv->_segSize == 524288) conv->fft = DFT524288;
	else if (conv->_segSize == 1048576) conv->fft = DFT1048576;
	else goto fail;

	conv->bit = (unsigned int *)calloc(conv->_segSize, sizeof(unsigned int));
	conv->sine = (float *)calloc(conv->_segSize, sizeof(float));
	if (!conv->bit || !conv->sine || !fft_alloc_buffer(&conv->_fftBuffer[0], conv->_segSize) ||
		!fft_alloc_buffer(&conv->_fftBuffer[1], conv->_segSize))
		goto fail;
	fhtbitReversalTbl(conv->bit, conv->_segSize);
	fhtsinHalfTblFloat(conv->sine, conv->_segSize);

	if (!fft_alloc_table(&conv->_segmentsReLeft, conv->_segCount) ||
		!fft_alloc_table(&conv->_segmentsImLeft, conv->_segCount) ||
		!fft_alloc_table(&conv->_segmentsReRight, conv->_segCount) ||
		!fft_alloc_table(&conv->_segmentsImRight, conv->_segCount))
		goto fail;
	for (unsigned int i = 0; i < conv->_segCount; ++i)
	{
		if (!fft_alloc_buffer(&conv->_segmentsReLeft[i], conv->_fftComplexSize) ||
			!fft_alloc_buffer(&conv->_segmentsImLeft[i], conv->_fftComplexSize) ||
			!fft_alloc_buffer(&conv->_segmentsReRight[i], conv->_fftComplexSize) ||
			!fft_alloc_buffer(&conv->_segmentsImRight[i], conv->_fftComplexSize))
			goto fail;
	}

	if (!fft_alloc_table(&conv->_segmentsLLIRRe, conv->_segCount) ||
		!fft_alloc_table(&conv->_segmentsLLIRIm, conv->_segCount) ||
		!fft_alloc_table(&conv->_segmentsLRIRRe, conv->_segCount) ||
		!fft_alloc_table(&conv->_segmentsLRIRIm, conv->_segCount) ||
		!fft_alloc_table(&conv->_segmentsRLIRRe, conv->_segCount) ||
		!fft_alloc_table(&conv->_segmentsRLIRIm, conv->_segCount) ||
		!fft_alloc_table(&conv->_segmentsRRIRRe, conv->_segCount) ||
		!fft_alloc_table(&conv->_segmentsRRIRIm, conv->_segCount))
		goto fail;
	for (unsigned int i = 0; i < conv->_segCount; ++i)
	{
		if (!fft_alloc_buffer(&conv->_segmentsLLIRRe[i], conv->_fftComplexSize) ||
			!fft_alloc_buffer(&conv->_segmentsLLIRIm[i], conv->_fftComplexSize) ||
			!fft_alloc_buffer(&conv->_segmentsLRIRRe[i], conv->_fftComplexSize) ||
			!fft_alloc_buffer(&conv->_segmentsLRIRIm[i], conv->_fftComplexSize) ||
			!fft_alloc_buffer(&conv->_segmentsRLIRRe[i], conv->_fftComplexSize) ||
			!fft_alloc_buffer(&conv->_segmentsRLIRIm[i], conv->_fftComplexSize) ||
			!fft_alloc_buffer(&conv->_segmentsRRIRRe[i], conv->_fftComplexSize) ||
			!fft_alloc_buffer(&conv->_segmentsRRIRIm[i], conv->_fftComplexSize))
			goto fail;
		fft_fill_ir_segment(irLL, irLen, i, conv->_blockSize, conv->_segSize,
			conv->_fftComplexSize, conv->bit, conv->_fftBuffer[0], conv->sine,
			conv->fft, conv->_segmentsLLIRRe[i], conv->_segmentsLLIRIm[i]);
		fft_fill_ir_segment(irLR, irLen, i, conv->_blockSize, conv->_segSize,
			conv->_fftComplexSize, conv->bit, conv->_fftBuffer[0], conv->sine,
			conv->fft, conv->_segmentsLRIRRe[i], conv->_segmentsLRIRIm[i]);
		fft_fill_ir_segment(irRL, irLen, i, conv->_blockSize, conv->_segSize,
			conv->_fftComplexSize, conv->bit, conv->_fftBuffer[0], conv->sine,
			conv->fft, conv->_segmentsRLIRRe[i], conv->_segmentsRLIRIm[i]);
		fft_fill_ir_segment(irRR, irLen, i, conv->_blockSize, conv->_segSize,
			conv->_fftComplexSize, conv->bit, conv->_fftBuffer[0], conv->sine,
			conv->fft, conv->_segmentsRRIRRe[i], conv->_segmentsRRIRIm[i]);
	}

	if (!fft_alloc_buffer(&conv->_preMultiplied[0][0], conv->_fftComplexSize) ||
		!fft_alloc_buffer(&conv->_preMultiplied[0][1], conv->_fftComplexSize) ||
		!fft_alloc_buffer(&conv->_preMultiplied[1][0], conv->_fftComplexSize) ||
		!fft_alloc_buffer(&conv->_preMultiplied[1][1], conv->_fftComplexSize) ||
		!fft_alloc_buffer(&conv->_overlap[0], conv->_blockSize) ||
		!fft_alloc_buffer(&conv->_overlap[1], conv->_blockSize) ||
		!fft_alloc_buffer(&conv->_inputBuffer[0], conv->_blockSize) ||
		!fft_alloc_buffer(&conv->_inputBuffer[1], conv->_blockSize))
		goto fail;
	conv->_inputBufferFill = 0;
	conv->_current = 0;
	conv->gain = 1.0f / ((float)conv->_segSize * 2.0f);
	conv->_irLength = irLen;
	conv->_initialized = 1;
	return 1;

fail:
	FFTConvolver2x4x2Free(conv);
	return 0;
}
int FFTConvolver2x2LoadImpulseResponse(FFTConvolver2x2 *conv, unsigned int blockSize, const float* irL, const float* irR, unsigned int irLen)
{
	unsigned int roundedBlock, segCount, complexSize;
	if (!conv || !fft_ir_valid(irL, irLen) || !fft_ir_valid(irR, irLen) ||
		!fft_geometry_valid(blockSize, irLen, &roundedBlock, &segCount, &complexSize))
		return 0;
	FFTConvolver2x2Free(conv);
	conv->_blockSize = roundedBlock;
	conv->_segSize = 2u * roundedBlock;
	conv->_segCount = segCount;
	conv->_segCountMinus1 = segCount - 1;
	conv->_fftComplexSize = complexSize;

	if (conv->_segSize == 2) conv->fft = DFT2;
	else if (conv->_segSize == 4) conv->fft = DFT4;
	else if (conv->_segSize == 8) conv->fft = DFT8;
	else if (conv->_segSize == 16) conv->fft = DFT16;
	else if (conv->_segSize == 32) conv->fft = DFT32;
	else if (conv->_segSize == 64) conv->fft = DFT64;
	else if (conv->_segSize == 128) conv->fft = DFT128;
	else if (conv->_segSize == 256) conv->fft = DFT256;
	else if (conv->_segSize == 512) conv->fft = DFT512;
	else if (conv->_segSize == 1024) conv->fft = DFT1024;
	else if (conv->_segSize == 2048) conv->fft = DFT2048;
	else if (conv->_segSize == 4096) conv->fft = DFT4096;
	else if (conv->_segSize == 8192) conv->fft = DFT8192;
	else if (conv->_segSize == 16384) conv->fft = DFT16384;
	else if (conv->_segSize == 32768) conv->fft = DFT32768;
	else if (conv->_segSize == 65536) conv->fft = DFT65536;
	else if (conv->_segSize == 131072) conv->fft = DFT131072;
	else if (conv->_segSize == 262144) conv->fft = DFT262144;
	else if (conv->_segSize == 524288) conv->fft = DFT524288;
	else if (conv->_segSize == 1048576) conv->fft = DFT1048576;
	else goto fail;

	conv->bit = (unsigned int *)calloc(conv->_segSize, sizeof(unsigned int));
	conv->sine = (float *)calloc(conv->_segSize, sizeof(float));
	if (!conv->bit || !conv->sine || !fft_alloc_buffer(&conv->_fftBuffer[0], conv->_segSize) ||
		!fft_alloc_buffer(&conv->_fftBuffer[1], conv->_segSize))
		goto fail;
	fhtbitReversalTbl(conv->bit, conv->_segSize);
	fhtsinHalfTblFloat(conv->sine, conv->_segSize);

	if (!fft_alloc_table(&conv->_segmentsReLeft, conv->_segCount) ||
		!fft_alloc_table(&conv->_segmentsImLeft, conv->_segCount) ||
		!fft_alloc_table(&conv->_segmentsReRight, conv->_segCount) ||
		!fft_alloc_table(&conv->_segmentsImRight, conv->_segCount))
		goto fail;
	for (unsigned int i = 0; i < conv->_segCount; ++i)
	{
		if (!fft_alloc_buffer(&conv->_segmentsReLeft[i], conv->_fftComplexSize) ||
			!fft_alloc_buffer(&conv->_segmentsImLeft[i], conv->_fftComplexSize) ||
			!fft_alloc_buffer(&conv->_segmentsReRight[i], conv->_fftComplexSize) ||
			!fft_alloc_buffer(&conv->_segmentsImRight[i], conv->_fftComplexSize))
			goto fail;
	}

	if (!fft_alloc_table(&conv->_segmentsLLIRRe, conv->_segCount) ||
		!fft_alloc_table(&conv->_segmentsLLIRIm, conv->_segCount) ||
		!fft_alloc_table(&conv->_segmentsRRIRRe, conv->_segCount) ||
		!fft_alloc_table(&conv->_segmentsRRIRIm, conv->_segCount))
		goto fail;
	for (unsigned int i = 0; i < conv->_segCount; ++i)
	{
		if (!fft_alloc_buffer(&conv->_segmentsLLIRRe[i], conv->_fftComplexSize) ||
			!fft_alloc_buffer(&conv->_segmentsLLIRIm[i], conv->_fftComplexSize) ||
			!fft_alloc_buffer(&conv->_segmentsRRIRRe[i], conv->_fftComplexSize) ||
			!fft_alloc_buffer(&conv->_segmentsRRIRIm[i], conv->_fftComplexSize))
			goto fail;
		fft_fill_ir_segment(irL, irLen, i, conv->_blockSize, conv->_segSize,
			conv->_fftComplexSize, conv->bit, conv->_fftBuffer[0], conv->sine,
			conv->fft, conv->_segmentsLLIRRe[i], conv->_segmentsLLIRIm[i]);
		fft_fill_ir_segment(irR, irLen, i, conv->_blockSize, conv->_segSize,
			conv->_fftComplexSize, conv->bit, conv->_fftBuffer[0], conv->sine,
			conv->fft, conv->_segmentsRRIRRe[i], conv->_segmentsRRIRIm[i]);
	}

	if (!fft_alloc_buffer(&conv->_preMultiplied[0][0], conv->_fftComplexSize) ||
		!fft_alloc_buffer(&conv->_preMultiplied[0][1], conv->_fftComplexSize) ||
		!fft_alloc_buffer(&conv->_preMultiplied[1][0], conv->_fftComplexSize) ||
		!fft_alloc_buffer(&conv->_preMultiplied[1][1], conv->_fftComplexSize) ||
		!fft_alloc_buffer(&conv->_overlap[0], conv->_blockSize) ||
		!fft_alloc_buffer(&conv->_overlap[1], conv->_blockSize) ||
		!fft_alloc_buffer(&conv->_inputBuffer[0], conv->_blockSize) ||
		!fft_alloc_buffer(&conv->_inputBuffer[1], conv->_blockSize))
		goto fail;
	conv->_inputBufferFill = 0;
	conv->_current = 0;
	conv->gain = 1.0f / ((float)conv->_segSize * 2.0f);
	conv->_irLength = irLen;
	conv->_initialized = 1;
	return 1;

fail:
	FFTConvolver2x2Free(conv);
	return 0;
}
void FFTConvolver2x2RefreshImpulseResponse(FFTConvolver2x2 *conv1, FFTConvolver2x2 *conv2, const float* irL, const float* irR, unsigned int irLen)
{
	if (!conv1 || !conv2 || !fft_ir_valid(irL, irLen) ||
		!fft_ir_valid(irR, irLen) || !fft_2x2_ready(conv1) ||
		!fft_2x2_ready(conv2) || conv1->_blockSize != conv2->_blockSize ||
		conv1->_segSize != conv2->_segSize || conv1->_segCount != conv2->_segCount ||
		conv1->_fftComplexSize != conv2->_fftComplexSize ||
		conv1->_irLength != irLen || conv2->_irLength != irLen)
		return;
	for (unsigned int i = 0; i < conv1->_segCount; ++i)
	{
		fft_fill_ir_segment(irL, irLen, i, conv1->_blockSize, conv1->_segSize,
			conv1->_fftComplexSize, conv1->bit, conv1->_fftBuffer[0],
			conv1->sine, conv1->fft, conv2->_segmentsLLIRRe[i],
			conv2->_segmentsLLIRIm[i]);
		fft_fill_ir_segment(irR, irLen, i, conv1->_blockSize, conv1->_segSize,
			conv1->_fftComplexSize, conv1->bit, conv1->_fftBuffer[0],
			conv1->sine, conv1->fft, conv2->_segmentsRRIRRe[i],
			conv2->_segmentsRRIRIm[i]);
	}
}
int FFTConvolver1x2LoadImpulseResponse(FFTConvolver1x2 *conv, unsigned int blockSize, const float* irL, const float* irR, unsigned int irLen)
{
	unsigned int roundedBlock, segCount, complexSize;
	if (!conv || !fft_ir_valid(irL, irLen) || !fft_ir_valid(irR, irLen) ||
		!fft_geometry_valid(blockSize, irLen, &roundedBlock, &segCount, &complexSize))
		return 0;
	FFTConvolver1x2Free(conv);
	conv->_blockSize = roundedBlock;
	conv->_segSize = 2u * roundedBlock;
	conv->_segCount = segCount;
	conv->_segCountMinus1 = segCount - 1;
	conv->_fftComplexSize = complexSize;

	if (conv->_segSize == 2) conv->fft = DFT2;
	else if (conv->_segSize == 4) conv->fft = DFT4;
	else if (conv->_segSize == 8) conv->fft = DFT8;
	else if (conv->_segSize == 16) conv->fft = DFT16;
	else if (conv->_segSize == 32) conv->fft = DFT32;
	else if (conv->_segSize == 64) conv->fft = DFT64;
	else if (conv->_segSize == 128) conv->fft = DFT128;
	else if (conv->_segSize == 256) conv->fft = DFT256;
	else if (conv->_segSize == 512) conv->fft = DFT512;
	else if (conv->_segSize == 1024) conv->fft = DFT1024;
	else if (conv->_segSize == 2048) conv->fft = DFT2048;
	else if (conv->_segSize == 4096) conv->fft = DFT4096;
	else if (conv->_segSize == 8192) conv->fft = DFT8192;
	else if (conv->_segSize == 16384) conv->fft = DFT16384;
	else if (conv->_segSize == 32768) conv->fft = DFT32768;
	else if (conv->_segSize == 65536) conv->fft = DFT65536;
	else if (conv->_segSize == 131072) conv->fft = DFT131072;
	else if (conv->_segSize == 262144) conv->fft = DFT262144;
	else if (conv->_segSize == 524288) conv->fft = DFT524288;
	else if (conv->_segSize == 1048576) conv->fft = DFT1048576;
	else goto fail;

	conv->bit = (unsigned int *)calloc(conv->_segSize, sizeof(unsigned int));
	conv->sine = (float *)calloc(conv->_segSize, sizeof(float));
	if (!conv->bit || !conv->sine || !fft_alloc_buffer(&conv->_fftBuffer[0], conv->_segSize) ||
		!fft_alloc_buffer(&conv->_fftBuffer[1], conv->_segSize))
		goto fail;
	fhtbitReversalTbl(conv->bit, conv->_segSize);
	fhtsinHalfTblFloat(conv->sine, conv->_segSize);

	if (!fft_alloc_table(&conv->_segmentsRe, conv->_segCount) ||
		!fft_alloc_table(&conv->_segmentsIm, conv->_segCount))
		goto fail;
	for (unsigned int i = 0; i < conv->_segCount; ++i)
	{
		if (!fft_alloc_buffer(&conv->_segmentsRe[i], conv->_fftComplexSize) ||
			!fft_alloc_buffer(&conv->_segmentsIm[i], conv->_fftComplexSize))
			goto fail;
	}

	if (!fft_alloc_table(&conv->_segmentsLLIRRe, conv->_segCount) ||
		!fft_alloc_table(&conv->_segmentsLLIRIm, conv->_segCount) ||
		!fft_alloc_table(&conv->_segmentsRRIRRe, conv->_segCount) ||
		!fft_alloc_table(&conv->_segmentsRRIRIm, conv->_segCount))
		goto fail;
	for (unsigned int i = 0; i < conv->_segCount; ++i)
	{
		if (!fft_alloc_buffer(&conv->_segmentsLLIRRe[i], conv->_fftComplexSize) ||
			!fft_alloc_buffer(&conv->_segmentsLLIRIm[i], conv->_fftComplexSize) ||
			!fft_alloc_buffer(&conv->_segmentsRRIRRe[i], conv->_fftComplexSize) ||
			!fft_alloc_buffer(&conv->_segmentsRRIRIm[i], conv->_fftComplexSize))
			goto fail;
		fft_fill_ir_segment(irL, irLen, i, conv->_blockSize, conv->_segSize,
			conv->_fftComplexSize, conv->bit, conv->_fftBuffer[0], conv->sine,
			conv->fft, conv->_segmentsLLIRRe[i], conv->_segmentsLLIRIm[i]);
		fft_fill_ir_segment(irR, irLen, i, conv->_blockSize, conv->_segSize,
			conv->_fftComplexSize, conv->bit, conv->_fftBuffer[0], conv->sine,
			conv->fft, conv->_segmentsRRIRRe[i], conv->_segmentsRRIRIm[i]);
	}

	if (!fft_alloc_buffer(&conv->_preMultiplied[0][0], conv->_fftComplexSize) ||
		!fft_alloc_buffer(&conv->_preMultiplied[0][1], conv->_fftComplexSize) ||
		!fft_alloc_buffer(&conv->_preMultiplied[1][0], conv->_fftComplexSize) ||
		!fft_alloc_buffer(&conv->_preMultiplied[1][1], conv->_fftComplexSize) ||
		!fft_alloc_buffer(&conv->_overlap[0], conv->_blockSize) ||
		!fft_alloc_buffer(&conv->_overlap[1], conv->_blockSize) ||
		!fft_alloc_buffer(&conv->_inputBuffer, conv->_blockSize))
		goto fail;
	conv->_inputBufferFill = 0;
	conv->_current = 0;
	conv->gain = 1.0f / ((float)conv->_segSize * 2.0f);
	conv->_irLength = irLen;
	conv->_initialized = 1;
	return 1;

fail:
	FFTConvolver1x2Free(conv);
	return 0;
}
void FFTConvolver1x1Process(FFTConvolver1x1 *conv, const float* input, float* output, unsigned int len)
{
	if (len == 0)
		return;
	if (!fft_1x1_ready(conv) || !input || !output)
	{
		fft_zero_output(output, len);
		return;
	}
	unsigned int j, symIdx;
	unsigned int processed = 0;
	while (processed < len)
	{
		const int inputBufferWasEmpty = (conv->_inputBufferFill == 0);
		const unsigned int processing = min(len - processed, conv->_blockSize - conv->_inputBufferFill);
		const unsigned int inputBufferPos = conv->_inputBufferFill;
		memcpy(conv->_inputBuffer + inputBufferPos, input + processed, processing * sizeof(float));

		// Forward FFT
		for (j = 0; j < conv->_blockSize; j++)
			conv->_fftBuffer[conv->bit[j]] = conv->_inputBuffer[j];
		for (j = conv->_blockSize; j < conv->_segSize; j++)
			conv->_fftBuffer[conv->bit[j]] = 0.0f;
		conv->fft(conv->_fftBuffer, conv->sine);
		conv->_segmentsRe[conv->_current][0] = conv->_fftBuffer[0];
		for (j = 1; j < conv->_fftComplexSize; j++)
		{
			symIdx = conv->_segSize - j;
			conv->_segmentsRe[conv->_current][j] = conv->_fftBuffer[j] + conv->_fftBuffer[symIdx];
			conv->_segmentsIm[conv->_current][j] = conv->_fftBuffer[j] - conv->_fftBuffer[symIdx];
		}

		// Complex multiplication
		const float *reA;
		const float *imA;
		const float *reB;
		const float *imB;
		unsigned int end4 = conv->_fftComplexSize - 1;
		if (inputBufferWasEmpty)
		{
			unsigned int segFrameIndex = (conv->_current + 1) % conv->_segCount;
			if (conv->_segCount > 1)
			{
				float *re = conv->_preMultiplied[0];
				float *im = conv->_preMultiplied[1];
				reA = conv->_segmentsIRRe[1];
				imA = conv->_segmentsIRIm[1];
				reB = conv->_segmentsRe[segFrameIndex];
				imB = conv->_segmentsIm[segFrameIndex];
				for (j = 0; j < end4; j += 4)
				{
					re[j + 0] = reA[j + 0] * reB[j + 0] - imA[j + 0] * imB[j + 0];
					re[j + 1] = reA[j + 1] * reB[j + 1] - imA[j + 1] * imB[j + 1];
					re[j + 2] = reA[j + 2] * reB[j + 2] - imA[j + 2] * imB[j + 2];
					re[j + 3] = reA[j + 3] * reB[j + 3] - imA[j + 3] * imB[j + 3];
					im[j + 0] = reA[j + 0] * imB[j + 0] + imA[j + 0] * reB[j + 0];
					im[j + 1] = reA[j + 1] * imB[j + 1] + imA[j + 1] * reB[j + 1];
					im[j + 2] = reA[j + 2] * imB[j + 2] + imA[j + 2] * reB[j + 2];
					im[j + 3] = reA[j + 3] * imB[j + 3] + imA[j + 3] * reB[j + 3];
				}
				re[end4] = reA[end4] * reB[end4] - imA[end4] * imB[end4];
				im[end4] = reA[end4] * imB[end4] + imA[end4] * reB[end4];
				for (unsigned int i = 2; i < conv->_segCount; ++i)
				{
					segFrameIndex = (conv->_current + i) % conv->_segCount;
					re = conv->_preMultiplied[0];
					im = conv->_preMultiplied[1];
					reA = conv->_segmentsIRRe[i];
					imA = conv->_segmentsIRIm[i];
					reB = conv->_segmentsRe[segFrameIndex];
					imB = conv->_segmentsIm[segFrameIndex];
					for (j = 0; j < end4; j += 4)
					{
						re[j + 0] += reA[j + 0] * reB[j + 0] - imA[j + 0] * imB[j + 0];
						re[j + 1] += reA[j + 1] * reB[j + 1] - imA[j + 1] * imB[j + 1];
						re[j + 2] += reA[j + 2] * reB[j + 2] - imA[j + 2] * imB[j + 2];
						re[j + 3] += reA[j + 3] * reB[j + 3] - imA[j + 3] * imB[j + 3];
						im[j + 0] += reA[j + 0] * imB[j + 0] + imA[j + 0] * reB[j + 0];
						im[j + 1] += reA[j + 1] * imB[j + 1] + imA[j + 1] * reB[j + 1];
						im[j + 2] += reA[j + 2] * imB[j + 2] + imA[j + 2] * reB[j + 2];
						im[j + 3] += reA[j + 3] * imB[j + 3] + imA[j + 3] * reB[j + 3];
					}
					re[end4] += reA[end4] * reB[end4] - imA[end4] * imB[end4];
					im[end4] += reA[end4] * imB[end4] + imA[end4] * reB[end4];
				}
			}
		}
		reA = conv->_segmentsIRRe[0];
		imA = conv->_segmentsIRIm[0];
		reB = conv->_segmentsRe[conv->_current];
		imB = conv->_segmentsIm[conv->_current];
		const float *srcRe = conv->_preMultiplied[0];
		const float *srcIm = conv->_preMultiplied[1];
		float real, imag;
		conv->_fftBuffer[0] = reB[0] * reA[0] + srcRe[0];
		for (j = 1; j < conv->_fftComplexSize; ++j)
		{
			symIdx = conv->_segSize - j;
			real = reB[j] * reA[j] - imB[j] * imA[j] + srcRe[j];
			imag = reB[j] * imA[j] + imB[j] * reA[j] + srcIm[j];
			conv->_fftBuffer[conv->bit[j]] = (real + imag) * 0.5f;
			conv->_fftBuffer[conv->bit[symIdx]] = (real - imag) * 0.5f;
		}
		// Backward FFT
		conv->fft(conv->_fftBuffer, conv->sine);

		// Add overlap
		float *result = output + processed;
		const float *a = conv->_fftBuffer + inputBufferPos;
		const float *b = conv->_overlap + inputBufferPos;
		end4 = (processing >> 2) << 2;
		for (j = 0; j < end4; j += 4)
		{
			result[j + 0] = (a[j + 0] + b[j + 0]) * conv->gain;
			result[j + 1] = (a[j + 1] + b[j + 1]) * conv->gain;
			result[j + 2] = (a[j + 2] + b[j + 2]) * conv->gain;
			result[j + 3] = (a[j + 3] + b[j + 3]) * conv->gain;
		}
		for (j = end4; j < processing; ++j)
			result[j] = (a[j] + b[j]) * conv->gain;

		// Input buffer full => Next block
		conv->_inputBufferFill += processing;
		if (conv->_inputBufferFill == conv->_blockSize)
		{
			// Input buffer is empty again now
			memset(conv->_inputBuffer, 0, conv->_blockSize * sizeof(float));
			conv->_inputBufferFill = 0;
			// Save the overlap
			memcpy(conv->_overlap, conv->_fftBuffer + conv->_blockSize, conv->_blockSize * sizeof(float));
			// Update current segment
			conv->_current = (conv->_current > 0) ? (conv->_current - 1) : conv->_segCountMinus1;
		}
		processed += processing;
	}
}
void FFTConvolver2x4x2Process(FFTConvolver2x4x2 *conv, const float* x1, const float* x2, float* y1, float* y2, unsigned int len)
{
	if (len == 0)
		return;
	if (!fft_2x4x2_ready(conv) || !x1 || !x2 || !y1 || !y2)
	{
		fft_zero_output(y1, len);
		fft_zero_output(y2, len);
		return;
	}
	unsigned int j, symIdx;
	unsigned int processed = 0;
	while (processed < len)
	{
		const int inputBufferWasEmpty = (conv->_inputBufferFill == 0);
		const unsigned int processing = min(len - processed, conv->_blockSize - conv->_inputBufferFill);
		const unsigned int inputBufferPos = conv->_inputBufferFill;
		memcpy(conv->_inputBuffer[0] + inputBufferPos, x1 + processed, processing * sizeof(float));
		memcpy(conv->_inputBuffer[1] + inputBufferPos, x2 + processed, processing * sizeof(float));

		// Forward FFT
		for (j = 0; j < conv->_blockSize; j++)
		{
			conv->_fftBuffer[0][conv->bit[j]] = conv->_inputBuffer[0][j];
			conv->_fftBuffer[1][conv->bit[j]] = conv->_inputBuffer[1][j];
		}
		for (j = conv->_blockSize; j < conv->_segSize; j++)
		{
			conv->_fftBuffer[0][conv->bit[j]] = 0.0f;
			conv->_fftBuffer[1][conv->bit[j]] = 0.0f;
		}
		conv->fft(conv->_fftBuffer[0], conv->sine);
		conv->_segmentsReLeft[conv->_current][0] = conv->_fftBuffer[0][0];
		conv->fft(conv->_fftBuffer[1], conv->sine);
		conv->_segmentsReRight[conv->_current][0] = conv->_fftBuffer[1][0];
		for (j = 1; j < conv->_fftComplexSize; j++)
		{
			symIdx = conv->_segSize - j;
			conv->_segmentsReLeft[conv->_current][j] = conv->_fftBuffer[0][j] + conv->_fftBuffer[0][symIdx];
			conv->_segmentsImLeft[conv->_current][j] = conv->_fftBuffer[0][j] - conv->_fftBuffer[0][symIdx];
			conv->_segmentsReRight[conv->_current][j] = conv->_fftBuffer[1][j] + conv->_fftBuffer[1][symIdx];
			conv->_segmentsImRight[conv->_current][j] = conv->_fftBuffer[1][j] - conv->_fftBuffer[1][symIdx];
		}

		// Complex multiplication
		const float *reALL, *imALL, *reALR, *imALR, *reARL, *imARL, *reARR, *imARR;
		const float *reBLeft;
		const float *imBLeft;
		const float *reBRight;
		const float *imBRight;
		unsigned int end4 = conv->_fftComplexSize - 1;
		if (inputBufferWasEmpty)
		{
			unsigned int segFrameIndex = (conv->_current + 1) % conv->_segCount;
			if (conv->_segCount > 1)
			{
				float *reLeft = conv->_preMultiplied[0][0];
				float *imLeft = conv->_preMultiplied[0][1];
				float *reRight = conv->_preMultiplied[1][0];
				float *imRight = conv->_preMultiplied[1][1];
				reALL = conv->_segmentsLLIRRe[1];
				imALL = conv->_segmentsLLIRIm[1];
				reALR = conv->_segmentsLRIRRe[1];
				imALR = conv->_segmentsLRIRIm[1];
				reARL = conv->_segmentsRLIRRe[1];
				imARL = conv->_segmentsRLIRIm[1];
				reARR = conv->_segmentsRRIRRe[1];
				imARR = conv->_segmentsRRIRIm[1];
				reBLeft = conv->_segmentsReLeft[segFrameIndex];
				imBLeft = conv->_segmentsImLeft[segFrameIndex];
				reBRight = conv->_segmentsReRight[segFrameIndex];
				imBRight = conv->_segmentsImRight[segFrameIndex];
				for (j = 0; j < end4; j += 4)
				{
					reLeft[j + 0] = (reARL[j + 0] * reBRight[j + 0] - imARL[j + 0] * imBRight[j + 0]) + (reALL[j + 0] * reBLeft[j + 0] - imALL[j + 0] * imBLeft[j + 0]);
					reLeft[j + 1] = (reARL[j + 1] * reBRight[j + 1] - imARL[j + 1] * imBRight[j + 1]) + (reALL[j + 1] * reBLeft[j + 1] - imALL[j + 1] * imBLeft[j + 1]);
					reLeft[j + 2] = (reARL[j + 2] * reBRight[j + 2] - imARL[j + 2] * imBRight[j + 2]) + (reALL[j + 2] * reBLeft[j + 2] - imALL[j + 2] * imBLeft[j + 2]);
					reLeft[j + 3] = (reARL[j + 3] * reBRight[j + 3] - imARL[j + 3] * imBRight[j + 3]) + (reALL[j + 3] * reBLeft[j + 3] - imALL[j + 3] * imBLeft[j + 3]);
					imLeft[j + 0] = (imARL[j + 0] * reBRight[j + 0] + reARL[j + 0] * imBRight[j + 0]) + (reALL[j + 0] * imBLeft[j + 0] + imALL[j + 0] * reBLeft[j + 0]);
					imLeft[j + 1] = (imARL[j + 1] * reBRight[j + 1] + reARL[j + 1] * imBRight[j + 1]) + (reALL[j + 1] * imBLeft[j + 1] + imALL[j + 1] * reBLeft[j + 1]);
					imLeft[j + 2] = (imARL[j + 2] * reBRight[j + 2] + reARL[j + 2] * imBRight[j + 2]) + (reALL[j + 2] * imBLeft[j + 2] + imALL[j + 2] * reBLeft[j + 2]);
					imLeft[j + 3] = (imARL[j + 3] * reBRight[j + 3] + reARL[j + 3] * imBRight[j + 3]) + (reALL[j + 3] * imBLeft[j + 3] + imALL[j + 3] * reBLeft[j + 3]);
					reRight[j + 0] = (reALR[j + 0] * reBLeft[j + 0] - imALR[j + 0] * imBLeft[j + 0]) + (reARR[j + 0] * reBRight[j + 0] - imARR[j + 0] * imBRight[j + 0]);
					reRight[j + 1] = (reALR[j + 1] * reBLeft[j + 1] - imALR[j + 1] * imBLeft[j + 1]) + (reARR[j + 1] * reBRight[j + 1] - imARR[j + 1] * imBRight[j + 1]);
					reRight[j + 2] = (reALR[j + 2] * reBLeft[j + 2] - imALR[j + 2] * imBLeft[j + 2]) + (reARR[j + 2] * reBRight[j + 2] - imARR[j + 2] * imBRight[j + 2]);
					reRight[j + 3] = (reALR[j + 3] * reBLeft[j + 3] - imALR[j + 3] * imBLeft[j + 3]) + (reARR[j + 3] * reBRight[j + 3] - imARR[j + 3] * imBRight[j + 3]);
					imRight[j + 0] = (imALR[j + 0] * reBLeft[j + 0] + reALR[j + 0] * imBLeft[j + 0]) + (reARR[j + 0] * imBRight[j + 0] + imARR[j + 0] * reBRight[j + 0]);
					imRight[j + 1] = (imALR[j + 1] * reBLeft[j + 1] + reALR[j + 1] * imBLeft[j + 1]) + (reARR[j + 1] * imBRight[j + 1] + imARR[j + 1] * reBRight[j + 1]);
					imRight[j + 2] = (imALR[j + 2] * reBLeft[j + 2] + reALR[j + 2] * imBLeft[j + 2]) + (reARR[j + 2] * imBRight[j + 2] + imARR[j + 2] * reBRight[j + 2]);
					imRight[j + 3] = (imALR[j + 3] * reBLeft[j + 3] + reALR[j + 3] * imBLeft[j + 3]) + (reARR[j + 3] * imBRight[j + 3] + imARR[j + 3] * reBRight[j + 3]);
				}
				reLeft[end4] = (reARL[end4] * reBRight[end4] - imARL[end4] * imBRight[end4]) + (reALL[end4] * reBLeft[end4] - imALL[end4] * imBLeft[end4]);
				imLeft[end4] = (imARL[end4] * reBRight[end4] + reARL[end4] * imBRight[end4]) + (reALL[end4] * imBLeft[end4] + imALL[end4] * reBLeft[end4]);
				reRight[end4] = (reALR[end4] * reBLeft[end4] - imALR[end4] * imBLeft[end4]) + (reARR[end4] * reBRight[end4] - imARR[end4] * imBRight[end4]);
				imRight[end4] = (imALR[end4] * reBLeft[end4] + reALR[end4] * imBLeft[end4]) + (reARR[end4] * imBRight[end4] + imARR[end4] * reBRight[end4]);
				for (unsigned int i = 2; i < conv->_segCount; ++i)
				{
					segFrameIndex = (conv->_current + i) % conv->_segCount;
					reLeft = conv->_preMultiplied[0][0];
					imLeft = conv->_preMultiplied[0][1];
					reRight = conv->_preMultiplied[1][0];
					imRight = conv->_preMultiplied[1][1];
					reALL = conv->_segmentsLLIRRe[i];
					imALL = conv->_segmentsLLIRIm[i];
					reALR = conv->_segmentsLRIRRe[i];
					imALR = conv->_segmentsLRIRIm[i];
					reARL = conv->_segmentsRLIRRe[i];
					imARL = conv->_segmentsRLIRIm[i];
					reARR = conv->_segmentsRRIRRe[i];
					imARR = conv->_segmentsRRIRIm[i];
					reBLeft = conv->_segmentsReLeft[segFrameIndex];
					imBLeft = conv->_segmentsImLeft[segFrameIndex];
					reBRight = conv->_segmentsReRight[segFrameIndex];
					imBRight = conv->_segmentsImRight[segFrameIndex];
					for (j = 0; j < end4; j += 4)
					{
						reLeft[j + 0] += (reARL[j + 0] * reBRight[j + 0] - imARL[j + 0] * imBRight[j + 0]) + (reALL[j + 0] * reBLeft[j + 0] - imALL[j + 0] * imBLeft[j + 0]);
						reLeft[j + 1] += (reARL[j + 1] * reBRight[j + 1] - imARL[j + 1] * imBRight[j + 1]) + (reALL[j + 1] * reBLeft[j + 1] - imALL[j + 1] * imBLeft[j + 1]);
						reLeft[j + 2] += (reARL[j + 2] * reBRight[j + 2] - imARL[j + 2] * imBRight[j + 2]) + (reALL[j + 2] * reBLeft[j + 2] - imALL[j + 2] * imBLeft[j + 2]);
						reLeft[j + 3] += (reARL[j + 3] * reBRight[j + 3] - imARL[j + 3] * imBRight[j + 3]) + (reALL[j + 3] * reBLeft[j + 3] - imALL[j + 3] * imBLeft[j + 3]);
						imLeft[j + 0] += (imARL[j + 0] * reBRight[j + 0] + reARL[j + 0] * imBRight[j + 0]) + (reALL[j + 0] * imBLeft[j + 0] + imALL[j + 0] * reBLeft[j + 0]);
						imLeft[j + 1] += (imARL[j + 1] * reBRight[j + 1] + reARL[j + 1] * imBRight[j + 1]) + (reALL[j + 1] * imBLeft[j + 1] + imALL[j + 1] * reBLeft[j + 1]);
						imLeft[j + 2] += (imARL[j + 2] * reBRight[j + 2] + reARL[j + 2] * imBRight[j + 2]) + (reALL[j + 2] * imBLeft[j + 2] + imALL[j + 2] * reBLeft[j + 2]);
						imLeft[j + 3] += (imARL[j + 3] * reBRight[j + 3] + reARL[j + 3] * imBRight[j + 3]) + (reALL[j + 3] * imBLeft[j + 3] + imALL[j + 3] * reBLeft[j + 3]);
						reRight[j + 0] += (reALR[j + 0] * reBLeft[j + 0] - imALR[j + 0] * imBLeft[j + 0]) + (reARR[j + 0] * reBRight[j + 0] - imARR[j + 0] * imBRight[j + 0]);
						reRight[j + 1] += (reALR[j + 1] * reBLeft[j + 1] - imALR[j + 1] * imBLeft[j + 1]) + (reARR[j + 1] * reBRight[j + 1] - imARR[j + 1] * imBRight[j + 1]);
						reRight[j + 2] += (reALR[j + 2] * reBLeft[j + 2] - imALR[j + 2] * imBLeft[j + 2]) + (reARR[j + 2] * reBRight[j + 2] - imARR[j + 2] * imBRight[j + 2]);
						reRight[j + 3] += (reALR[j + 3] * reBLeft[j + 3] - imALR[j + 3] * imBLeft[j + 3]) + (reARR[j + 3] * reBRight[j + 3] - imARR[j + 3] * imBRight[j + 3]);
						imRight[j + 0] += (imALR[j + 0] * reBLeft[j + 0] + reALR[j + 0] * imBLeft[j + 0]) + (reARR[j + 0] * imBRight[j + 0] + imARR[j + 0] * reBRight[j + 0]);
						imRight[j + 1] += (imALR[j + 1] * reBLeft[j + 1] + reALR[j + 1] * imBLeft[j + 1]) + (reARR[j + 1] * imBRight[j + 1] + imARR[j + 1] * reBRight[j + 1]);
						imRight[j + 2] += (imALR[j + 2] * reBLeft[j + 2] + reALR[j + 2] * imBLeft[j + 2]) + (reARR[j + 2] * imBRight[j + 2] + imARR[j + 2] * reBRight[j + 2]);
						imRight[j + 3] += (imALR[j + 3] * reBLeft[j + 3] + reALR[j + 3] * imBLeft[j + 3]) + (reARR[j + 3] * imBRight[j + 3] + imARR[j + 3] * reBRight[j + 3]);
					}
					reLeft[end4] += (reARL[end4] * reBRight[end4] - imARL[end4] * imBRight[end4]) + (reALL[end4] * reBLeft[end4] - imALL[end4] * imBLeft[end4]);
					imLeft[end4] += (imARL[end4] * reBRight[end4] + reARL[end4] * imBRight[end4]) + (reALL[end4] * imBLeft[end4] + imALL[end4] * reBLeft[end4]);
					reRight[end4] += (reALR[end4] * reBLeft[end4] - imALR[end4] * imBLeft[end4]) + (reARR[end4] * reBRight[end4] - imARR[end4] * imBRight[end4]);
					imRight[end4] += (imALR[end4] * reBLeft[end4] + reALR[end4] * imBLeft[end4]) + (reARR[end4] * imBRight[end4] + imARR[end4] * reBRight[end4]);
				}
			}
		}
		reALL = conv->_segmentsLLIRRe[0];
		imALL = conv->_segmentsLLIRIm[0];
		reALR = conv->_segmentsLRIRRe[0];
		imALR = conv->_segmentsLRIRIm[0];
		reARL = conv->_segmentsRLIRRe[0];
		imARL = conv->_segmentsRLIRIm[0];
		reARR = conv->_segmentsRRIRRe[0];
		imARR = conv->_segmentsRRIRIm[0];
		reBLeft = conv->_segmentsReLeft[conv->_current];
		imBLeft = conv->_segmentsImLeft[conv->_current];
		reBRight = conv->_segmentsReRight[conv->_current];
		imBRight = conv->_segmentsImRight[conv->_current];
		const float *src1Re = conv->_preMultiplied[0][0];
		const float *src1Im = conv->_preMultiplied[0][1];
		const float *src2Re = conv->_preMultiplied[1][0];
		const float *src2Im = conv->_preMultiplied[1][1];
		float realL, imagL, realR, imagR;
		conv->_fftBuffer[0][0] = (reARL[0] * reBRight[0]) + (reALL[0] * reBLeft[0]) + src1Re[0];
		conv->_fftBuffer[1][0] = (reALR[0] * reBLeft[0]) + (reARR[0] * reBRight[0]) + src2Re[0];
		for (j = 1; j < conv->_fftComplexSize; ++j)
		{
			symIdx = conv->_segSize - j;
			realL = (reARL[j] * reBRight[j] - imARL[j] * imBRight[j]) + (reALL[j] * reBLeft[j] - imALL[j] * imBLeft[j]) + src1Re[j];
			imagL = (imARL[j] * reBRight[j] + reARL[j] * imBRight[j]) + (reALL[j] * imBLeft[j] + imALL[j] * reBLeft[j]) + src1Im[j];
			realR = (reALR[j] * reBLeft[j] - imALR[j] * imBLeft[j]) + (reARR[j] * reBRight[j] - imARR[j] * imBRight[j]) + src2Re[j];
			imagR = (imALR[j] * reBLeft[j] + reALR[j] * imBLeft[j]) + (reARR[j] * imBRight[j] + imARR[j] * reBRight[j]) + src2Im[j];
			conv->_fftBuffer[0][conv->bit[j]] = (realL + imagL) * 0.5f;
			conv->_fftBuffer[0][conv->bit[symIdx]] = (realL - imagL) * 0.5f;
			conv->_fftBuffer[1][conv->bit[j]] = (realR + imagR) * 0.5f;
			conv->_fftBuffer[1][conv->bit[symIdx]] = (realR - imagR) * 0.5f;
		}
		// Backward FFT
		conv->fft(conv->_fftBuffer[0], conv->sine);
		conv->fft(conv->_fftBuffer[1], conv->sine);

		// Add overlap
		float *result1 = y1 + processed;
		const float *a1 = conv->_fftBuffer[0] + inputBufferPos;
		const float *b1 = conv->_overlap[0] + inputBufferPos;
		float *result2 = y2 + processed;
		const float *a2 = conv->_fftBuffer[1] + inputBufferPos;
		const float *b2 = conv->_overlap[1] + inputBufferPos;
		end4 = (processing >> 2) << 2;
		for (j = 0; j < end4; j += 4)
		{
			result1[j + 0] = (a1[j + 0] + b1[j + 0]) * conv->gain;
			result1[j + 1] = (a1[j + 1] + b1[j + 1]) * conv->gain;
			result1[j + 2] = (a1[j + 2] + b1[j + 2]) * conv->gain;
			result1[j + 3] = (a1[j + 3] + b1[j + 3]) * conv->gain;
			result2[j + 0] = (a2[j + 0] + b2[j + 0]) * conv->gain;
			result2[j + 1] = (a2[j + 1] + b2[j + 1]) * conv->gain;
			result2[j + 2] = (a2[j + 2] + b2[j + 2]) * conv->gain;
			result2[j + 3] = (a2[j + 3] + b2[j + 3]) * conv->gain;
		}
		for (j = end4; j < processing; ++j)
		{
			result1[j] = (a1[j] + b1[j]) * conv->gain;
			result2[j] = (a2[j] + b2[j]) * conv->gain;
		}

		// Input buffer full => Next block
		conv->_inputBufferFill += processing;
		if (conv->_inputBufferFill == conv->_blockSize)
		{
			// Input buffer is empty again now
			memset(conv->_inputBuffer[0], 0, conv->_blockSize * sizeof(float));
			memset(conv->_inputBuffer[1], 0, conv->_blockSize * sizeof(float));
			conv->_inputBufferFill = 0;
			// Save the overlap
			memcpy(conv->_overlap[0], conv->_fftBuffer[0] + conv->_blockSize, conv->_blockSize * sizeof(float));
			memcpy(conv->_overlap[1], conv->_fftBuffer[1] + conv->_blockSize, conv->_blockSize * sizeof(float));
			// Update current segment
			conv->_current = (conv->_current > 0) ? (conv->_current - 1) : conv->_segCountMinus1;
		}
		processed += processing;
	}
}
void FFTConvolver2x2Process(FFTConvolver2x2 *conv, const float* x1, const float* x2, float* y1, float* y2, unsigned int len)
{
	if (len == 0)
		return;
	if (!fft_2x2_ready(conv) || !x1 || !x2 || !y1 || !y2)
	{
		fft_zero_output(y1, len);
		fft_zero_output(y2, len);
		return;
	}
	unsigned int j, symIdx;
	unsigned int processed = 0;
	while (processed < len)
	{
		const int inputBufferWasEmpty = (conv->_inputBufferFill == 0);
		const unsigned int processing = min(len - processed, conv->_blockSize - conv->_inputBufferFill);
		const unsigned int inputBufferPos = conv->_inputBufferFill;
		memcpy(conv->_inputBuffer[0] + inputBufferPos, x1 + processed, processing * sizeof(float));
		memcpy(conv->_inputBuffer[1] + inputBufferPos, x2 + processed, processing * sizeof(float));

		// Forward FFT
		for (j = 0; j < conv->_blockSize; j++)
		{
			conv->_fftBuffer[0][conv->bit[j]] = conv->_inputBuffer[0][j];
			conv->_fftBuffer[1][conv->bit[j]] = conv->_inputBuffer[1][j];
		}
		for (j = conv->_blockSize; j < conv->_segSize; j++)
		{
			conv->_fftBuffer[0][conv->bit[j]] = 0.0f;
			conv->_fftBuffer[1][conv->bit[j]] = 0.0f;
		}
		conv->fft(conv->_fftBuffer[0], conv->sine);
		conv->_segmentsReLeft[conv->_current][0] = conv->_fftBuffer[0][0];
		conv->fft(conv->_fftBuffer[1], conv->sine);
		conv->_segmentsReRight[conv->_current][0] = conv->_fftBuffer[1][0];
		for (j = 1; j < conv->_fftComplexSize; j++)
		{
			symIdx = conv->_segSize - j;
			conv->_segmentsReLeft[conv->_current][j] = conv->_fftBuffer[0][j] + conv->_fftBuffer[0][symIdx];
			conv->_segmentsImLeft[conv->_current][j] = conv->_fftBuffer[0][j] - conv->_fftBuffer[0][symIdx];
			conv->_segmentsReRight[conv->_current][j] = conv->_fftBuffer[1][j] + conv->_fftBuffer[1][symIdx];
			conv->_segmentsImRight[conv->_current][j] = conv->_fftBuffer[1][j] - conv->_fftBuffer[1][symIdx];
		}

		// Complex multiplication
		const float *reALL, *imALL, *reARR, *imARR;
		const float *reBLeft;
		const float *imBLeft;
		const float *reBRight;
		const float *imBRight;
		unsigned int end4 = conv->_fftComplexSize - 1;
		if (inputBufferWasEmpty)
		{
			unsigned int segFrameIndex = (conv->_current + 1) % conv->_segCount;
			if (conv->_segCount > 1)
			{
				float *reLeft = conv->_preMultiplied[0][0];
				float *imLeft = conv->_preMultiplied[0][1];
				float *reRight = conv->_preMultiplied[1][0];
				float *imRight = conv->_preMultiplied[1][1];
				reALL = conv->_segmentsLLIRRe[1];
				imALL = conv->_segmentsLLIRIm[1];
				reARR = conv->_segmentsRRIRRe[1];
				imARR = conv->_segmentsRRIRIm[1];
				reBLeft = conv->_segmentsReLeft[segFrameIndex];
				imBLeft = conv->_segmentsImLeft[segFrameIndex];
				reBRight = conv->_segmentsReRight[segFrameIndex];
				imBRight = conv->_segmentsImRight[segFrameIndex];
				for (j = 0; j < end4; j += 4)
				{
					reLeft[j + 0] = reALL[j + 0] * reBLeft[j + 0] - imALL[j + 0] * imBLeft[j + 0];
					reLeft[j + 1] = reALL[j + 1] * reBLeft[j + 1] - imALL[j + 1] * imBLeft[j + 1];
					reLeft[j + 2] = reALL[j + 2] * reBLeft[j + 2] - imALL[j + 2] * imBLeft[j + 2];
					reLeft[j + 3] = reALL[j + 3] * reBLeft[j + 3] - imALL[j + 3] * imBLeft[j + 3];
					imLeft[j + 0] = reALL[j + 0] * imBLeft[j + 0] + imALL[j + 0] * reBLeft[j + 0];
					imLeft[j + 1] = reALL[j + 1] * imBLeft[j + 1] + imALL[j + 1] * reBLeft[j + 1];
					imLeft[j + 2] = reALL[j + 2] * imBLeft[j + 2] + imALL[j + 2] * reBLeft[j + 2];
					imLeft[j + 3] = reALL[j + 3] * imBLeft[j + 3] + imALL[j + 3] * reBLeft[j + 3];
					reRight[j + 0] = reARR[j + 0] * reBRight[j + 0] - imARR[j + 0] * imBRight[j + 0];
					reRight[j + 1] = reARR[j + 1] * reBRight[j + 1] - imARR[j + 1] * imBRight[j + 1];
					reRight[j + 2] = reARR[j + 2] * reBRight[j + 2] - imARR[j + 2] * imBRight[j + 2];
					reRight[j + 3] = reARR[j + 3] * reBRight[j + 3] - imARR[j + 3] * imBRight[j + 3];
					imRight[j + 0] = reARR[j + 0] * imBRight[j + 0] + imARR[j + 0] * reBRight[j + 0];
					imRight[j + 1] = reARR[j + 1] * imBRight[j + 1] + imARR[j + 1] * reBRight[j + 1];
					imRight[j + 2] = reARR[j + 2] * imBRight[j + 2] + imARR[j + 2] * reBRight[j + 2];
					imRight[j + 3] = reARR[j + 3] * imBRight[j + 3] + imARR[j + 3] * reBRight[j + 3];
				}
				reLeft[end4] = reALL[end4] * reBLeft[end4] - imALL[end4] * imBLeft[end4];
				imLeft[end4] = reALL[end4] * imBLeft[end4] + imALL[end4] * reBLeft[end4];
				reRight[end4] = reARR[end4] * reBRight[end4] - imARR[end4] * imBRight[end4];
				imRight[end4] = reARR[end4] * imBRight[end4] + imARR[end4] * reBRight[end4];
				for (unsigned int i = 2; i < conv->_segCount; ++i)
				{
					segFrameIndex = (conv->_current + i) % conv->_segCount;
					reLeft = conv->_preMultiplied[0][0];
					imLeft = conv->_preMultiplied[0][1];
					reRight = conv->_preMultiplied[1][0];
					imRight = conv->_preMultiplied[1][1];
					reALL = conv->_segmentsLLIRRe[i];
					imALL = conv->_segmentsLLIRIm[i];
					reARR = conv->_segmentsRRIRRe[i];
					imARR = conv->_segmentsRRIRIm[i];
					reBLeft = conv->_segmentsReLeft[segFrameIndex];
					imBLeft = conv->_segmentsImLeft[segFrameIndex];
					reBRight = conv->_segmentsReRight[segFrameIndex];
					imBRight = conv->_segmentsImRight[segFrameIndex];
					for (j = 0; j < end4; j += 4)
					{
						reLeft[j + 0] += reALL[j + 0] * reBLeft[j + 0] - imALL[j + 0] * imBLeft[j + 0];
						reLeft[j + 1] += reALL[j + 1] * reBLeft[j + 1] - imALL[j + 1] * imBLeft[j + 1];
						reLeft[j + 2] += reALL[j + 2] * reBLeft[j + 2] - imALL[j + 2] * imBLeft[j + 2];
						reLeft[j + 3] += reALL[j + 3] * reBLeft[j + 3] - imALL[j + 3] * imBLeft[j + 3];
						imLeft[j + 0] += reALL[j + 0] * imBLeft[j + 0] + imALL[j + 0] * reBLeft[j + 0];
						imLeft[j + 1] += reALL[j + 1] * imBLeft[j + 1] + imALL[j + 1] * reBLeft[j + 1];
						imLeft[j + 2] += reALL[j + 2] * imBLeft[j + 2] + imALL[j + 2] * reBLeft[j + 2];
						imLeft[j + 3] += reALL[j + 3] * imBLeft[j + 3] + imALL[j + 3] * reBLeft[j + 3];
						reRight[j + 0] += reARR[j + 0] * reBRight[j + 0] - imARR[j + 0] * imBRight[j + 0];
						reRight[j + 1] += reARR[j + 1] * reBRight[j + 1] - imARR[j + 1] * imBRight[j + 1];
						reRight[j + 2] += reARR[j + 2] * reBRight[j + 2] - imARR[j + 2] * imBRight[j + 2];
						reRight[j + 3] += reARR[j + 3] * reBRight[j + 3] - imARR[j + 3] * imBRight[j + 3];
						imRight[j + 0] += reARR[j + 0] * imBRight[j + 0] + imARR[j + 0] * reBRight[j + 0];
						imRight[j + 1] += reARR[j + 1] * imBRight[j + 1] + imARR[j + 1] * reBRight[j + 1];
						imRight[j + 2] += reARR[j + 2] * imBRight[j + 2] + imARR[j + 2] * reBRight[j + 2];
						imRight[j + 3] += reARR[j + 3] * imBRight[j + 3] + imARR[j + 3] * reBRight[j + 3];
					}
					reLeft[end4] += reALL[end4] * reBLeft[end4] - imALL[end4] * imBLeft[end4];
					imLeft[end4] += reALL[end4] * imBLeft[end4] + imALL[end4] * reBLeft[end4];
					reRight[end4] += reARR[end4] * reBRight[end4] - imARR[end4] * imBRight[end4];
					imRight[end4] += reARR[end4] * imBRight[end4] + imARR[end4] * reBRight[end4];
				}
			}
		}
		reALL = conv->_segmentsLLIRRe[0];
		imALL = conv->_segmentsLLIRIm[0];
		reARR = conv->_segmentsRRIRRe[0];
		imARR = conv->_segmentsRRIRIm[0];
		reBLeft = conv->_segmentsReLeft[conv->_current];
		imBLeft = conv->_segmentsImLeft[conv->_current];
		reBRight = conv->_segmentsReRight[conv->_current];
		imBRight = conv->_segmentsImRight[conv->_current];
		const float *src1Re = conv->_preMultiplied[0][0];
		const float *src1Im = conv->_preMultiplied[0][1];
		const float *src2Re = conv->_preMultiplied[1][0];
		const float *src2Im = conv->_preMultiplied[1][1];
		float realL, imagL, realR, imagR;
		conv->_fftBuffer[0][0] = (reALL[0] * reBLeft[0]) + src1Re[0];
		conv->_fftBuffer[1][0] = (reARR[0] * reBRight[0]) + src2Re[0];
		for (j = 1; j < conv->_fftComplexSize; ++j)
		{
			symIdx = conv->_segSize - j;
			realL = (reALL[j] * reBLeft[j] - imALL[j] * imBLeft[j]) + src1Re[j];
			imagL = (reALL[j] * imBLeft[j] + imALL[j] * reBLeft[j]) + src1Im[j];
			realR = (reARR[j] * reBRight[j] - imARR[j] * imBRight[j]) + src2Re[j];
			imagR = (reARR[j] * imBRight[j] + imARR[j] * reBRight[j]) + src2Im[j];
			conv->_fftBuffer[0][conv->bit[j]] = (realL + imagL) * 0.5f;
			conv->_fftBuffer[0][conv->bit[symIdx]] = (realL - imagL) * 0.5f;
			conv->_fftBuffer[1][conv->bit[j]] = (realR + imagR) * 0.5f;
			conv->_fftBuffer[1][conv->bit[symIdx]] = (realR - imagR) * 0.5f;
		}
		// Backward FFT
		conv->fft(conv->_fftBuffer[0], conv->sine);
		conv->fft(conv->_fftBuffer[1], conv->sine);

		// Add overlap
		float *result1 = y1 + processed;
		const float *a1 = conv->_fftBuffer[0] + inputBufferPos;
		const float *b1 = conv->_overlap[0] + inputBufferPos;
		float *result2 = y2 + processed;
		const float *a2 = conv->_fftBuffer[1] + inputBufferPos;
		const float *b2 = conv->_overlap[1] + inputBufferPos;
		end4 = (processing >> 2) << 2;
		for (j = 0; j < end4; j += 4)
		{
			result1[j + 0] = (a1[j + 0] + b1[j + 0]) * conv->gain;
			result1[j + 1] = (a1[j + 1] + b1[j + 1]) * conv->gain;
			result1[j + 2] = (a1[j + 2] + b1[j + 2]) * conv->gain;
			result1[j + 3] = (a1[j + 3] + b1[j + 3]) * conv->gain;
			result2[j + 0] = (a2[j + 0] + b2[j + 0]) * conv->gain;
			result2[j + 1] = (a2[j + 1] + b2[j + 1]) * conv->gain;
			result2[j + 2] = (a2[j + 2] + b2[j + 2]) * conv->gain;
			result2[j + 3] = (a2[j + 3] + b2[j + 3]) * conv->gain;
		}
		for (j = end4; j < processing; ++j)
		{
			result1[j] = (a1[j] + b1[j]) * conv->gain;
			result2[j] = (a2[j] + b2[j]) * conv->gain;
		}

		// Input buffer full => Next block
		conv->_inputBufferFill += processing;
		if (conv->_inputBufferFill == conv->_blockSize)
		{
			// Input buffer is empty again now
			memset(conv->_inputBuffer[0], 0, conv->_blockSize * sizeof(float));
			memset(conv->_inputBuffer[1], 0, conv->_blockSize * sizeof(float));
			conv->_inputBufferFill = 0;
			// Save the overlap
			memcpy(conv->_overlap[0], conv->_fftBuffer[0] + conv->_blockSize, conv->_blockSize * sizeof(float));
			memcpy(conv->_overlap[1], conv->_fftBuffer[1] + conv->_blockSize, conv->_blockSize * sizeof(float));
			// Update current segment
			conv->_current = (conv->_current > 0) ? (conv->_current - 1) : conv->_segCountMinus1;
		}
		processed += processing;
	}
}
void FFTConvolver1x2Process(FFTConvolver1x2 *conv, const float* x, float* y1, float* y2, unsigned int len)
{
	if (len == 0)
		return;
	if (!fft_1x2_ready(conv) || !x || !y1 || !y2)
	{
		fft_zero_output(y1, len);
		fft_zero_output(y2, len);
		return;
	}
	unsigned int j, symIdx;
	unsigned int processed = 0;
	while (processed < len)
	{
		const int inputBufferWasEmpty = (conv->_inputBufferFill == 0);
		const unsigned int processing = min(len - processed, conv->_blockSize - conv->_inputBufferFill);
		const unsigned int inputBufferPos = conv->_inputBufferFill;
		memcpy(conv->_inputBuffer + inputBufferPos, x + processed, processing * sizeof(float));

		// Forward FFT
		for (j = 0; j < conv->_blockSize; j++)
			conv->_fftBuffer[0][conv->bit[j]] = conv->_inputBuffer[j];
		for (j = conv->_blockSize; j < conv->_segSize; j++)
			conv->_fftBuffer[0][conv->bit[j]] = 0.0f;
		conv->fft(conv->_fftBuffer[0], conv->sine);
		conv->_segmentsRe[conv->_current][0] = conv->_fftBuffer[0][0];
		for (j = 1; j < conv->_fftComplexSize; j++)
		{
			symIdx = conv->_segSize - j;
			conv->_segmentsRe[conv->_current][j] = conv->_fftBuffer[0][j] + conv->_fftBuffer[0][symIdx];
			conv->_segmentsIm[conv->_current][j] = conv->_fftBuffer[0][j] - conv->_fftBuffer[0][symIdx];
		}

		// Complex multiplication
		const float *reALL, *imALL, *reARR, *imARR;
		const float *reB;
		const float *imB;
		unsigned int end4 = conv->_fftComplexSize - 1;
		if (inputBufferWasEmpty)
		{
			unsigned int segFrameIndex = (conv->_current + 1) % conv->_segCount;
			if (conv->_segCount > 1)
			{
				float *reLeft = conv->_preMultiplied[0][0];
				float *imLeft = conv->_preMultiplied[0][1];
				float *reRight = conv->_preMultiplied[1][0];
				float *imRight = conv->_preMultiplied[1][1];
				reALL = conv->_segmentsLLIRRe[1];
				imALL = conv->_segmentsLLIRIm[1];
				reARR = conv->_segmentsRRIRRe[1];
				imARR = conv->_segmentsRRIRIm[1];
				reB = conv->_segmentsRe[segFrameIndex];
				imB = conv->_segmentsIm[segFrameIndex];
				for (j = 0; j < end4; j += 4)
				{
					reLeft[j + 0] = reALL[j + 0] * reB[j + 0] - imALL[j + 0] * imB[j + 0];
					reLeft[j + 1] = reALL[j + 1] * reB[j + 1] - imALL[j + 1] * imB[j + 1];
					reLeft[j + 2] = reALL[j + 2] * reB[j + 2] - imALL[j + 2] * imB[j + 2];
					reLeft[j + 3] = reALL[j + 3] * reB[j + 3] - imALL[j + 3] * imB[j + 3];
					imLeft[j + 0] = reALL[j + 0] * imB[j + 0] + imALL[j + 0] * reB[j + 0];
					imLeft[j + 1] = reALL[j + 1] * imB[j + 1] + imALL[j + 1] * reB[j + 1];
					imLeft[j + 2] = reALL[j + 2] * imB[j + 2] + imALL[j + 2] * reB[j + 2];
					imLeft[j + 3] = reALL[j + 3] * imB[j + 3] + imALL[j + 3] * reB[j + 3];
					reRight[j + 0] = reARR[j + 0] * reB[j + 0] - imARR[j + 0] * imB[j + 0];
					reRight[j + 1] = reARR[j + 1] * reB[j + 1] - imARR[j + 1] * imB[j + 1];
					reRight[j + 2] = reARR[j + 2] * reB[j + 2] - imARR[j + 2] * imB[j + 2];
					reRight[j + 3] = reARR[j + 3] * reB[j + 3] - imARR[j + 3] * imB[j + 3];
					imRight[j + 0] = reARR[j + 0] * imB[j + 0] + imARR[j + 0] * reB[j + 0];
					imRight[j + 1] = reARR[j + 1] * imB[j + 1] + imARR[j + 1] * reB[j + 1];
					imRight[j + 2] = reARR[j + 2] * imB[j + 2] + imARR[j + 2] * reB[j + 2];
					imRight[j + 3] = reARR[j + 3] * imB[j + 3] + imARR[j + 3] * reB[j + 3];
				}
				reLeft[end4] = reALL[end4] * reB[end4] - imALL[end4] * imB[end4];
				imLeft[end4] = reALL[end4] * imB[end4] + imALL[end4] * reB[end4];
				reRight[end4] = reARR[end4] * reB[end4] - imARR[end4] * imB[end4];
				imRight[end4] = reARR[end4] * imB[end4] + imARR[end4] * reB[end4];
				for (unsigned int i = 2; i < conv->_segCount; ++i)
				{
					segFrameIndex = (conv->_current + i) % conv->_segCount;
					reLeft = conv->_preMultiplied[0][0];
					imLeft = conv->_preMultiplied[0][1];
					reRight = conv->_preMultiplied[1][0];
					imRight = conv->_preMultiplied[1][1];
					reALL = conv->_segmentsLLIRRe[i];
					imALL = conv->_segmentsLLIRIm[i];
					reARR = conv->_segmentsRRIRRe[i];
					imARR = conv->_segmentsRRIRIm[i];
					reB = conv->_segmentsRe[segFrameIndex];
					imB = conv->_segmentsIm[segFrameIndex];
					for (j = 0; j < end4; j += 4)
					{
						reLeft[j + 0] += reALL[j + 0] * reB[j + 0] - imALL[j + 0] * imB[j + 0];
						reLeft[j + 1] += reALL[j + 1] * reB[j + 1] - imALL[j + 1] * imB[j + 1];
						reLeft[j + 2] += reALL[j + 2] * reB[j + 2] - imALL[j + 2] * imB[j + 2];
						reLeft[j + 3] += reALL[j + 3] * reB[j + 3] - imALL[j + 3] * imB[j + 3];
						imLeft[j + 0] += reALL[j + 0] * imB[j + 0] + imALL[j + 0] * reB[j + 0];
						imLeft[j + 1] += reALL[j + 1] * imB[j + 1] + imALL[j + 1] * reB[j + 1];
						imLeft[j + 2] += reALL[j + 2] * imB[j + 2] + imALL[j + 2] * reB[j + 2];
						imLeft[j + 3] += reALL[j + 3] * imB[j + 3] + imALL[j + 3] * reB[j + 3];
						reRight[j + 0] += reARR[j + 0] * reB[j + 0] - imARR[j + 0] * imB[j + 0];
						reRight[j + 1] += reARR[j + 1] * reB[j + 1] - imARR[j + 1] * imB[j + 1];
						reRight[j + 2] += reARR[j + 2] * reB[j + 2] - imARR[j + 2] * imB[j + 2];
						reRight[j + 3] += reARR[j + 3] * reB[j + 3] - imARR[j + 3] * imB[j + 3];
						imRight[j + 0] += reARR[j + 0] * imB[j + 0] + imARR[j + 0] * reB[j + 0];
						imRight[j + 1] += reARR[j + 1] * imB[j + 1] + imARR[j + 1] * reB[j + 1];
						imRight[j + 2] += reARR[j + 2] * imB[j + 2] + imARR[j + 2] * reB[j + 2];
						imRight[j + 3] += reARR[j + 3] * imB[j + 3] + imARR[j + 3] * reB[j + 3];
					}
					reLeft[end4] += reALL[end4] * reB[end4] - imALL[end4] * imB[end4];
					imLeft[end4] += reALL[end4] * imB[end4] + imALL[end4] * reB[end4];
					reRight[end4] += reARR[end4] * reB[end4] - imARR[end4] * imB[end4];
					imRight[end4] += reARR[end4] * imB[end4] + imARR[end4] * reB[end4];
				}
			}
		}
		reALL = conv->_segmentsLLIRRe[0];
		imALL = conv->_segmentsLLIRIm[0];
		reARR = conv->_segmentsRRIRRe[0];
		imARR = conv->_segmentsRRIRIm[0];
		reB = conv->_segmentsRe[conv->_current];
		imB = conv->_segmentsIm[conv->_current];
		const float *src1Re = conv->_preMultiplied[0][0];
		const float *src1Im = conv->_preMultiplied[0][1];
		const float *src2Re = conv->_preMultiplied[1][0];
		const float *src2Im = conv->_preMultiplied[1][1];
		float realL, imagL, realR, imagR;
		conv->_fftBuffer[0][0] = (reALL[0] * reB[0]) + src1Re[0];
		conv->_fftBuffer[1][0] = (reARR[0] * reB[0]) + src2Re[0];
		for (j = 1; j < conv->_fftComplexSize; ++j)
		{
			symIdx = conv->_segSize - j;
			realL = (reALL[j] * reB[j] - imALL[j] * imB[j]) + src1Re[j];
			imagL = (reALL[j] * imB[j] + imALL[j] * reB[j]) + src1Im[j];
			realR = (reARR[j] * reB[j] - imARR[j] * imB[j]) + src2Re[j];
			imagR = (reARR[j] * imB[j] + imARR[j] * reB[j]) + src2Im[j];
			conv->_fftBuffer[0][conv->bit[j]] = (realL + imagL) * 0.5f;
			conv->_fftBuffer[0][conv->bit[symIdx]] = (realL - imagL) * 0.5f;
			conv->_fftBuffer[1][conv->bit[j]] = (realR + imagR) * 0.5f;
			conv->_fftBuffer[1][conv->bit[symIdx]] = (realR - imagR) * 0.5f;
		}
		// Backward FFT
		conv->fft(conv->_fftBuffer[0], conv->sine);
		conv->fft(conv->_fftBuffer[1], conv->sine);

		// Add overlap
		float *result1 = y1 + processed;
		const float *a1 = conv->_fftBuffer[0] + inputBufferPos;
		const float *b1 = conv->_overlap[0] + inputBufferPos;
		float *result2 = y2 + processed;
		const float *a2 = conv->_fftBuffer[1] + inputBufferPos;
		const float *b2 = conv->_overlap[1] + inputBufferPos;
		end4 = (processing >> 2) << 2;
		for (j = 0; j < end4; j += 4)
		{
			result1[j + 0] = (a1[j + 0] + b1[j + 0]) * conv->gain;
			result1[j + 1] = (a1[j + 1] + b1[j + 1]) * conv->gain;
			result1[j + 2] = (a1[j + 2] + b1[j + 2]) * conv->gain;
			result1[j + 3] = (a1[j + 3] + b1[j + 3]) * conv->gain;
			result2[j + 0] = (a2[j + 0] + b2[j + 0]) * conv->gain;
			result2[j + 1] = (a2[j + 1] + b2[j + 1]) * conv->gain;
			result2[j + 2] = (a2[j + 2] + b2[j + 2]) * conv->gain;
			result2[j + 3] = (a2[j + 3] + b2[j + 3]) * conv->gain;
		}
		for (j = end4; j < processing; ++j)
		{
			result1[j] = (a1[j] + b1[j]) * conv->gain;
			result2[j] = (a2[j] + b2[j]) * conv->gain;
		}

		// Input buffer full => Next block
		conv->_inputBufferFill += processing;
		if (conv->_inputBufferFill == conv->_blockSize)
		{
			// Input buffer is empty again now
			memset(conv->_inputBuffer, 0, conv->_blockSize * sizeof(float));
			conv->_inputBufferFill = 0;
			// Save the overlap
			memcpy(conv->_overlap[0], conv->_fftBuffer[0] + conv->_blockSize, conv->_blockSize * sizeof(float));
			memcpy(conv->_overlap[1], conv->_fftBuffer[1] + conv->_blockSize, conv->_blockSize * sizeof(float));
			// Update current segment
			conv->_current = (conv->_current > 0) ? (conv->_current - 1) : conv->_segCountMinus1;
		}
		processed += processing;
	}
}