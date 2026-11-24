#ifndef __NS_EEL_MATRIX_H__
#define __NS_EEL_MATRIX_H__
#include "eelCommon.h"
#include "numericSys/quadprog.h"
/* [PATCHED-AuraDSP P-057] 跨度守卫（审查 P-052 残留）：eel_matrix
 * 内建族的 rows/cols/长度全部来自脚本，基址虽已由 P-052 掩码进池，
 * 但「合法基址 + 超大跨度」仍可读出池尾、且 rows*cols 在 int32 里
 * 先行溢出。与 nseel-compiler.c 的 MemCpy 纪律同口径：掩码后基址
 * + 元素跨度（int64 计算）必须整段落在池块内，否则整次调用拒绝。 */
static int _eel_span_fits(int32_t offs, int64_t span)
{
	if (span < 0)
		return 0;
	return (int64_t)((uint32_t)offs & (uint32_t)(NSEEL_RAM_ITEMSPERBLOCK - 1)) + span <= NSEEL_RAM_ITEMSPERBLOCK;
}

static float NSEEL_CGEN_CALL _eel_matDeterminant(float *blocks, float *start, float *m, float *n)
{
	int32_t rows1 = (int32_t)*m;
	int32_t cols1 = (int32_t)*n;
	if (rows1 != cols1)
		return (float)-1;
	int32_t offs1 = (int32_t)(*start + NSEEL_CLOSEFACTOR);
	float *matrix = __NSEEL_RAMAlloc(blocks, offs1);
	/* [PATCHED-AuraDSP P-057] */ if (!_eel_span_fits(offs1, (int64_t)rows1 * cols1))
		return (float)-1;
	double *mat = (double*)malloc(rows1 * cols1 * sizeof(double));
	for (int i = 0; i < rows1 * cols1; i++)
		mat[i] = matrix[i];
	float val = (float)determinant(mat, rows1);
	free(mat);
	return val;
}
static float NSEEL_CGEN_CALL _eel_matRank(float *blocks, float *start, float *m, float *n)
{
	int32_t rows1 = (int32_t)*m;
	int32_t cols1 = (int32_t)*n;
	int32_t offs1 = (int32_t)(*start + NSEEL_CLOSEFACTOR);
	float *matrix = __NSEEL_RAMAlloc(blocks, offs1);
	/* [PATCHED-AuraDSP P-057] */ if (!_eel_span_fits(offs1, (int64_t)rows1 * cols1))
		return (float)-1;
	double *mat = (double*)malloc(rows1 * cols1 * sizeof(double));
	for (int i = 0; i < rows1 * cols1; i++)
		mat[i] = matrix[i];
	float val = (float)rank(mat, rows1, cols1);
	free(mat);
	return val;
}
void transposeFlt(float *src, float *dst, int32_t n, int32_t m)
{
	for (int32_t k = 0; k < n * m; k++)
		dst[k] = src[m * (k % n) + (k / n)];
}
static float NSEEL_CGEN_CALL _eel_matTranspose(void *opaque, INT_PTR num_param, float **parms)
{
	compileContext *c = (compileContext*)opaque;
	float *blocks = EEL_RAM(c);
	int32_t rows1 = (int32_t)*parms[1];
	int32_t cols1 = (int32_t)*parms[2];
	int32_t offs1 = (int32_t)(*parms[0] + NSEEL_CLOSEFACTOR);
	float *matrix1 = __NSEEL_RAMAlloc(blocks, offs1);
	int32_t offs2 = (int32_t)(*parms[3] + NSEEL_CLOSEFACTOR);
	float *outputMatrix = __NSEEL_RAMAlloc(blocks, offs2);
	/* [PATCHED-AuraDSP P-057] */ if (!_eel_span_fits(offs1, (int64_t)rows1 * cols1) || !_eel_span_fits(offs2, (int64_t)rows1 * cols1))
		return 0;
	transposeFlt(matrix1, outputMatrix, rows1, cols1);
	return 0;
}
static float NSEEL_CGEN_CALL _eel_matPinv(void *opaque, INT_PTR num_param, float **parms)
{
	compileContext *c = (compileContext*)opaque;
	float *blocks = EEL_RAM(c);
	int32_t rows1 = (int32_t)*parms[1];
	int32_t cols1 = (int32_t)*parms[2];
	int32_t offs1 = (int32_t)(*parms[0] + NSEEL_CLOSEFACTOR);
	float *matrix1 = __NSEEL_RAMAlloc(blocks, offs1);
	int32_t offs2 = (int32_t)(*parms[3] + NSEEL_CLOSEFACTOR);
	float *outputMatrix = __NSEEL_RAMAlloc(blocks, offs2);
	int32_t offs3 = (int32_t)(*parms[4] + NSEEL_CLOSEFACTOR);
	float *outputInfo = __NSEEL_RAMAlloc(blocks, offs3);
	/* [PATCHED-AuraDSP P-057] */ if (!_eel_span_fits(offs1, (int64_t)rows1 * cols1) || !_eel_span_fits(offs2, (int64_t)rows1 * cols1) || !_eel_span_fits(offs3, 2))
		return 0;
	int32_t size[2];
	double *matIn = (double*)malloc(rows1 * cols1 * sizeof(double));
	double *matOut = (double*)malloc(rows1 * cols1 * sizeof(double));
	for (int i = 0; i < rows1 * cols1; i++)
		matIn[i] = matrix1[i];
	pinv(matIn, rows1, cols1, matOut, size);
	free(matIn);
	for (int i = 0; i < rows1 * cols1; i++)
		outputMatrix[i] = (float)matOut[i];
	free(matOut);
	outputInfo[0] = (float)size[0];
	outputInfo[1] = (float)size[1];
	return 0;
}
static float NSEEL_CGEN_CALL _eel_matPinvFast(void *opaque, INT_PTR num_param, float **parms)
{
	compileContext *c = (compileContext*)opaque;
	float *blocks = EEL_RAM(c);
	int32_t rows1 = (int32_t)*parms[1];
	int32_t cols1 = (int32_t)*parms[2];
	int32_t offs1 = (int32_t)(*parms[0] + NSEEL_CLOSEFACTOR);
	float *matrix1 = __NSEEL_RAMAlloc(blocks, offs1);
	int32_t offs2 = (int32_t)(*parms[3] + NSEEL_CLOSEFACTOR);
	float *outputMatrix = __NSEEL_RAMAlloc(blocks, offs2);
	int32_t offs3 = (int32_t)(*parms[4] + NSEEL_CLOSEFACTOR);
	float *outputInfo = __NSEEL_RAMAlloc(blocks, offs3);
	/* [PATCHED-AuraDSP P-057] */ if (!_eel_span_fits(offs1, (int64_t)rows1 * cols1) || !_eel_span_fits(offs2, (int64_t)rows1 * cols1) || !_eel_span_fits(offs3, 2))
		return 0;
	int32_t size[2];
	double *matIn = (double*)malloc(rows1 * cols1 * sizeof(double));
	double *matOut = (double*)malloc(rows1 * cols1 * sizeof(double));
	for (int i = 0; i < rows1 * cols1; i++)
		matIn[i] = matrix1[i];
	geninv(matIn, rows1, cols1, matOut, size);
	free(matIn);
	for (int i = 0; i < rows1 * cols1; i++)
		outputMatrix[i] = (float)matOut[i];
	free(matOut);
	outputInfo[0] = (float)size[0];
	outputInfo[1] = (float)size[1];
	return 0;
}
static float NSEEL_CGEN_CALL _eel_cholesky(void *opaque, INT_PTR num_param, float **parms)
{
	compileContext *c = (compileContext*)opaque;
	float *blocks = EEL_RAM(c);
	int32_t rows1 = (int32_t)*parms[1];
	int32_t cols1 = (int32_t)*parms[2];
	if (rows1 != cols1)
		return (float)-1;
	int32_t offs1 = (int32_t)(*parms[0] + NSEEL_CLOSEFACTOR);
	float *matrix1 = __NSEEL_RAMAlloc(blocks, offs1);
	int32_t offs2 = (int32_t)(*parms[3] + NSEEL_CLOSEFACTOR);
	float *outputMatrix = __NSEEL_RAMAlloc(blocks, offs2);
	/* [PATCHED-AuraDSP P-057] */ if (!_eel_span_fits(offs1, (int64_t)rows1 * cols1) || !_eel_span_fits(offs2, (int64_t)rows1 * cols1))
		return (float)-1;
	double *matIn = (double*)malloc(rows1 * cols1 * sizeof(double));
	double *matOut = (double*)malloc(rows1 * cols1 * sizeof(double));
	for (int i = 0; i < rows1 * cols1; i++)
		matIn[i] = matrix1[i];
	cholesky(matIn, matOut, rows1);
	free(matIn);
	for (int i = 0; i < rows1 * cols1; i++)
		outputMatrix[i] = (float)matOut[i];
	free(matOut);
	return 0;
}
static float NSEEL_CGEN_CALL _eel_inv_chol(void *opaque, INT_PTR num_param, float **parms)
{
	compileContext *c = (compileContext*)opaque;
	float *blocks = EEL_RAM(c);
	int32_t rows1 = (int32_t)*parms[1];
	int32_t cols1 = (int32_t)*parms[2];
	if (rows1 != cols1)
		return (float)-1;
	int32_t offs1 = (int32_t)(*parms[0] + NSEEL_CLOSEFACTOR);
	float *matrix1 = __NSEEL_RAMAlloc(blocks, offs1);
	int32_t offs2 = (int32_t)(*parms[3] + NSEEL_CLOSEFACTOR);
	float *outputMatrix = __NSEEL_RAMAlloc(blocks, offs2);
	/* [PATCHED-AuraDSP P-057] */ if (!_eel_span_fits(offs1, (int64_t)rows1 * cols1) || !_eel_span_fits(offs2, (int64_t)rows1 * cols1))
		return (float)-1;
	double *matIn = (double*)malloc(rows1 * cols1 * sizeof(double));
	double *matOut = (double*)malloc(rows1 * cols1 * sizeof(double));
	for (int i = 0; i < rows1 * cols1; i++)
		matIn[i] = matrix1[i];
	inv_chol(matIn, matOut, rows1);
	free(matIn);
	for (int i = 0; i < rows1 * cols1; i++)
		outputMatrix[i] = (float)matOut[i];
	free(matOut);
	return 0;
}
static float NSEEL_CGEN_CALL _eel_matInv(void *opaque, INT_PTR num_param, float **parms)
{
	compileContext *c = (compileContext*)opaque;
	float *blocks = EEL_RAM(c);
	int32_t rows1 = (int32_t)*parms[1];
	int32_t cols1 = (int32_t)*parms[2];
	if (rows1 != cols1)
		return (float)-1;
	int32_t offs1 = (int32_t)(*parms[0] + NSEEL_CLOSEFACTOR);
	float *matrix1 = __NSEEL_RAMAlloc(blocks, offs1);
	int32_t offs2 = (int32_t)(*parms[3] + NSEEL_CLOSEFACTOR);
	float *outputMatrix = __NSEEL_RAMAlloc(blocks, offs2);
	/* [PATCHED-AuraDSP P-057] */ if (!_eel_span_fits(offs1, (int64_t)rows1 * cols1) || !_eel_span_fits(offs2, (int64_t)rows1 * cols1))
		return (float)-1;
	double *matIn = (double*)malloc(rows1 * cols1 * sizeof(double));
	double *matOut = (double*)malloc(rows1 * cols1 * sizeof(double));
	for (int i = 0; i < rows1 * cols1; i++)
		matIn[i] = matrix1[i];
	inv(matIn, rows1, matOut);
	free(matIn);
	for (int i = 0; i < rows1 * cols1; i++)
		outputMatrix[i] = (float)matOut[i];
	free(matOut);
	return 0;
}
static float NSEEL_CGEN_CALL _eel_mldivide(void *opaque, INT_PTR num_param, float **parms)
{
	compileContext *c = (compileContext*)opaque;
	float *blocks = EEL_RAM(c);
	int32_t rows1 = (int32_t)*parms[1];
	int32_t cols1 = (int32_t)*parms[2];
	int32_t offs1 = (int32_t)(*parms[0] + NSEEL_CLOSEFACTOR);
	float *matrix1 = __NSEEL_RAMAlloc(blocks, offs1);
	int32_t rows2 = (int32_t)*parms[4];
	int32_t cols2 = (int32_t)*parms[5];
	int32_t offs2 = (int32_t)(*parms[3] + NSEEL_CLOSEFACTOR);
	float *matrix2 = __NSEEL_RAMAlloc(blocks, offs2);
	int32_t offs3 = (int32_t)(*parms[6] + NSEEL_CLOSEFACTOR);
	float *outputMatrix = __NSEEL_RAMAlloc(blocks, offs3);
	int32_t offs4 = (int32_t)(*parms[7] + NSEEL_CLOSEFACTOR);
	float *outputInfo = __NSEEL_RAMAlloc(blocks, offs4);
	/* [PATCHED-AuraDSP P-057] */ if (!_eel_span_fits(offs1, (int64_t)rows1 * cols1) || !_eel_span_fits(offs2, (int64_t)rows2 * cols2) || !_eel_span_fits(offs4, 2) || !_eel_span_fits(offs3, rows1 == cols1 ? (int64_t)rows2 * cols2 : (int64_t)cols2 * cols1))
		return 0;
	int32_t size[2];
	double *mat1In = (double*)malloc(rows1 * cols1 * sizeof(double));
	double *mat2In = (double*)malloc(rows2 * cols2 * sizeof(double));
	size_t oL;
	if (rows1 == cols1)
		oL = rows2 * cols2;
	else
		oL = cols2 * cols1;
	double *matOut = (double*)malloc(oL * sizeof(double));
	for (int i = 0; i < rows1 * cols1; i++)
		mat1In[i] = matrix1[i];
	for (int i = 0; i < rows2 * cols2; i++)
		mat2In[i] = matrix2[i];
	mldivide(mat1In, rows1, cols1, mat2In, rows2, cols2, matOut, size);
	free(mat1In);
	free(mat2In);
	for (int i = 0; i < size[0] * size[1]; i++)
		outputMatrix[i] = (float)matOut[i];
	free(matOut);
	outputInfo[0] = (float)size[0];
	outputInfo[1] = (float)size[1];
	return 0;
}
static float NSEEL_CGEN_CALL _eel_mrdivide(void *opaque, INT_PTR num_param, float **parms)
{
	compileContext *c = (compileContext*)opaque;
	float *blocks = EEL_RAM(c);
	int32_t rows1 = (int32_t)*parms[1];
	int32_t cols1 = (int32_t)*parms[2];
	int32_t offs1 = (int32_t)(*parms[0] + NSEEL_CLOSEFACTOR);
	float *matrix1 = __NSEEL_RAMAlloc(blocks, offs1);
	int32_t rows2 = (int32_t)*parms[4];
	int32_t cols2 = (int32_t)*parms[5];
	int32_t offs2 = (int32_t)(*parms[3] + NSEEL_CLOSEFACTOR);
	float *matrix2 = __NSEEL_RAMAlloc(blocks, offs2);
	int32_t offs3 = (int32_t)(*parms[6] + NSEEL_CLOSEFACTOR);
	float *outputMatrix = __NSEEL_RAMAlloc(blocks, offs3);
	int32_t offs4 = (int32_t)(*parms[7] + NSEEL_CLOSEFACTOR);
	float *outputInfo = __NSEEL_RAMAlloc(blocks, offs4);
	/* [PATCHED-AuraDSP P-057] */ if (!_eel_span_fits(offs1, (int64_t)rows1 * cols1) || !_eel_span_fits(offs2, (int64_t)rows2 * cols2) || !_eel_span_fits(offs4, 2) || !_eel_span_fits(offs3, rows2 == cols2 ? (int64_t)cols1 * rows1 : (int64_t)rows2 * rows1))
		return 0;
	int32_t size[2];
	double *mat1In = (double*)malloc(rows1 * cols1 * sizeof(double));
	double *mat2In = (double*)malloc(rows2 * cols2 * sizeof(double));
	size_t oL;
	if (rows2 == cols2)
		oL = cols1 * rows1;
	else
		oL = rows2 * rows1;
	double *matOut = (double*)malloc(oL * sizeof(double));
	for (int i = 0; i < rows1 * cols1; i++)
		mat1In[i] = matrix1[i];
	for (int i = 0; i < rows2 * cols2; i++)
		mat2In[i] = matrix2[i];
	mrdivide(mat1In, rows1, cols1, mat2In, rows2, cols2, matOut, size);
	free(mat1In);
	free(mat2In);
	for (int i = 0; i < size[0] * size[1]; i++)
		outputMatrix[i] = (float)matOut[i];
	free(matOut);
	outputInfo[0] = (float)size[0];
	outputInfo[1] = (float)size[1];
	return 0;
}
static float NSEEL_CGEN_CALL _eel_quadprog(void *opaque, INT_PTR num_param, float **parms)
{
	compileContext *c = (compileContext*)opaque;
	float *blocks = EEL_RAM(c);
	int32_t problemLength = (int32_t)(*parms[0] + NSEEL_CLOSEFACTOR);
	float *H = __NSEEL_RAMAlloc(blocks, (int32_t)(*parms[1] + NSEEL_CLOSEFACTOR));
	float *f = __NSEEL_RAMAlloc(blocks, (int32_t)(*parms[2] + NSEEL_CLOSEFACTOR));
	int32_t inequalityLen = (int32_t)(*parms[3] + NSEEL_CLOSEFACTOR);
	int32_t APtr = (int32_t)(*parms[4] + NSEEL_CLOSEFACTOR);
	float *A = 0;
	if (APtr != -1)
		A = __NSEEL_RAMAlloc(blocks, APtr);
	int32_t bPtr = (int32_t)(*parms[5] + NSEEL_CLOSEFACTOR);
	float *b = 0;
	if (bPtr != -1)
		b = __NSEEL_RAMAlloc(blocks, bPtr);
	int32_t equalityLen = (int32_t)(*parms[6] + NSEEL_CLOSEFACTOR);
	int32_t AeqPtr = (int32_t)(*parms[7] + NSEEL_CLOSEFACTOR);
	float *Aeq = 0;
	if (AeqPtr != -1)
		Aeq = __NSEEL_RAMAlloc(blocks, AeqPtr);
	int32_t beqPtr = (int32_t)(*parms[8] + NSEEL_CLOSEFACTOR);
	float *beq = 0;
	if (beqPtr != -1)
		beq = __NSEEL_RAMAlloc(blocks, beqPtr);
	int32_t lbPtr = (int32_t)(*parms[9] + NSEEL_CLOSEFACTOR);
	float *lb = 0;
	if (lbPtr != -1)
		lb = __NSEEL_RAMAlloc(blocks, lbPtr);
	int32_t ubPtr = (int32_t)(*parms[10] + NSEEL_CLOSEFACTOR);
	float *ub = 0;
	if (ubPtr != -1)
		ub = __NSEEL_RAMAlloc(blocks, ubPtr);
	float *ans = __NSEEL_RAMAlloc(blocks, (int32_t)(*parms[11] + NSEEL_CLOSEFACTOR));
	/* [PATCHED-AuraDSP P-057] */ if (problemLength < 0 || inequalityLen < 0 || equalityLen < 0 ||
		!_eel_span_fits((int32_t)(*parms[1] + NSEEL_CLOSEFACTOR), (int64_t)problemLength * problemLength) ||
		!_eel_span_fits((int32_t)(*parms[2] + NSEEL_CLOSEFACTOR), problemLength) ||
		(A && !_eel_span_fits(APtr, (int64_t)inequalityLen * problemLength)) ||
		(b && !_eel_span_fits(bPtr, inequalityLen)) ||
		(Aeq && !_eel_span_fits(AeqPtr, (int64_t)equalityLen * problemLength)) ||
		(beq && !_eel_span_fits(beqPtr, equalityLen)) ||
		(lb && !_eel_span_fits(lbPtr, problemLength)) ||
		(ub && !_eel_span_fits(ubPtr, problemLength)) ||
		!_eel_span_fits((int32_t)(*parms[11] + NSEEL_CLOSEFACTOR), problemLength))
		return 0;
	float fval;
	double *dH = (double*)malloc(problemLength * problemLength * sizeof(double));
	for (int i = 0; i < problemLength * problemLength; i++)
		dH[i] = H[i];
	double *df = (double*)malloc(problemLength * sizeof(double));
	for (int i = 0; i < problemLength; i++)
		df[i] = f[i];
	if ((!A || !b) && inequalityLen)
	{
		const char *msg = "quadprog: inequalityLen greater than 0 while the inequality matrix is empty\nCheck input argument, now assuming no inequality constraints\n";
		EEL_STRING_STDOUT_WRITE(msg, strlen(msg));
	}
	if ((!Aeq || !beq) && equalityLen)
	{
		const char *msg = "quadprog: equalityLen greater than 0 while the equality matrix is empty\nCheck input argument, now assuming no equality constraints\n";
		EEL_STRING_STDOUT_WRITE(msg, strlen(msg));
	}
	int32_t err = quadprog(problemLength, dH, df, inequalityLen, A, b, equalityLen, Aeq, beq, lb, ub, ans, &fval);
	if (err == -2)
	{
		const char *msg = "quadprog: Fatal error";
		EEL_STRING_STDOUT_WRITE(msg, strlen(msg));
	}
	else if (err == -1)
	{
		const char *msg = "quadprog: Quadratic form must be symmetric.";
		EEL_STRING_STDOUT_WRITE(msg, strlen(msg));
	}
	else if (err == 0)
	{
		const char *msg = "quadprog: Found feasible solution.";
		EEL_STRING_STDOUT_WRITE(msg, strlen(msg));
	}
	free(dH);
	free(df);
	return (float)fval;
}
void matrix_transpose_matrix_self_product_float(const float *a, double *product, int rows1, int cols1)
{
	int i, j, k;
	for (i = 0; i < rows1; ++i)
		for (j = 0; j < rows1; ++j)
		{
			double res = 0.0;
			for (k = 0; k < cols1; ++k)
				res += a[k * rows1 + i] * a[k * rows1 + j];
			product[i * rows1 + j] = res;
		}
}
void transpose_matrix_vector_mult_float(const float *mat, const float *vec, double *c, int rows, int cols, double weight)
{
	for (int i = 0; i < cols; i++)
	{
		double res = 0.0;
		for (int j = 0; j < rows; j++)
			res += (mat[j * cols + i] * vec[j] * weight);
		c[i] = res;
	}
}
static float NSEEL_CGEN_CALL _eel_lsqlin(void *opaque, INT_PTR num_param, float **parms)
{
	compileContext *c = (compileContext*)opaque;
	float *blocks = EEL_RAM(c);
	int32_t equationsLength = (int32_t)(*parms[0] + NSEEL_CLOSEFACTOR);
	int32_t problemLength = (int32_t)(*parms[1] + NSEEL_CLOSEFACTOR);
	float *C = __NSEEL_RAMAlloc(blocks, (int32_t)(*parms[2] + NSEEL_CLOSEFACTOR));
	float *d = __NSEEL_RAMAlloc(blocks, (int32_t)(*parms[3] + NSEEL_CLOSEFACTOR));
	int32_t inequalityLen = (int32_t)(*parms[4] + NSEEL_CLOSEFACTOR);
	int32_t APtr = (int32_t)(*parms[5] + NSEEL_CLOSEFACTOR);
	float *A = 0;
	if (APtr != -1)
		A = __NSEEL_RAMAlloc(blocks, APtr);
	int32_t bPtr = (int32_t)(*parms[6] + NSEEL_CLOSEFACTOR);
	float *b = 0;
	if (bPtr != -1)
		b = __NSEEL_RAMAlloc(blocks, bPtr);
	int32_t equalityLen = (int32_t)(*parms[7] + NSEEL_CLOSEFACTOR);
	int32_t AeqPtr = (int32_t)(*parms[8] + NSEEL_CLOSEFACTOR);
	float *Aeq = 0;
	if (AeqPtr != -1)
		Aeq = __NSEEL_RAMAlloc(blocks, AeqPtr);
	int32_t beqPtr = (int32_t)(*parms[9] + NSEEL_CLOSEFACTOR);
	float *beq = 0;
	if (beqPtr != -1)
		beq = __NSEEL_RAMAlloc(blocks, beqPtr);
	int32_t lbPtr = (int32_t)(*parms[10] + NSEEL_CLOSEFACTOR);
	float *lb = 0;
	if (lbPtr != -1)
		lb = __NSEEL_RAMAlloc(blocks, lbPtr);
	int32_t ubPtr = (int32_t)(*parms[11] + NSEEL_CLOSEFACTOR);
	float *ub = 0;
	if (ubPtr != -1)
		ub = __NSEEL_RAMAlloc(blocks, ubPtr);
	float *ans = __NSEEL_RAMAlloc(blocks, (int32_t)(*parms[12] + NSEEL_CLOSEFACTOR));
	/* [PATCHED-AuraDSP P-057] */ if (equationsLength < 0 || problemLength < 0 || inequalityLen < 0 || equalityLen < 0 ||
		!_eel_span_fits((int32_t)(*parms[2] + NSEEL_CLOSEFACTOR), (int64_t)equationsLength * problemLength) ||
		!_eel_span_fits((int32_t)(*parms[3] + NSEEL_CLOSEFACTOR), equationsLength) ||
		(A && !_eel_span_fits(APtr, (int64_t)inequalityLen * problemLength)) ||
		(b && !_eel_span_fits(bPtr, inequalityLen)) ||
		(Aeq && !_eel_span_fits(AeqPtr, (int64_t)equalityLen * problemLength)) ||
		(beq && !_eel_span_fits(beqPtr, equalityLen)) ||
		(lb && !_eel_span_fits(lbPtr, problemLength)) ||
		(ub && !_eel_span_fits(ubPtr, problemLength)) ||
		!_eel_span_fits((int32_t)(*parms[12] + NSEEL_CLOSEFACTOR), problemLength))
		return 0;
	double *hessian = (double*)malloc(problemLength * problemLength * sizeof(double));
	matrix_transpose_matrix_self_product_float(C, hessian, problemLength, equationsLength);
	double *linConstraint = (double*)malloc(problemLength * sizeof(double));
	transpose_matrix_vector_mult_float(C, d, linConstraint, equationsLength, problemLength, -1.0);
	float fval;
	if ((!A || !b) && inequalityLen)
	{
		const char *msg = "lsqlin: inequalityLen greater than 0 while the inequality matrix is empty\nCheck input argument, now assuming no inequality constraints\n";
		EEL_STRING_STDOUT_WRITE(msg, strlen(msg));
	}
	if ((!Aeq || !beq) && equalityLen)
	{
		const char *msg = "lsqlin: equalityLen greater than 0 while the equality matrix is empty\nCheck input argument, now assuming no equality constraints\n";
		EEL_STRING_STDOUT_WRITE(msg, strlen(msg));
	}
	int32_t err = quadprog(problemLength, hessian, linConstraint, inequalityLen, A, b, equalityLen, Aeq, beq, lb, ub, ans, &fval);
	if (err == -2)
	{
		const char *msg = "lsqlin: Fatal error";
		EEL_STRING_STDOUT_WRITE(msg, strlen(msg));
	}
	else if (err == -1)
	{
		const char *msg = "lsqlin: Quadratic form must be symmetric.";
		EEL_STRING_STDOUT_WRITE(msg, strlen(msg));
	}
	else if (err == 0)
	{
		const char *msg = "lsqlin: Found feasible solution.";
		EEL_STRING_STDOUT_WRITE(msg, strlen(msg));
	}
	free(hessian);
	free(linConstraint);
	return (float)fval;
}
static float NSEEL_CGEN_CALL _eel_roots(void *opaque, INT_PTR num_param, float **parms)
{
	compileContext *c = (compileContext*)opaque;
	float *blocks = EEL_RAM(c);
	int32_t N = (int32_t)(*parms[2] + NSEEL_CLOSEFACTOR);
	int32_t offs2 = (int32_t)(*parms[0] + NSEEL_CLOSEFACTOR);
	float *polyRe = __NSEEL_RAMAlloc(blocks, offs2);
	int32_t offs3 = (int32_t)(*parms[1] + NSEEL_CLOSEFACTOR);
	float *polyIm = __NSEEL_RAMAlloc(blocks, offs3);
	int32_t offs4 = (int32_t)(*parms[3] + NSEEL_CLOSEFACTOR);
	float *zeroRe = __NSEEL_RAMAlloc(blocks, offs4);
	int32_t offs5 = (int32_t)(*parms[4] + NSEEL_CLOSEFACTOR);
	float *zeroIm = __NSEEL_RAMAlloc(blocks, offs5);
	/* [PATCHED-AuraDSP P-057] */ if (N < 1 || !_eel_span_fits(offs2, N) || !_eel_span_fits(offs3, N) || !_eel_span_fits(offs4, N - 1) || !_eel_span_fits(offs5, N - 1))
		return 0;
	double *mat1In = (double*)malloc(N * sizeof(double));
	double *mat2In = (double*)malloc(N * sizeof(double));
	double *mat1Out = (double*)malloc((N - 1) * sizeof(double));
	double *mat2Out = (double*)malloc((N - 1) * sizeof(double));
	for (int i = 0; i < N; i++)
	{
		mat1In[i] = polyRe[i];
		mat2In[i] = polyIm[i];
	}
	float degree = (float)cpoly(mat1In, mat2In, N - 1, mat1Out, mat2Out);
	free(mat1In);
	free(mat2In);
	for (int i = 0; i < N - 1; i++)
	{
		zeroRe[i] = (float)mat1Out[i];
		zeroIm[i] = (float)mat2Out[i];
	}
	free(mat1Out);
	free(mat2Out);
	return degree;
}
#include "numericSys/FilterDesign/fdesign.h"
static float NSEEL_CGEN_CALL _eel_cplxpair(void *opaque, INT_PTR num_param, float **parms)
{
	compileContext *c = (compileContext*)opaque;
	float *blocks = EEL_RAM(c);
	int32_t N = (int32_t)(*parms[2] + NSEEL_CLOSEFACTOR);
	int32_t offs2 = (int32_t)(*parms[0] + NSEEL_CLOSEFACTOR);
	float *polyRe = __NSEEL_RAMAlloc(blocks, offs2);
	int32_t offs3 = (int32_t)(*parms[1] + NSEEL_CLOSEFACTOR);
	float *polyIm = __NSEEL_RAMAlloc(blocks, offs3);
	int32_t offs4 = (int32_t)(*parms[3] + NSEEL_CLOSEFACTOR);
	float *sortedRe = __NSEEL_RAMAlloc(blocks, offs4);
	int32_t offs5 = (int32_t)(*parms[4] + NSEEL_CLOSEFACTOR);
	float *sortedIm = __NSEEL_RAMAlloc(blocks, offs5);
	/* [PATCHED-AuraDSP P-057] */ if (N < 1 || !_eel_span_fits(offs2, N) || !_eel_span_fits(offs3, N) || !_eel_span_fits(offs4, N) || !_eel_span_fits(offs5, N))
		return 0;
	double *mat1In = (double*)malloc(N * sizeof(double));
	double *mat2In = (double*)malloc(N * sizeof(double));
	double *mat1Out = (double*)malloc(N * sizeof(double));
	double *mat2Out = (double*)malloc(N * sizeof(double));
	for (int i = 0; i < N; i++)
	{
		mat1In[i] = polyRe[i];
		mat2In[i] = polyIm[i];
	}
	float suc = (float)cplxpair(mat1In, mat2In, N, mat1Out, mat2Out);
	free(mat1In);
	free(mat2In);
	for (int i = 0; i < N; i++)
	{
		sortedRe[i] = (float)mat1Out[i];
		sortedIm[i] = (float)mat2Out[i];
	}
	free(mat1Out);
	free(mat2Out);
	return suc;
}
static float NSEEL_CGEN_CALL _eel_firls(void *opaque, INT_PTR num_param, float **parms)
{
	compileContext *c = (compileContext*)opaque;
	float *blocks = EEL_RAM(c);
	int32_t N = (int32_t)(*parms[0] + NSEEL_CLOSEFACTOR);
	int32_t offs2 = (int32_t)(*parms[1] + NSEEL_CLOSEFACTOR);
	float *F = __NSEEL_RAMAlloc(blocks, offs2);
	int32_t offs3 = (int32_t)(*parms[2] + NSEEL_CLOSEFACTOR);
	float *M = __NSEEL_RAMAlloc(blocks, offs3);
	float *W = 0;
	int32_t offs4 = (int32_t)(*parms[3] > 0.0f ? *parms[3] + NSEEL_CLOSEFACTOR : *parms[3] - NSEEL_CLOSEFACTOR);
	if (offs4 > 0)
		W = __NSEEL_RAMAlloc(blocks, offs4);
	int32_t offs5 = (int32_t)(*parms[6] + NSEEL_CLOSEFACTOR);
	float *h = __NSEEL_RAMAlloc(blocks, offs5);
	int32_t gridLen = (int32_t)(*parms[4] + NSEEL_CLOSEFACTOR);
	int32_t filtertype = (int32_t)(*parms[5] + NSEEL_CLOSEFACTOR);
	if (filtertype < 0)
		filtertype = 0;
	if (filtertype > 2)
		filtertype = 2;
	/* [PATCHED-AuraDSP P-057] */ if (N < 0 || gridLen < 0 || !_eel_span_fits(offs2, gridLen) || !_eel_span_fits(offs3, gridLen) || (W && !_eel_span_fits(offs4, gridLen >> 1)) || !_eel_span_fits(offs5, (int64_t)N + 1))
		return (float)-1;
	double *v1 = (double*)malloc(gridLen * sizeof(double));
	double *v2 = (double*)malloc(gridLen * sizeof(double));
	double *v3 = 0;
	if (W)
	{
		v3 = (double*)malloc((gridLen >> 1) * sizeof(double));
		for (int i = 0; i < gridLen >> 1; i++)
			v3[i] = W[i];
	}
	double *v4 = (double*)malloc((N + 1) * sizeof(double));
	for (int i = 0; i < gridLen; i++)
	{
		v1[i] = F[i];
		v2[i] = M[i];
	}
	int32_t order = firls(N, v1, v2, v3, gridLen, filtertype, v4);
	for (int i = 0; i < N + 1; i++)
		h[i] = (float)v4[i];
	free(v1);
	free(v2);
	if (v3)
		free(v3);
	free(v4);
	return (float)order;
}
static float NSEEL_CGEN_CALL _eel_eqnerror(void *opaque, INT_PTR num_param, float **parms)
{
	compileContext *c = (compileContext*)opaque;
	float *blocks = EEL_RAM(c);
	int32_t M = (int32_t)(*parms[0] + NSEEL_CLOSEFACTOR);
	int32_t N = (int32_t)(*parms[1] + NSEEL_CLOSEFACTOR);
	int32_t gridLen = (int32_t)(*parms[2] + NSEEL_CLOSEFACTOR);
	int32_t offs1 = (int32_t)(*parms[3] + NSEEL_CLOSEFACTOR);
	float *om = __NSEEL_RAMAlloc(blocks, offs1);
	int32_t offs2 = (int32_t)(*parms[4] + NSEEL_CLOSEFACTOR);
	float *cplxReal = __NSEEL_RAMAlloc(blocks, offs2);
	int32_t offs3 = (int32_t)(*parms[5] + NSEEL_CLOSEFACTOR);
	float *cplxImag = __NSEEL_RAMAlloc(blocks, offs3);
	float *W = __NSEEL_RAMAlloc(blocks, (int32_t)(*parms[6] + NSEEL_CLOSEFACTOR));
	int32_t iterEqnErr = (int32_t)(*parms[7] + NSEEL_CLOSEFACTOR);
	if (iterEqnErr < 1)
		iterEqnErr = 1;
	if (iterEqnErr > 3)
		iterEqnErr = 3;
	int32_t offs5 = (int32_t)(*parms[8] + NSEEL_CLOSEFACTOR);
	float *b = __NSEEL_RAMAlloc(blocks, offs5);
	int32_t offs6 = (int32_t)(*parms[9] + NSEEL_CLOSEFACTOR);
	float *a = __NSEEL_RAMAlloc(blocks, offs6);
	/* [PATCHED-AuraDSP P-057] */ if (M < 0 || N < 0 || gridLen < 0 || !_eel_span_fits(offs1, gridLen) || !_eel_span_fits(offs2, gridLen) || !_eel_span_fits(offs3, gridLen) || !_eel_span_fits((int32_t)(*parms[6] + NSEEL_CLOSEFACTOR), gridLen) || !_eel_span_fits(offs5, (int64_t)M + 1) || !_eel_span_fits(offs6, (int64_t)N + 1))
		return 0;
	double *v1 = (double*)malloc(gridLen * sizeof(double));
	double *v2 = (double*)malloc(gridLen * sizeof(double));
	double *v3 = (double*)malloc(gridLen * sizeof(double));
	double *v4 = (double*)malloc(gridLen * sizeof(double));
	for (int i = 0; i < gridLen; i++)
	{
		v1[i] = om[i];
		v2[i] = cplxReal[i];
		v3[i] = cplxImag[i];
		v4[i] = W[i];
	}
	EquationErrorIIR initSolution;
	InitEquationErrorIIR(&initSolution, M, N, gridLen);
	eqnerror(&initSolution, v1, v2, v3, v4, iterEqnErr);
	free(v1);
	free(v2);
	free(v3);
	free(v4);
	for (int32_t i = 0; i < M + 1; i++)
		b[i] = (float)initSolution.b[i];
	for (int32_t i = 0; i < N + 1; i++)
		a[i] = (float)initSolution.a[i];
	EquationErrorIIRFree(&initSolution);
	return 1;
}
static float NSEEL_CGEN_CALL _eel_unwrap(void *opaque, INT_PTR num_param, float **parms)
{
	compileContext *c = (compileContext*)opaque;
	float *blocks = EEL_RAM(c);
	int32_t N = (int32_t)(*parms[1] + NSEEL_CLOSEFACTOR);
	float *x = __NSEEL_RAMAlloc(blocks, (int32_t)(*parms[0] + NSEEL_CLOSEFACTOR));
	/* [PATCHED-AuraDSP P-057] */ if (!_eel_span_fits((int32_t)(*parms[0] + NSEEL_CLOSEFACTOR), N))
		return 0;
	double tol = 0.0;
	if (num_param == 3)
		tol = *parms[2];
	unwrap(x, N, tol);
	return 1;
}
static float NSEEL_CGEN_CALL _eel_zp2sos(void *opaque, INT_PTR num_param, float **parms)
{
	compileContext *c = (compileContext*)opaque;
	float *blocks = EEL_RAM(c);
	int32_t offs1 = (int32_t)(*parms[0] + NSEEL_CLOSEFACTOR);
	float *zRe = __NSEEL_RAMAlloc(blocks, offs1);
	int32_t offs2 = (int32_t)(*parms[1] + NSEEL_CLOSEFACTOR);
	float *zIm = __NSEEL_RAMAlloc(blocks, offs2);
	int32_t zeroNumRoots = (int32_t)(*parms[2] + NSEEL_CLOSEFACTOR);
	int32_t offs3 = (int32_t)(*parms[3] + NSEEL_CLOSEFACTOR);
	float *pRe = __NSEEL_RAMAlloc(blocks, offs3);
	int32_t offs4 = (int32_t)(*parms[4] + NSEEL_CLOSEFACTOR);
	float *pIm = __NSEEL_RAMAlloc(blocks, offs4);
	int32_t poleNumRoots = (int32_t)(*parms[5] + NSEEL_CLOSEFACTOR);
	int32_t offs5 = (int32_t)(*parms[6] + NSEEL_CLOSEFACTOR);
	float *sosOut = __NSEEL_RAMAlloc(blocks, offs5);
	/* [PATCHED-AuraDSP P-057] */ if (!_eel_span_fits(offs1, zeroNumRoots) || !_eel_span_fits(offs2, zeroNumRoots) || !_eel_span_fits(offs3, poleNumRoots) || !_eel_span_fits(offs4, poleNumRoots) || !_eel_span_fits(offs5, ((int64_t)max(zeroNumRoots, poleNumRoots) / 2 + 1) * 6))
		return 0;
	double *v1 = (double*)malloc(zeroNumRoots * sizeof(double));
	double *v2 = (double*)malloc(zeroNumRoots * sizeof(double));
	double *v3 = (double*)malloc(poleNumRoots * sizeof(double));
	double *v4 = (double*)malloc(poleNumRoots * sizeof(double));
	for (int i = 0; i < zeroNumRoots; i++)
	{
		v1[i] = zRe[i];
		v2[i] = zIm[i];
	}
	for (int i = 0; i < poleNumRoots; i++)
	{
		v3[i] = pRe[i];
		v4[i] = pIm[i];
	}
	unsigned int myNSec = (unsigned int)ceil(max(zeroNumRoots, poleNumRoots) * 0.5);
	double *v5 = (double*)malloc(myNSec * 6 * sizeof(double));
	int numSections = zp2sos(v1, v2, zeroNumRoots, v3, v4, poleNumRoots, v5);
	free(v1);
	free(v2);
	free(v3);
	free(v4);
	for (int i = 0; i < numSections * 6; i++)
		sosOut[i] = (float)v5[i];
	free(v5);
	*parms[7] = (float)numSections;
	return (float)(numSections * 6);
}
static float NSEEL_CGEN_CALL _eel_tf2sos(void *opaque, INT_PTR num_param, float **parms)
{
	compileContext *c = (compileContext*)opaque;
	float *blocks = EEL_RAM(c);
	int32_t offs1 = (int32_t)(*parms[0] + NSEEL_CLOSEFACTOR);
	float *b = __NSEEL_RAMAlloc(blocks, offs1);
	int32_t bLen = (int32_t)(*parms[1] + NSEEL_CLOSEFACTOR);
	int32_t offs2 = (int32_t)(*parms[2] + NSEEL_CLOSEFACTOR);
	float *a = __NSEEL_RAMAlloc(blocks, offs2);
	int32_t aLen = (int32_t)(*parms[3] + NSEEL_CLOSEFACTOR);
	int32_t offs3 = (int32_t)(*parms[4] + NSEEL_CLOSEFACTOR);
	float *sosOut = __NSEEL_RAMAlloc(blocks, offs3);
	/* [PATCHED-AuraDSP P-057] */ if (!_eel_span_fits(offs1, bLen) || !_eel_span_fits(offs2, aLen) || !_eel_span_fits(offs3, ((int64_t)max(bLen, aLen) / 2 + 1) * 6))
		return 0;
	double *v1 = (double*)malloc(bLen * sizeof(double));
	double *v2 = (double*)malloc(aLen * sizeof(double));
	for (int i = 0; i < bLen; i++)
		v1[i] = b[i];
	for (int i = 0; i < aLen; i++)
		v2[i] = a[i];
	double *sos;
	int numSections = tf2sos(v1, bLen, v2, aLen, &sos);
	free(v1);
	free(v2);
	for (int i = 0; i < numSections * 6; i++)
		sosOut[i] = (float)sos[i];
	free(sos);
	*parms[5] = (float)numSections;
	return (float)(numSections * 6);
}
#endif
