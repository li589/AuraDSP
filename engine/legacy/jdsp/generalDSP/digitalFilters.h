#ifndef M_PI
#define M_PI 3.14159265358979323846264338327950288
#endif
#define ORDER 16 // Must be even
#define ORDERPLUS1 (ORDER + 1)
#define ORDERMULT2 (ORDER << 1)
#define STAGE (ORDER >> 1)
#define M1STAGE (STAGE - 1)
typedef struct
{
	double a1, a2;
} LPFCoeffs;
typedef struct
{
	double _xn1, _xn2;
	double _yn[STAGE], _yn1[STAGE], _yn2[STAGE];
} iirSOS;
typedef struct
{
	int factor;
	LPFCoeffs coeffs[STAGE];
	float gain;
	iirSOS lpfU, lpfD;
} samplerateTool;
typedef struct
{
	double b, bp, a;
	double zLPF, zHPF;
} DF1P;
typedef struct
{
	DF1P sys[9];
} TenBandsCrossover;
void init10BandsCrossover(TenBandsCrossover *lr4, double fs, double lowBandHz, double midBand1Hz, double midBand2Hz, double midBand3Hz, double midBand4Hz, double midBand5Hz, double midBand6Hz, double midBand7Hz, double midBand8Hz);
void process10BandsCrossover(TenBandsCrossover *lr4, double x, double *lowOut, double *midOut1, double *midOut2, double *midOut3, double *midOut4, double *midOut5, double *midOut6, double *midOut7, double *midOut8, double *highOut);
void oversample_makeSmp(samplerateTool *oversample, int factor);
/* [PATCHED-AuraDSP P-049] 允许调用方指定抗混叠低通的归一化截止（相对输入 Nyquist）。
 * 真空管在 44.1k 工作域需要把通带保到 20 kHz；固定的 0.89 会让 20 kHz
 * 落进 16 阶 Butterworth 的过渡带（实测 -10.6 dB）。 */
void oversample_makeSmpCutoff(samplerateTool *oversample, int factor, double cutoffRatio);
void oversample_stepupSmp(samplerateTool *oversample, float input, float *output);
double oversample_stepdownSmpDouble(samplerateTool *oversample, double *input);
float oversample_stepdownSmpFloat(samplerateTool *oversample, float *input);
