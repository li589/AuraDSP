#ifndef __SRC_H__
#define __SRC_H__
/* [PATCHED-AuraDSP P-060] Bound min-phase FHT workspace by phase count. */
#define AURADSP_ASRC_MINPHASE_MAX_PHASES 256u
#ifdef __cplusplus
extern "C" {
#endif
	typedef struct
	{
		float* pfb;
		unsigned int num_phases;
		unsigned int taps_per_phase;
		unsigned int interpolation;
		unsigned int decimation;
		unsigned int phase_index;
		unsigned int input_deficit;
		float* history;
		unsigned int history_length;
		unsigned int phase_index_step;
	} SRCResampler;
	int psrc_is_valid(const SRCResampler* filter);
	int psrc_generate(SRCResampler* filter, unsigned int interpolation, unsigned int decimation, int tap, double cutoff_freq, char minphase);
	int psrc_clone(SRCResampler* filterDest, SRCResampler* filterSrc);
	unsigned int psrc_filt(SRCResampler* filter, float *x, unsigned int count, float *y);
	unsigned int psrc_filt_stereo(SRCResampler *filter[2], float *x1, float *x2, unsigned int count, float *y1, float *y2);
	void psrc_free(SRCResampler* filter);
#ifdef __cplusplus
}
#endif
#endif