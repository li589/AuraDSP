#ifndef _EEL_JDSP_HD_H_
#define _EEL_JDSP_HD_H_
#include <stdint.h>
#include "../cpthread.h"
#include "generalDSP/interpolation.h"
#include "Effects/eel2/numericSys/libsamplerate/samplerate.h"
#include "generalDSP/TwoStageFFTConvolver.h"
#include "generalDSP/digitalFilters.h"
#include "Effects/eel2/numericSys/FilterDesign/fdesign.h"
#include "Effects/eel2/eelCommon.h"
#include "generalDSP/ArbFIRGen.h"
#define MAX_BENCHMARK (10)
// Misc
extern double mapVal(double x, double in_min, double in_max, double out_min, double out_max);
extern double mag2dB(double lin);
extern float db2magf(double dB);
extern double db2mag(double dB);
extern void linspace(double *x, int n, double a, double b);
extern void channel_joinFloat(float **chan_buffers, unsigned int num_channels, float *buffer, unsigned int num_frames);
extern void channel_join(double **chan_buffers, unsigned int num_channels, double *buffer, unsigned int num_frames);
extern void channel_split(double *buffer, unsigned int num_frames, double **chan_buffers, unsigned int num_channels);
extern void channel_splitFloat(float *buffer, unsigned int num_frames, float **chan_buffers, unsigned int num_channels);
extern void normalise(float *buffer, int num_samps);
extern unsigned int crc32c(const unsigned char *buf, size_t len);
extern int upper_bound(double *a, int n, double x);
extern int lower_bound(double *a, int n, double x);
extern size_t fast_upper_bound(double *a, size_t n, double x);
extern size_t fast_lower_bound(double *a, size_t n, double x);
extern void fhtsinHalfTblFloat(float *dst, unsigned int n);
extern void LLdiscreteHartleyFloat(float *A, const int nPoints, const float *sinTab);
extern double randXorshift(uint64_t s[2]);
// Misc end
typedef struct
{
	float threshold;
	float relCoef;
	float envOverThreshold;
} JLimiter;
#define FFTSIZE_DRS (8192)
#define ANALYSIS_OVERLAP_DRS_MAX (8)
#define HALFWNDLEN_DRS ((FFTSIZE_DRS >> 1) + 1)
/* 输出 FIFO 深度。每 hop(ovpLen) 产出一块，块长不整除 hop 时待读块数会在
 * 0..2 间摆动；旧值 2 恰好压在边界上（mOutputBufferCount++ 后立即按
 * count-1 取址，越界即堆写坏），且未给「启动缺额」留任何余量。
 * 4 是纯余量，不改变延迟（延迟只取决于缺额与 OLA 长度）。 */
#define MAX_OUTPUT_BUFFERS_DRS 4
#define NUMPTS_DRS (7)
#define DYN_BANDS_GAMMATONE (16)
#define MAXORDER (12)
#define MAXSECTIONS (MAXORDER >> 1)
// number of points of pre and post padding used to set initial conditions
#define PREPAD (200) // Max pad
#define POSPAD (200) // Max pad
typedef struct
{
	float real, imag;
} cplx;
typedef struct
{
	double real, imag;
} cplxDouble;
typedef struct str_dynfreqdomain
{
	// Frequency domain
	float analysisWnd[FFTSIZE_DRS];
	unsigned int fftLen, minus_fftLen, ovpLen, ovpCount, halfLen, smpShift, procUpTo;
	void(*fft)(float*, const float*);
	unsigned int mBitRev[FFTSIZE_DRS];
	float 	mSineTab[FFTSIZE_DRS >> 1];
	float synthesisWnd[FFTSIZE_DRS];
	// Shared variable between all FFT length and modes and channel config
	int  mOutputReadSampleOffset;
	int  mOutputBufferCount; // How many buffers are actually in use
	/* 启动缺额（样本，工作域）：首个处理块的块长决定，见
	 * CompressorStartupDeficit()。-1 = 尚未确定（Init 后待首次调用定）。 */
	int  mOutputDeficit;
	unsigned int mInputSamplesNeeded;
	float 	*mOutputBuffer[MAX_OUTPUT_BUFFERS_DRS];
	float buffer[MAX_OUTPUT_BUFFERS_DRS][FFTSIZE_DRS >> 1];
	unsigned int mInputPos;
	float 	mInput[2][FFTSIZE_DRS];
	float mOverlapStage2dash[2][ANALYSIS_OVERLAP_DRS_MAX][FFTSIZE_DRS >> 1];
	float 	mTempLBuffer[FFTSIZE_DRS];
	float 	mTempRBuffer[FFTSIZE_DRS];
	float timeDomainOut[2][FFTSIZE_DRS];
	float mag[HALFWNDLEN_DRS];
	float aheight[HALFWNDLEN_DRS];
	char noGridDownsampling;
	unsigned int smallGridSize;
	char octaveSmooth[sizeof(unsigned int) + sizeof(float) + sizeof(unsigned int) + ((HALFWNDLEN_DRS + 1) << 1) * sizeof(unsigned int) + (HALFWNDLEN_DRS + 1) * sizeof(float) + ((HALFWNDLEN_DRS + 1) + 3) * 2 * sizeof(float)];
	float finalGain[HALFWNDLEN_DRS];
	double freq2[NUMPTS_DRS + 2];
	float freq3[DYN_BANDS_GAMMATONE + 2];
	double gains2[NUMPTS_DRS + 2];
	float DREmultUniform[HALFWNDLEN_DRS];
	float DREmult[HALFWNDLEN_DRS];
	float oldBuf[HALFWNDLEN_DRS];
	ierper pch;
	float headRoomdB;
	float fgt_fac, fgt_facT;
	float spectralRate;
	// Time domain
	float bRe[DYN_BANDS_GAMMATONE];
	float aRe[DYN_BANDS_GAMMATONE];
	float aIm[DYN_BANDS_GAMMATONE];
	float Zre[DYN_BANDS_GAMMATONE * 2];
	float Zim[DYN_BANDS_GAMMATONE * 2];
	float gmtFreq[DYN_BANDS_GAMMATONE];
	float interpolatedGain[DYN_BANDS_GAMMATONE + 2];
	float diffGain[DYN_BANDS_GAMMATONE];
	float c1[(DYN_BANDS_GAMMATONE - 1)];
	float c2[(DYN_BANDS_GAMMATONE - 1)];
	float d0[(DYN_BANDS_GAMMATONE - 1)];
	float d1[(DYN_BANDS_GAMMATONE - 1)];
	float overallGain;
	float c1step[(DYN_BANDS_GAMMATONE - 1)];
	float c2step[(DYN_BANDS_GAMMATONE - 1)];
	float d0step[(DYN_BANDS_GAMMATONE - 1)];
	float d1step[(DYN_BANDS_GAMMATONE - 1)];
	float overallGainstep;
	float z1_AL[(DYN_BANDS_GAMMATONE - 1)];
	float z2_AL[(DYN_BANDS_GAMMATONE - 1)];
	float z1_AR[(DYN_BANDS_GAMMATONE - 1)];
	float z2_AR[(DYN_BANDS_GAMMATONE - 1)];
	double trigo[(DYN_BANDS_GAMMATONE - 1) * 4];
	unsigned int updatePerNSmps;
	float dsSm, alpha;
	int updateIdx;
	// Global variable
	int granularity, tfresolution;
	// CWT
	unsigned int reqSynthesisWnd;
	float gauss_c1[PREPAD + HALFWNDLEN_DRS + POSPAD - 1], gauss_c2[PREPAD + HALFWNDLEN_DRS + POSPAD - 1], gauss_b[PREPAD + HALFWNDLEN_DRS + POSPAD - 1];
	unsigned int prepad, pospad;
	unsigned int bitrevfftshift[FFTSIZE_DRS];
	float corrF[HALFWNDLEN_DRS];
	void (*process)(struct str_dynfreqdomain *);
	float shiftCentre[HALFWNDLEN_DRS];
	float scalarGain;
	float fftBuf[2][FFTSIZE_DRS], getbackCorrectedToSpectrum1[2][FFTSIZE_DRS];
	float real[2][HALFWNDLEN_DRS], imag[2][HALFWNDLEN_DRS];
	float specHannReal[2][PREPAD + HALFWNDLEN_DRS + POSPAD - 1], specHannImag[2][PREPAD + HALFWNDLEN_DRS + POSPAD - 1];
	cplx tmp[2][PREPAD + HALFWNDLEN_DRS + POSPAD - 1];
	int isMono; /* [PATCHED-AuraDSP P-034] 1=跳过通道 1 (Right) 的 FFT/CWT/STFT，节约 50% CPU */
} FFTCompander;
/* [PATCHED-AuraDSP P-018 B1-c] comp 影子槽（与 B1-a liveprog 影子 VM / B1-b ddc
 * 影子视图同范式）。原实现 `FFTCompander comp` 单体内嵌 + kAuraStages comp
 * lock=1：控制线程 CompressorSetParam(forceRefresh=1) 持 jdsp_lock 整体重置
 * compander（FFTCompanderInit 全量重算），RT 的 stage_comp 每块取同一把锁
 * ⇒ 重建期间音频整段卡死（Z13 只修了数据竞争，没修等待时长）。
 * 现改为：控制线程在非活动影子槽上全量拷贝 + 重建，成功后原子换
 * compActive 指针；RT 块首只读一次指针，块内不碰换出实例，stage lock 置 0。
 * [PATCHED-AuraDSP P-034] 槽数扩充为 9（8 活动槽 + 1 影子重建槽），支持 8 声道独立实例。
 * 在途守卫双条件（compInFlight==0 或 compProcCount>=retiredAt）覆盖排空，
 * 音频停流时 inFlight==0 立即可复用（不受 procCount 冻结影响）。
 * 每槽 pch.s 为构造时分配的私有插针数组（ierper 含堆指针，禁止跨槽别名）。 */
typedef struct
{
	FFTCompander cm;
	/* 本槽被换下时所期望的 compProcCount 下界（换下时刻快照 +1）。
	 * 复用本槽要求 compProcCount >= retiredAt（换下后跑满 1 块）或
	 * compInFlight == 0。0=从未当活动槽（立即可用）。 */
	uint64_t retiredAt;
} CompSlot;
#define AURA_COMP_CHANNELS 8
#define AURA_COMP_SLOTS (AURA_COMP_CHANNELS + 1)
typedef struct
{
	int needOversample;
	samplerateTool smp[2];
	SixBandsCrossover subband[2];
	float pregain, postgain;
	/* [PATCHED-AuraDSP P-011 2026-10-13] 电子管音色/混合/补偿。
	 * RT 只读、控制线程写（x86 对齐字读写无撕裂，与既有 pregain 同模式）。
	 * VTInit 不重置这 4 个字段（开关切换不丢用户值）；tapeLp 每次 Enable 清零。 */
	int character;    /* 0 Triode / 1 Pentode / 2 Tape */
	float drywet;     /* 湿比 0..1（0=干声直通，1=全湿=旧行为） */
	float outcomp;    /* 输出补偿 dB（只作用于湿信号） */
	float tapeLp[2];  /* Tape 档 HF 阻尼一阶状态 */
} VacuumTube;
typedef struct
{
	float inputs[1024];
	int inPoint;
	int outPoint;
	int allocateLen;
} integerDelayLine;
typedef struct
{
	int filterType;
	float gCoeff; // gain element 
	float RCoeff; // feedback damping element
	float KCoeff; // shelf gain element
	float precomputeCoeff1, precomputeCoeff2, precomputeCoeff3, precomputeCoeff4;
	float z1_A, z2_A; // state variables (z^-1)
} StateVariable2ndOrder;
typedef struct
{
	float maxGain;
	float originalBuf[960];
	int downsamplerPos;
	samplerateTool downsampler;
	float delayLine[16];
	float fftBuf[16];
	float smoothFFTBuffer[9];
	float freq[9];
	float maxSmoothingFactor, minusmaxSmoothingFactor;
	float smoothMaxFreq;
	float boostdB;
	double fs;
	float gainSmoothingFactor, minusgainSmoothingFactor;
	StateVariable2ndOrder svf[2];
	integerDelayLine dL[2];
} DBB;
//   sf_reverb_state_st rv;
//   sf_presetreverb(&rv, 44100, SF_REVERB_PRESET_DEFAULT);
//
//   for each abitrary length sample:
//   float outputL, outputR;
//   sf_reverb_process(&rv, inputL, inputR, &outputL, &outputR);
#define SF_REVERB_DS        3000
typedef struct
{
	int pos;                 // current write position
	int size;                // delay size
	float buf[SF_REVERB_DS]; // delay buffer
} sf_rv_delay_st;
// 1st order IIR filter
typedef struct
{
	float a2; // coefficients
	float b1;
	float b2;
	float y1; // state
} sf_rv_iir1_st;
// biquad
// note: we don't use biquad.c because we want to step through the sound one sample at a time, one
//       channel at a time
typedef struct
{
	float b0; // biquad coefficients
	float b1;
	float b2;
	float a1;
	float a2;
	float xn1; // input[n - 1]
	float xn2; // input[n - 2]
	float yn1; // output[n - 1]
	float yn2; // output[n - 2]
} sf_rv_biquad_st;
// early reflection
typedef struct
{
	int             delaytblL[18], delaytblR[18];
	sf_rv_delay_st  delayPWL, delayPWR;
	sf_rv_delay_st  delayRL, delayLR;
	sf_rv_biquad_st allpassXL, allpassXR;
	sf_rv_biquad_st allpassL, allpassR;
	sf_rv_iir1_st   lpfL, lpfR;
	sf_rv_iir1_st   hpfL, hpfR;
	float wet1, wet2;
} sf_rv_earlyref_st;
// oversampling
// maximum oversampling factor
#define SF_REVERB_OF        2
typedef struct
{
	int factor;           // oversampling factor [1 to SF_REVERB_OF]
	sf_rv_biquad_st lpfU; // lowpass filter used for upsampling
	sf_rv_biquad_st lpfD; // lowpass filter used for downsampling
} sf_rv_oversample_st;
// dc cut
typedef struct
{
	float gain;
	float y1;
	float y2;
} sf_rv_dccut_st;
// fractal noise cache
// noise buffer size; must be a power of 2 because it's generated via fractal generator
#define SF_REVERB_NS        (1<<11)
typedef struct
{
	int pos;                 // current read position in the buffer
	float buf[SF_REVERB_NS]; // buffer filled with noise
} sf_rv_noise_st;
// low-frequency oscilator (LFO)
typedef struct
{
	float re;  // real part
	float im;  // imaginary part
	float sn;  // sin of angle increment per sample
	float co;  // cos of angle increment per sample
	int count; // number of samples generated so far (used to apply small corrections over time)
} sf_rv_lfo_st;
// all-pass filter
// maximum size
#define SF_REVERB_APS       3400
typedef struct
{
	int pos;
	int size;
	float feedback;
	float decay;
	float buf[SF_REVERB_APS];
} sf_rv_allpass_st;
// 2nd order all-pass filter
// maximum sizes of the two buffers
#define SF_REVERB_AP2S1     4200
#define SF_REVERB_AP2S2     3000
typedef struct
{
	//    line 1                 line 2
	int   pos1, pos2;
	int   size1, size2;
	float feedback1, feedback2;
	float decay1, decay2;
	float buf1[SF_REVERB_AP2S1], buf2[SF_REVERB_AP2S2];
} sf_rv_allpass2_st;
// 3rd order all-pass filter with modulation
// maximum sizes of the three buffers and maximum mod size of the first line
#define SF_REVERB_AP3S1     4000
#define SF_REVERB_AP3M1     600
#define SF_REVERB_AP3S2     2000
#define SF_REVERB_AP3S3     3000
typedef struct
{
	//    line 1 (with modulation)                 line 2                 line 3
	int   rpos1, wpos1, pos2, pos3;
	int   size1, msize1, size2, size3;
	float feedback1, feedback2, feedback3;
	float decay1, decay2, decay3;
	float buf1[SF_REVERB_AP3S1 + SF_REVERB_AP3M1], buf2[SF_REVERB_AP3S2], buf3[SF_REVERB_AP3S3];
} sf_rv_allpass3_st;
// modulated all-pass filter
// maximum size and maximum mod size
#define SF_REVERB_APMS      3600
#define SF_REVERB_APMM      137
typedef struct
{
	int rpos, wpos;
	int size, msize;
	float feedback;
	float decay;
	float z1;
	float buf[SF_REVERB_APMS + SF_REVERB_APMM];
} sf_rv_allpassm_st;
// comb filter
// maximum size of the buffer
#define SF_REVERB_CS        1500
typedef struct
{
	int pos;
	int size;
	float buf[SF_REVERB_CS];
} sf_rv_comb_st;
//
// the final reverb state structure
//
// note: this struct is about 1Mb
typedef struct
{
	sf_rv_earlyref_st   earlyref;
	sf_rv_oversample_st oversampleL, oversampleR;
	sf_rv_dccut_st      dccutL, dccutR;
	sf_rv_noise_st      noise;
	sf_rv_lfo_st        lfo1;
	sf_rv_iir1_st       lfo1_lpf;
	sf_rv_allpassm_st   diffL[10], diffR[10];
	sf_rv_allpass_st    crossL[4], crossR[4];
	sf_rv_iir1_st       clpfL, clpfR; // cross LPF
	sf_rv_delay_st      cdelayL, cdelayR; // cross delay
	sf_rv_biquad_st     bassapL, bassapR; // bass all-pass
	sf_rv_biquad_st     basslpL, basslpR; // bass lowpass
	sf_rv_iir1_st       damplpL, damplpR; // dampening lowpass
	sf_rv_allpassm_st   dampap1L, dampap1R; // dampening all-pass (1)
	sf_rv_delay_st      dampdL, dampdR; // dampening delay
	sf_rv_allpassm_st   dampap2L, dampap2R; // dampening all-pass (2)
	sf_rv_delay_st      cbassd1L, cbassd1R; // cross-fade bass delay (1)
	sf_rv_allpass2_st   cbassap1L, cbassap1R; // cross-fade bass allpass (1)
	sf_rv_delay_st      cbassd2L, cbassd2R; // cross-fade bass delay (2)
	sf_rv_allpass3_st   cbassap2L, cbassap2R; // cross-fade bass allpass (2)
	sf_rv_lfo_st        lfo2;
	sf_rv_iir1_st       lfo2_lpf;
	sf_rv_comb_st       combL, combR;
	sf_rv_biquad_st     lastlpfL, lastlpfR;
	sf_rv_delay_st      lastdelayL, lastdelayR;
	sf_rv_delay_st      inpdelayL, inpdelayR;
	int outco[32];
	float loopdecay;
	float wet1, wet2;
	float wander;
	float bassb;
	float ertolate; // early reflection mix parameters
	float erefwet;
	float dry;
} sf_reverb_state_st;
typedef enum
{
	SF_REVERB_PRESET_DEFAULT,
	SF_REVERB_PRESET_SMALLHALL1,
	SF_REVERB_PRESET_SMALLHALL2,
	SF_REVERB_PRESET_MEDIUMHALL1,
	SF_REVERB_PRESET_MEDIUMHALL2,
	SF_REVERB_PRESET_LARGEHALL1,
	SF_REVERB_PRESET_LARGEHALL2,
	SF_REVERB_PRESET_SMALLROOM1,
	SF_REVERB_PRESET_SMALLROOM2,
	SF_REVERB_PRESET_MEDIUMROOM1,
	SF_REVERB_PRESET_MEDIUMROOM2,
	SF_REVERB_PRESET_LARGEROOM1,
	SF_REVERB_PRESET_LARGEROOM2,
	SF_REVERB_PRESET_MEDIUMER1,
	SF_REVERB_PRESET_MEDIUMER2,
	SF_REVERB_PRESET_PLATEHIGH,
	SF_REVERB_PRESET_PLATELOW,
	SF_REVERB_PRESET_LONGREVERB1,
	SF_REVERB_PRESET_LONGREVERB2
} sf_reverb_preset;
/* [PATCHED-AuraDSP P-033] 混响原生参数与影子槽定义 */
typedef struct {
    int   oversamplefactor;  /* 1..2 */
    float ertolate;          /* 0..1 早期反射湿比 */
    float erefwet_db;        /* dB */
    float dry_db;            /* dB */
    float ereffactor;        /* 0.5..2.5 早期反射房间倍数 */
    float erefwidth;         /* 0..1 */
    float width;             /* 0..1 */
    float wet_db;            /* dB */
    float wander;            /* 0..1 */
    float bassb;             /* 0..1 */
    float spin;              /* 0..10 */
    float inputlpf_hz;       /* Hz */
    float basslpf_hz;        /* Hz */
    float damplpf_hz;        /* Hz */
    float outputlpf_hz;      /* Hz */
    float rt60_s;            /* 0.1..30 */
    float delay_s;           /* 0..0.1 */
} AuraReverbNativeParams;

#define AURA_REVERB_SLOTS 2
typedef struct {
    sf_reverb_state_st rv;
    uint64_t retiredAt;
} ReverbSlot;

typedef struct
{
	char subband[2][getMemSizeWarpedPFB(5, 2)];
	float emaAlpha[5];
	float sumStates[5];
	float diffStates[5];
	float mix, minusMix, gain;
	/* [PATCHED-AuraDSP P-002 2026-10-09] 分带展宽：每子带独立 mix。
	 * bandMixUsed=0 时行为与上游完全一致（统一 mix）。 */
	float bandMix[5];
	char bandMixUsed;
} stereoEnhancement;
typedef struct
{
	NSEEL_VMCTX vm;
	NSEEL_CODEHANDLE codehandleInit, codehandleProcess;
	float *vmFs, *input1, *input2;
	/* [PATCHED-AuraDSP P-038] 宿主环境感知变量绑定与快照 */
	float *vmDevFs, *vmNumCh, *vmNch;
	float snapFs, snapDevFs;
	int snapNumCh;
	int compileSucessfully;
	/* [PATCHED-AuraDSP P-016 B1] 影子槽簿记：retiredAt = 本槽被换下时所期望的
	 * eelProcCount 下界（换下时刻快照 +1）。控制侧复用本槽前要求
	 * eelProcCount >= retiredAt，即换下后至少跑满 1 个音频块，
	 * 确保换出瞬间仍在途的那次 LiveProgProcess 已返回
	 * （与 P-006 mEQ 卷积器双缓冲同范式）。0=从未当活动槽（立即可用）。 */
	uint64_t retiredAt;
} LiveProg;
#define AURA_LIVEPROG_SLOTS 3
typedef struct
{
	double b0, b1, b2, a1, a2;
	double v1L, v2L, v1R, v2R; // State
} DirectForm2;
typedef struct
{
	char *oldFile;
} DDC;
/* [PATCHED-AuraDSP P-017 B1-b] DDC 影子视图：RT 块首读一次视图指针即得
 * {sosPointer, usedSOSCount} 一致对（原实现两字段分离写在 vdcFl 上，
 * 控制侧换指针与计数非原子，只能靠 jdsp_lock 互斥——而持锁方做文件
 * 解析可达数十毫秒，RT 整段阻塞）。视图随原子指针换入，旧视图由槽
 * 保留至在途守卫满足后复用（与 B1-a liveprog / P-006 mEQ 同范式）。 */
typedef struct
{
	DirectForm2 *sosPointer;
	int usedSOSCount;
	/* 换下时刻的 ddcProcCount 快照 +1；复用本槽要求
	 * ddcProcCount >= retiredAt（换下后跑满 1 块）或 ddcInFlight == 0。 */
	uint64_t retiredAt;
} DDCView;
#define AURA_DDC_SLOTS 3
/* Minimum/maximum cut frequency (Hz) */
/* bs2b_set_level_fcut() */
#define BS2B_MINFCUT 300
#define BS2B_MAXFCUT 2000
/* Minimum/maximum feed level (dB * 10 @ low frequencies) */
/* bs2b_set_level_feed() */
#define BS2B_MINFEED 10   /* 1 dB */
#define BS2B_MAXFEED 150  /* 15 dB */
/* Default crossfeed levels */
/* Sets a new coefficients by new crossfeed value.
 * level = ( ( uint32_t )fcut | ( ( uint32_t )feed << 16 ) )
 * where 'feed' is crossfeeding level at low frequencies (dB * 10)
 * and 'fcut' is cut frecuency (Hz)
 */
#define BS2B_DEFAULT_CLEVEL  ((unsigned int)700 | ((unsigned int)45 << 16))
#define BS2B_CMOY_CLEVEL     ((unsigned int)700 | ((unsigned int)60 << 16))
#define BS2B_JMEIER_CLEVEL   ((unsigned int)650 | ((unsigned int)95 << 16))
typedef struct str_t_bs2bd
{
	double a0_lo, b1_lo;         /* Lowpass IIR filter coefficients */
	double a0_hi, a1_hi, b1_hi;  /* Highboost IIR filter coefficients */
	double gain;                 /* Global gain against overloading */
	/* Buffer of last filtered sample: [0] 1-st channel, [1] 2-d channel */
	struct { double asis[2], lo[2], hi[2]; } lfs;
} t_bs2bdp;
/* Get flevel value that used in function BS2BInit */
int BS2BCalculateflevel(unsigned int fcut, unsigned int gain);
void BS2BInit(t_bs2bdp *bs2bdp, unsigned int samplerate, int flevel);
/* sample poits to double floats native endians */
void BS2BProcess(t_bs2bdp *bs2bdp, double *sampleL, double *sampleR);
typedef struct
{
	int mode; // 0: BS2B Lv 1, 1: BS2B Lv 2, 2: HRTF crossfeed, 2: HRTF surround 1, 2: HRTF surround 2, 2: HRTF surround 3
	t_bs2bdp bs2b[2];
	FFTConvolver2x4x2 *conv[3];
	TwoStageFFTConvolver2x4x2 *convLong_T_S;
	FFTConvolver2x4x2 *convLong_S_S;
	void(*process)(struct dspsys *, size_t);
} Crossfeed;
typedef struct dspsys dspsys;
typedef struct
{
	FFTConvolver2x2 *conv1d2x2_S_S;
	TwoStageFFTConvolver2x2 *conv1d2x2_T_S;
	FFTConvolver2x4x2 *conv1d2x4x2_S_S;
	TwoStageFFTConvolver2x4x2 *conv1d2x4x2_T_S;
	void(*process)(struct dspsys*, size_t);
} Convolver1D;
typedef struct
{
	ArbitraryEq coeffGen;
	unsigned int filterLen;
	FFTConvolver2x2 convState;
} ArbEqConv;
#define NUMPTS 15
typedef struct
{
	// FIR
	int currentInterpolationMode, operatingMode;
	ierper pch1, pch2;
	ArbEqConv instance;
	FFTConvolver2x2 conv;
	/* P-006：卷积器双缓冲。控制线程在非活动实例上重建 IR，块边界原子换指针，
	 * 避免「边 FFTConvolver2x2Process 边 RefreshImpulseResponse」改写同一对象。
	 * 两个实例都内嵌于 mEQ、由析构统一释放，不存在跨线程释放。
	 * convProcCount 由音频线程递增；convSwapProc 为上次换出时的快照，
	 * 换出后需再跑满 1 块才允许把该实例重新投入重建，防止与在途调用竞争。*/
	FFTConvolver2x2 convB;
	FFTConvolver2x2 *activeConv;
	volatile long convProcCount;
	volatile long convSwapProc;
	double freq[NUMPTS + 2];
	double gain[NUMPTS + 2];
	// IIR
	int order, nSec;
	float c1[(NUMPTS - 1) * MAXSECTIONS];
	float c2[(NUMPTS - 1) * MAXSECTIONS];
	float d0[(NUMPTS - 1) * MAXSECTIONS];
	float d1[(NUMPTS - 1) * MAXSECTIONS];
	float z1_AL[(NUMPTS - 1) * MAXSECTIONS];
	float z2_AL[(NUMPTS - 1) * MAXSECTIONS];
	float z1_AR[(NUMPTS - 1) * MAXSECTIONS];
	float z2_AR[(NUMPTS - 1) * MAXSECTIONS];
	float overallGain;
	char sec[NUMPTS - 1];
} MultimodalEQ;
extern unsigned int HSHOSVF(double fs, double fc, unsigned int filterOrder, double gain, double overallGainDb, float *c1, float *c2, float *d0, float *d1, float *overallGain);
typedef struct
{
	ArbEqConv instance;
	FFTConvolver2x2 conv;
} arbitraryMagnitude;
typedef struct
{
	float *impulseResponse;
	unsigned int impChannels, impulseLengthActual;
} tmpIRData;
/* [PATCHED-AuraDSP P-020 B4] 调用级 stage 门控覆盖。
 *
 * 背景：多声道链 Category B 段原先在 RT 内 save→写 0→restore 五个 vendor
 * 开关（tubeEnabled/limiterEnabled/compEnabled/equalizerEnabled/
 * arbitraryMagEnabled）。这些字段由控制线程（VacuumTubeEnable/Disable、
 * CompressorEnable/Disable、MultimodalEQEnable、ArbitraryResponseEqualizer…）
 * 随时改写——用户操作落在 save 与 restore 之间就会被 restore 静默回滚
 * （界面显示开着、实际关了），即 lost update；且这些字段本身非原子。
 *
 * 现在把「本次调用怎么算」作为参数传入：NULL = 全部沿用 jdsp 全局开关
 * （既有行为零变化）；非 NULL 时逐字段生效，-1 = 该字段仍用全局开关。
 * RT 绝不写全局开关字段。 */
typedef struct
{
	signed char tube, comp, bass, eq, arbmag, limiter;
} AuraStageGates;
/* [PATCHED-AuraDSP P-004 2026-10-09] 表驱动处理链：顺序由宿主经
 * JamesDSPRebuildChain 重建（graph.order）。stage fn 内含各自 enabled 判断；
 * lock=1 的段（convolver/ddc/liveprog）逐段加解锁——与上游"三段连续一次
 * 加解锁"相比锁粒度更细（竞态窗口变化，数值输出等价）。
 * [PATCHED-AuraDSP P-020 B4] fn 增 gates 参数（调用级门控，见上）。 */
typedef void (*JDSPStageFn)(struct dspsys *jdsp, size_t n, const AuraStageGates *gates);
typedef struct
{
	JDSPStageFn fn;
	char lock;
	unsigned char stageIdx; /* [PATCHED-AuraDSP P-023 M3.5-c] 0..11 对应固定 stage ID */
} JDSPChainItem;
typedef struct dspsys
{
	// Sys var
	char enableASRC;
	IntegerASRCHandler asrc[2];
	float trueSampleRate, fs;
	int numChannels; /* [PATCHED-AuraDSP P-038] 当前驱动层/交织通道数 */
	// Effect
	// Compressor
	int compEnabled, compForceRefresh;
	/* [PATCHED-AuraDSP P-018 B1-c] comp 影子槽（替代原单体内嵌 FFTCompander comp）：
	 * RT 块首读一次 compActive 即得一致快照（x86-64 对齐指针存/取即原子，
	 * 数据依赖保证读取顺序）；控制线程在非活动槽 compSlots[] 上全量拷贝 +
	 * 重建后原子换指针。compProcCount 由 RT 每块递增（CompressorProcess
	 * 入口，单写者，与 compEnabled 无关——停用期间块边界也要放行影子槽
	 * 复用）；compSwapProc 记录换指针后观察到的快照（诊断/断言用）；
	 * compInFlight 入口原子 +1、出口 -1，控制侧读到的 0 严谨证明无任何
	 * 在途调用持有旧快照（x86 TSO + lock 前缀全屏障）。stage_comp 的
	 * lock 标志已置 0。 */
	CompSlot compSlots[AURA_COMP_SLOTS];
	/* [PATCHED-AuraDSP P-034] 8 声道独立活动实例指针 */
	FFTCompander *compActive[AURA_COMP_CHANNELS];
	uint64_t compProcCount, compSwapProc;
	long compInFlight;
	float comp_gr; /* [PATCHED-AuraDSP P-025 P2.4] 实时压缩增益衰减分贝 (dB >= 0) */
	// Bass boost
	int bassBoostEnabled;
	DBB dbb;
	// Equalizer
	int equalizerEnabled, equalizerForceRefresh;
	MultimodalEQ mEQ;
	// Reverb
	int reverbEnabled;
	/* [PATCHED-AuraDSP P-033] 双影子槽：RT 块首只读 reverbActive 一致指针，
	 * 控制线程在非活动槽构建后原子换入，无锁无竞争。 */
	sf_reverb_state_st *reverbActive;
	ReverbSlot reverbSlots[AURA_REVERB_SLOTS];
	uint64_t reverbProcCount, reverbSwapProc;
	long reverbInFlight;
	// Stereo enhancement
	int sterEnhEnabled;
	stereoEnhancement sterEnh;
	// Vacuum tube
	int tubeEnabled;
	VacuumTube tube;
	// Crossfeed
	int crossfeedEnabled, crossfeedForceRefresh;
	Crossfeed advXF;
	// DDC
	int ddcEnabled, ddcForceRefresh;
	/* [PATCHED-AuraDSP P-005 2026-10-10] 卷积干湿比：宿主在 JamesDSPInit 后
	 * 提供 scratch（≥ blockSizeMax*2 floats），并在启用干湿时置 mixUsed=1。
	 * mixUsed=0 时 stage_conv 走上游原路径（零行为变化）。 */
	float *auraConvScratch;
	float auraConvWet, auraConvDry;
	char auraConvMixUsed;
	/* B1-b：RT 只读 ddcActive 视图指针（块首一次，x86-64 对齐指针存即
	 * 原子）；控制侧在影子槽上构建新 SOS 数组后原子换指针，旧视图由槽
	 * 保留至在途守卫满足后复用。ddcProcCount 由 RT 每块递增（DDCProcess
	 * 入口，单写者）；ddcInFlight 入口 +1/出口 -1（原子）。stage_ddc 的
	 * lock 标志已置 0。vdcFl 仅剩 oldFile（控制侧去重簿记，RT 不碰）。 */
	DDCView *ddcActive;
	DDCView ddcSlots[AURA_DDC_SLOTS];
	uint64_t ddcProcCount;
	long ddcInFlight;
	DDC vdcFl;
	// Convolver
	int convolverEnabled;
	Convolver1D conv;
	// Live programmable effect
	int liveprogEnabled;
	/* [PATCHED-AuraDSP P-016 B1] 影子 VM 编译：RT 只读 eel 指针（块首一次，
	 * x86-64 对齐指针存/取即原子）；EEL 编译在影子槽 eelSlots[] 上进行，
	 * 成功后原子换指针，RT 不再需要为 liveprog 持 jdsp_lock
	 * （stage_liveprog 的 lock 标志已置 0）。eelProcCount 由 RT 每块
	 * 递增（单写者，LiveProgProcess 入口），eelSwapProc 记录换指针时刻
	 * 快照（诊断/断言用）。 */
	LiveProg *eel;
	LiveProg eelSlots[AURA_LIVEPROG_SLOTS];
	uint64_t eelProcCount, eelSwapProc;
	/* B1：RT 在途计数器——LiveProgProcess 入口原子 +1、出口 -1（单 RT
	 * 线程时取值 0/1）。控制侧读到的 0 证明无任何在途调用持有旧快照
	 * （x86 TSO + lock 前缀全屏障下严谨），音频停流时据此立即可复用
	 * 换下的槽，不受 eelProcCount 冻结影响；eelProcCount 守卫则覆盖
	 * 「RT 在跑但块边界未过」的窗口。 */
	long eelInFlight;
	// Arbitrary magnitude response
	int arbitraryMagEnabled, arbMagForceRefresh;
	arbitraryMagnitude arbMag;
	// Output limiter
	float postGain;
	float postGainCh[2]; /* [PATCHED-AuraDSP P-037] stereo/matrix/binaural 逐声道补偿 */
	JLimiter limiter;
	int limiterEnabled; /* [PATCHED-AuraDSP P-012] limiter.enable 总开关（默认 1，关时只做 postGain） */
	size_t blockSize, blockSizeMax, pw2BlockMemSize;
	float *tmpBuffer[6];
	// Internal function pointer
	void(*processInternal)(struct dspsys *, size_t);
	/* [PATCHED-AuraDSP P-004 / M3.5-c] */
	JDSPChainItem chain[16];
	int chainLen;
	float stagePeakL[16];
	float stagePeakR[16];
	/* [PATCHED-AuraDSP P-010] 每效果输出增益门 + 自动增益补偿（leveler）。
	 * fx 索引：0=tube 1=comp 2=bass 3=eq 4=arbmag。
	 * [PATCHED-AuraDSP P-033] WP1 扩展 fx=5=reverb：Freeverb 退役后
	 * `reverb.outgain/autogain` 落到 vendor stage_reverb（原生参数仍属 WP2）。
	 * fxOutGain 线性增益（控制线程写，RT 读，x86 对齐 float 原子）；
	 * fxAutoGain 开关；fxAGIn/Out/Comp 为 RT 独占的平滑 RMS 与补偿增益。 */
	float fxOutGain[6];
	int   fxAutoGain[6];
	float fxAGIn[6], fxAGOut[6], fxAGComp[6];
	int32_t(*i32_from_p24)(const uint8_t *);
	void (*p24_from_i32)(int32_t, uint8_t *);
	// I/O function pointer
	void(*processInt16Deinterleaved)(struct dspsys*, int16_t*, int16_t*, int16_t*, int16_t*, size_t);
	void(*processInt32Deinterleaved)(struct dspsys*, int32_t*, int32_t*, int32_t*, int32_t*, size_t);
	void(*processInt8_24Deinterleaved)(struct dspsys *, int32_t*, int32_t*, int32_t*, int32_t*, size_t);
	void(*processInt24PackedDeinterleaved)(struct dspsys *, uint8_t*, uint8_t*, uint8_t*, uint8_t*, size_t);
	void(*processFloatDeinterleaved)(struct dspsys*, float*, float*, float*, float*, size_t);
	void(*processInt16Multiplexd)(struct dspsys*, int16_t*, int16_t*, size_t);
	void(*processInt32Multiplexd)(struct dspsys*, int32_t*, int32_t*, size_t);
	void(*processInt8_24Multiplexd)(struct dspsys*, int32_t*, int32_t*, size_t);
	void(*processInt24PackedMultiplexd)(struct dspsys*, uint8_t*, uint8_t*, size_t);
	void(*processFloatMultiplexd)(struct dspsys*, float*, float*, size_t);
	// Blobs(resampled)
	int blobsResampledLen;
	float *blobsCh1[3];
	float *blobsCh2[3];
	float *blobsCh3[3];
	float *blobsCh4[3];
	int frameLenSVirResampled;
	float *hrtfblobsResampled[4];
	tmpIRData impulseResponseStorage;
	// Mutex lock(pthread)
	int isMutexSuccess;
	pthread_mutex_t m_in_processing;
	// Random number and related
	uint64_t rndstate[2];
} JamesDSPLib;
// JamesDSP controller
extern void JamesDSPGlobalMemoryAllocation();
extern void JamesDSPGlobalMemoryDeallocation();
extern void JamesDSPReallocateBlock(JamesDSPLib *jdsp, size_t blockSizeMax);
extern void JamesDSP_Load_benchmark(double *_c0, double *_c1);
extern void JamesDSP_Save_benchmark(double *_c0, double *_c1);
extern void JamesDSP_Start_benchmark();
extern void jdsp_lock(JamesDSPLib *jdsp);
extern void jdsp_unlock(JamesDSPLib *jdsp);
extern void JamesDSPFree(JamesDSPLib *jdsp);
 extern void JamesDSPInit(JamesDSPLib *jdsp, int blockSizeMax, float sample_rate);
 extern void JamesDSPSetPostGain(JamesDSPLib *jdsp, double pGaindB);
 extern void JamesDSPSetPostGainCh(JamesDSPLib *jdsp, int ch, double pGaindB); /* [PATCHED-AuraDSP P-037] */
 /* [PATCHED-AuraDSP P-010] 每效果输出增益门 + 自动补偿（0=tube 1=comp 2=bass 3=eq 4=arbmag） */
 extern void JamesDSPSetFxOutGain(JamesDSPLib *jdsp, int fx, double linGain);
 extern void JamesDSPSetFxAutoGain(JamesDSPLib *jdsp, int fx, int on);
 extern void JamesDSPInitFxGains(JamesDSPLib *jdsp);
extern int JamesDSPGetMutexStatus(JamesDSPLib *jdsp);
extern void JamesDSPSetSampleRate(JamesDSPLib *jdsp, float new_sample_rate, int forceRefresh);
extern int selectConvPartitions(JamesDSPLib *jdsp, unsigned int impulseLengthActual, unsigned int *seg2Len);
// Limiter
extern void JLimiterSetCoefficients(JamesDSPLib *jdsp, double thresholddB, double msRelease);
extern void JLimiterInit(JamesDSPLib *jdsp);
// Compressor
extern void CompressorConstructor(JamesDSPLib *jdsp);
extern void CompressorDestructor(JamesDSPLib *jdsp);
extern void CompressorSetParam(JamesDSPLib *jdsp, float fgt_facT, int granularity, int tfresolution, char forceRefresh);
extern void CompressorSetGain(JamesDSPLib *jdsp, double *freq, double *gains, char cpy);
extern void CompressorEnable(JamesDSPLib *jdsp, char enable);
extern void CompressorDisable(JamesDSPLib *jdsp);
/* [PATCHED-AuraDSP P-020 B4] enabled 由调用方决定（stage_comp 传入本次调用的门控值，
 * 使 RT 无需改写 jdsp->compEnabled）；旧签名 CompressorProcess(jdsp,n) 由
 * stage_comp 内部等价实现（读全局 compEnabled）。 */
extern void CompressorProcess(JamesDSPLib *jdsp, size_t n, int enabled);
/* [PATCHED-AuraDSP P-034] 单声道逐通道独立压缩处理与块生命周期 */
extern void CompressorProcessBlockStart(JamesDSPLib *jdsp);
extern void CompressorProcessBlockEnd(JamesDSPLib *jdsp);
extern void CompressorProcessChannel(JamesDSPLib *jdsp, int ch, const float *in, float *out, size_t n, int enabled);
/* [PATCHED-AuraDSP P-019 B1-d] comp 启动缺额（工作域样本数）。
 *
 * FFTCompander 每 hop(ovpLen) 才产出一块输出，而每次调用至少要写回 n 个
 * 输出样本（调用方原地处理）。块长 n 与 hop 不整除时，「已产出 - 已交付」
 * 必然要永久落后一个相位量，否则管线会在部分调用上取不到输出——旧实现在
 * 这种情况下把**未处理的输入原样留在输出里**（原声直通，与延迟后的处理流
 * 叠加成双声/梳状），并把整条流永久错位。
 *
 * 缺额 = ovpLen - gcd(ovpLen, blockLen)，blockLen = **完整工作域块长**（不是裁到
 * hop 后的块）。启动时先以静音吐出这 D 个样本（它们对应的正是 OLA 爬升段，
 * 本来就是静音），此后「可用输出 = D + ovpLen*floor(I/ovpLen) - I
 * = D - (I mod ovpLen) >= 0」恒成立，任何块长都不再饥饿、不再直通。代价是
 * 块长不整除 hop 时延迟多 D 帧（≤ ovpLen-1），这个量必须计入上报延迟，
 * 否则又是"报得比听得少"。 */
extern unsigned int CompressorStartupDeficit(unsigned int ovpLen, unsigned int blockLen);
/* [PATCHED-AuraDSP P-018 B1-c] 影子构建 + 原子换指针一体化提交（RT 零锁等待）。
 * 参数：新 compander 参数（fgt_facT/granularity/tfresolution，变化或
 * forceRefresh 时触发 FFTCompanderInit 全量重算）；freq/gains/cpy 非空且
 * cpy=1 时复制新增益曲线；applyCurve=1 时重算 pchip/DREmult 曲线。
 * 返回 1=已换入活动视图；<0=失败（-4 引擎忙：500ms 墙钟内无可用影子槽或
 * 活动快照始终被 RT 占用，旧快照继续生效，不静音不退化）。 */
extern int CompressorCommit(JamesDSPLib *jdsp, float fgt_facT, int granularity,
                            int tfresolution, char forceRefresh,
                            const double *freq, const double *gains,
                            char cpy, char applyCurve);
// Bass boost
extern void BassBoostEnable(JamesDSPLib *jdsp);
extern void BassBoostDisable(JamesDSPLib *jdsp);
extern void BassBoostConstructor(JamesDSPLib *jdsp);
extern void BassBoostSetParam(JamesDSPLib *jdsp, float maxG);
extern void BassBoostProcess(JamesDSPLib *jdsp, size_t n);
// Reverb
extern void ReverbConstructor(JamesDSPLib *jdsp);
extern void ReverbDestructor(JamesDSPLib *jdsp);
extern void Reverb_SetParam(JamesDSPLib *jdsp, int presets);
extern void Reverb_SetNative(JamesDSPLib *jdsp, const AuraReverbNativeParams *p);
extern void ReverbEnable(JamesDSPLib *jdsp);
extern void ReverbDisable(JamesDSPLib *jdsp);
extern void ReverbProcess(JamesDSPLib *jdsp, size_t n);
// Stereo enhancement
extern void StereoEnhancementDestructor(JamesDSPLib *jdsp);
extern void StereoEnhancementConstructor(JamesDSPLib *jdsp);
extern void StereoEnhancementRefresh(JamesDSPLib *jdsp);
extern void StereoEnhancementSetParam(JamesDSPLib *jdsp, float mix);
extern void StereoEnhancementSetBandMix(JamesDSPLib *jdsp, int band, float mix); /* [PATCHED-AuraDSP P-002] */
extern void StereoEnhancementUseUnifiedMix(JamesDSPLib *jdsp); /* [PATCHED-AuraDSP P-002] */
extern void StereoEnhancementEnable(JamesDSPLib *jdsp);
extern void StereoEnhancementDisable(JamesDSPLib *jdsp);
extern void StereoEnhancementProcess(JamesDSPLib *jdsp, size_t n);
// Vacuum tube
extern void VacuumTubeEnable(JamesDSPLib *jdsp);
extern void VacuumTubeDisable(JamesDSPLib *jdsp);
extern void VacuumTubeSetGain(JamesDSPLib *jdsp, double dbGain);
extern void VacuumTubeSetCharacter(JamesDSPLib *jdsp, int character); /* [PATCHED-AuraDSP P-011 2026-10-13] */
extern void VacuumTubeSetDryWet(JamesDSPLib *jdsp, float mix); /* [PATCHED-AuraDSP P-011 2026-10-13] */
extern void VacuumTubeSetOutComp(JamesDSPLib *jdsp, double db); /* [PATCHED-AuraDSP P-011 2026-10-13] */
extern void VacuumTubeProcess(JamesDSPLib *jdsp, size_t n);
// Live programmable effect
extern const char* checkErrorCode(int errCode);
extern void LiveProgConstructor(JamesDSPLib *jdsp);
extern void LiveProgDestructor(JamesDSPLib *jdsp);
extern int LiveProgStringParser(JamesDSPLib *jdsp, char *eelCode);
extern void LiveProgEnable(JamesDSPLib *jdsp);
extern void LiveProgDisable(JamesDSPLib *jdsp);
extern void LiveProgUnload(JamesDSPLib *jdsp);
extern void LiveProgProcess(JamesDSPLib *jdsp, size_t n);
extern void LiveProgSetChannels(JamesDSPLib *jdsp, int channels); /* [PATCHED-AuraDSP P-038] */
// DDC
extern void DDCConstructor(JamesDSPLib *jdsp);
extern void DDCDestructor(JamesDSPLib *jdsp);
extern int DDCEnable(JamesDSPLib *jdsp, char enable);
extern void DDCDisable(JamesDSPLib *jdsp);
extern int DDCStringParser(JamesDSPLib *jdsp, char *newStr);
extern void DDCProcess(JamesDSPLib *jdsp, size_t n);
// Crossfeed
extern void CrossfeedConstructor(JamesDSPLib *jdsp);
extern void CrossfeedDestructor(JamesDSPLib *jdsp);
extern void CrossfeedEnable(JamesDSPLib *jdsp, char enable);
extern void CrossfeedDisable(JamesDSPLib *jdsp);
extern void CrossfeedChangeMode(JamesDSPLib *jdsp, int nMode);
extern void CrossfeedProcess(JamesDSPLib *jdsp, size_t n);
// Convolver
extern void Convolver1DEnable(JamesDSPLib *jdsp);
extern int JamesDSPRebuildChain(JamesDSPLib *jdsp, const char *ids); /* [PATCHED-AuraDSP P-004] */
/* [PATCHED-AuraDSP P-021 B5] 多声道声道对选择：仅跑 ids 逗号表指定的阶段子集（默认顺序）。
 * 镜像 processFloatMultiplexd 的块长/ASRC/交织处理；x 与 y 可为同一缓冲。
 * samplePeaks：镜像 processInternal 的逐 stage 峰值采样（viz stage_levels 用；
 * 拆链两段时开，3b 额外对段保持 false 维持现有语义）。
 * gates：调用级门控覆盖（B4）；NULL = 全部沿用 jdsp 全局开关。 */
extern void JamesDSPProcessMultiplexedStageSet(JamesDSPLib *jdsp, float *x, float *y,
                                               size_t n, const char *ids, char samplePeaks,
                                               const AuraStageGates *gates);
/* 把上层（App）下发的全量效果器 id 列表过滤成 vendor 认识的 12 个 stage id：
 * 保序、去重、丢弃未知 id（自研 stage 由引擎自己的链处理，不归 vendor 管），
 * 并确保 output 在末尾。out 至少需 512 字节。返回写入的字节数（不含 NUL）。 */
extern int JamesDSPFilterVendorOrder(const char *in, char *out, int out_size);
extern void Convolver1DDisable(JamesDSPLib *jdsp);
extern void Convolver1DConstructor(JamesDSPLib *jdsp);
extern void Convolver1DDestructor(JamesDSPLib *jdsp);
extern int Convolver1DLoadImpulseResponse(JamesDSPLib *jdsp, float *tempImpulseFloat, unsigned int impChannels, size_t impulseLengthActual, char updateOld);
// Arbitrary magnitude response
extern void ArbitraryResponseEqualizerConstructor(JamesDSPLib *jdsp);
extern void ArbitraryResponseEqualizerDestructor(JamesDSPLib *jdsp);
extern void ArbitraryResponseEqualizerStringParser(JamesDSPLib *jdsp, char *stringEq);
extern void ArbitraryResponseEqualizerEnable(JamesDSPLib *jdsp, char enable);
extern void ArbitraryResponseEqualizerDisable(JamesDSPLib *jdsp);
extern void ArbitraryResponseEqualizerProcess(JamesDSPLib *jdsp, size_t n);
// FIR Equalizer
extern void MultimodalEqualizerConstructor(JamesDSPLib *jdsp);
extern void MultimodalEqualizerDestructor(JamesDSPLib *jdsp);
extern void MultimodalEqualizerAxisInterpolation(JamesDSPLib *jdsp, int interpolationMode, int operatingMode, double *freqAx, double *gaindB);
extern void MultimodalEqualizerEnable(JamesDSPLib *jdsp, char enable);
extern void MultimodalEqualizerDisable(JamesDSPLib *jdsp);
extern void MultimodalEqualizerProcess(JamesDSPLib *jdsp, size_t n);
#endif
