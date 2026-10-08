/* spike_eq.c — M0 Spike: minimal global-mix effect (peaking EQ @1kHz +12dB)
 * Implements legacy audio_effect_library_t (API 2.0), self-contained defs
 * (NDK r30 no longer ships hardware/audio_effect.h).
 * Loads into audioserver via /odm/etc/audio_effects_config.xml registration.
 * DANGEROUS: a crash here kills audioserver (auto-restarts by init). */
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <math.h>
#include <errno.h>
#include <android/log.h>

#define LOG_TAG "SpikeEQ"
#define ALOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define ALOGW(...) __android_log_print(ANDROID_LOG_WARN, LOG_TAG, __VA_ARGS__)

/* ---- AOSP effect definitions (subset of hardware/audio_effect.h) ---- */
typedef struct effect_uuid_s {
    uint32_t timeLow; uint16_t timeMid; uint16_t timeHiAndVersion;
    uint8_t clockSeq[2]; uint8_t node[6];
} effect_uuid_t;
typedef struct effect_interface_s *effect_handle_t;
typedef struct audio_buffer_s {
    size_t frameCount;
    union { void *raw; int16_t *s16; int32_t *s32; float *f32; };
} audio_buffer_t;

#define AUDIO_EFFECT_LIBRARY_TAG        0x46454C41u
#define EFFECT_LIBRARY_API_VERSION      0x020000u
#define EFFECT_CONTROL_API_VERSION      0x020000u
#define AUDIO_EFFECT_LIBRARY_INFO_SYM   AELI

/* flags: insert + insert-first + device-ind (matches OplusAudioX 0x208) */
#define SPIKE_FLAGS 0x00000208u

enum {
    EFFECT_CMD_INIT = 0, EFFECT_CMD_SET_CONFIG, EFFECT_CMD_RESET,
    EFFECT_CMD_ENABLE, EFFECT_CMD_DISABLE, EFFECT_CMD_SET_PARAM,
    EFFECT_CMD_SET_PARAM_DEFERRED, EFFECT_CMD_SET_PARAM_COMMIT,
    EFFECT_CMD_GET_PARAM, EFFECT_CMD_SET_DEVICE, EFFECT_CMD_SET_VOLUME,
    EFFECT_CMD_OFFLOAD, EFFECT_CMD_DUMP, EFFECT_CMD_SET_AUDIO_MODE,
    EFFECT_CMD_FIRST_PROPAGATED = 0x10000,
    EFFECT_CMD_SET_AUDIO_SOURCE, EFFECT_CMD_SET_INPUT_DEVICE, EFFECT_CMD_GET_CONFIG
};
enum { AUDIO_FORMAT_PCM_16_BIT = 1, AUDIO_FORMAT_PCM_FLOAT = 5 };

typedef struct buffer_config_s {
    uint32_t samplingRate; uint32_t channels; int32_t format;
    uint8_t accessMode; uint16_t masks;
} buffer_config_t;

typedef struct effect_descriptor_s {
    effect_uuid_t type; effect_uuid_t uuid;
    uint32_t apiVersion; uint32_t flags;
    uint16_t cpuLoad; uint16_t memoryUsage;
    char name[64]; char implementor[64];
} effect_descriptor_t;

struct effect_interface_s {
    int32_t (*process)(effect_handle_t, audio_buffer_t *, audio_buffer_t *);
    int32_t (*process_reverse)(effect_handle_t, audio_buffer_t *, audio_buffer_t *);
    int32_t (*command)(effect_handle_t, uint32_t, uint32_t, void *, uint32_t *, void *);
    int32_t (*get_descriptor)(effect_handle_t, effect_descriptor_t *);
};

typedef struct audio_effect_library_s {
    uint32_t tag; uint32_t version;
    const char *name; const char *implementor;
    int32_t (*create_effect)(const effect_uuid_t *, int32_t, int32_t, effect_handle_t *);
    int32_t (*release_effect)(effect_handle_t);
    int32_t (*get_descriptor)(const effect_uuid_t *, effect_descriptor_t *);
} audio_effect_library_t;

/* ---- UUIDs ---- */
static const effect_uuid_t kTypeEq =    {0x0bed4300u, 0xddd6, 0x11db, {0x8f,0x34}, {0x00,0x02,0xa5,0xd5,0xc5,0x1b}};
static const effect_uuid_t kImplUuid =  {0x8e73f7a1u, 0x3c92, 0x4f6b, {0x9d,0x5e}, {0x7a,0x1b,0x2c,0x3d,0x4e,0x5f}};
static const effect_descriptor_t kDesc = {
    kTypeEq, kImplUuid, EFFECT_CONTROL_API_VERSION, SPIKE_FLAGS,
    10, 100, "SpikeEQ", "JamesDSP Rebuild (M0 spike)"
};

/* ---- effect instance ---- */
typedef struct spike_ctx_s {
    const struct effect_interface_s *itfe;   /* MUST be first (vtable pointer) */
    const effect_descriptor_t *desc;
    buffer_config_t cfg;
    int enabled;
    float b0, b1, b2, a1, a2;           /* biquad coefficients */
    float x1[8], x2[8], y1[8], y2[8];   /* per-channel state */
    int nch;
} spike_ctx_t;

static int popcount(uint32_t v) { int n = 0; while (v) { n += v & 1; v >>= 1; } return n; }

static void design_eq(spike_ctx_t *c) {
    /* RBJ peaking EQ: f0=1000Hz, Q=1.0, gain=+12dB */
    const double A = pow(10.0, 12.0 / 40.0);
    const double w0 = 2.0 * M_PI * 1000.0 / (double)(c->cfg.samplingRate ? c->cfg.samplingRate : 48000);
    const double alpha = sin(w0) / (2.0 * 1.0);
    const double a0 = 1.0 + alpha / A;
    c->b0 = (float)((1.0 + alpha * A) / a0);
    c->b1 = (float)((-2.0 * cos(w0)) / a0);
    c->b2 = (float)((1.0 - alpha * A) / a0);
    c->a1 = (float)((-2.0 * cos(w0)) / a0);
    c->a2 = (float)((1.0 - alpha / A) / a0);
}

static int32_t spike_process(effect_handle_t self, audio_buffer_t *in, audio_buffer_t *out) {
    spike_ctx_t *c = (spike_ctx_t *)self;
    if (!c || !in || !out || in->frameCount == 0) return 0;
    if (!c->enabled) { if (out != in && out->raw != in->raw) memcpy(out->raw, in->raw, in->frameCount * c->nch * (c->cfg.format == AUDIO_FORMAT_PCM_FLOAT ? 4 : 2)); return 0; }
    size_t frames = in->frameCount; int nch = c->nch;
    if (c->cfg.format == AUDIO_FORMAT_PCM_FLOAT) {
        float *ip = in->f32, *op = out->f32;
        for (size_t i = 0; i < frames; i++)
            for (int ch = 0; ch < nch && ch < 8; ch++) {
                float x = ip[i * nch + ch];
                float y = c->b0 * x + c->b1 * c->x1[ch] + c->b2 * c->x2[ch] - c->a1 * c->y1[ch] - c->a2 * c->y2[ch];
                c->x2[ch] = c->x1[ch]; c->x1[ch] = x; c->y2[ch] = c->y1[ch]; c->y1[ch] = y;
                op[i * nch + ch] = y;
            }
    } else {
        int16_t *ip = in->s16, *op = out->s16;
        for (size_t i = 0; i < frames; i++)
            for (int ch = 0; ch < nch && ch < 8; ch++) {
                float x = (float)ip[i * nch + ch] / 32768.0f;
                float y = c->b0 * x + c->b1 * c->x1[ch] + c->b2 * c->x2[ch] - c->a1 * c->y1[ch] - c->a2 * c->y2[ch];
                c->x2[ch] = c->x1[ch]; c->x1[ch] = x; c->y2[ch] = c->y1[ch]; c->y1[ch] = y;
                int v = (int)(y * 32767.0f); if (v > 32767) v = 32767; if (v < -32768) v = -32768;
                op[i * nch + ch] = (int16_t)v;
            }
    }
    return 0;
}

static int32_t spike_process_reverse(effect_handle_t self, audio_buffer_t *in, audio_buffer_t *out) {
    (void)self; (void)in; (void)out; return -ENOSYS;
}

static int32_t spike_command(effect_handle_t self, uint32_t cmd, uint32_t size, void *data, uint32_t *rsize, void *reply) {
    spike_ctx_t *c = (spike_ctx_t *)self;
    int32_t status = 0;
    uint32_t rs = sizeof(int32_t);
    if (rsize) *rsize = rs;
    if (reply) *(int32_t *)reply = 0;
    switch (cmd) {
    case EFFECT_CMD_INIT:
        ALOGI("INIT (sessionId from create), size=%u", size); break;
    case EFFECT_CMD_SET_CONFIG:
        if (data && size >= sizeof(buffer_config_t)) {
            memcpy(&c->cfg, data, sizeof(buffer_config_t));
            c->nch = popcount(c->cfg.channels); if (c->nch < 1) c->nch = 2;
            design_eq(c);
            ALOGI("SET_CONFIG rate=%u ch=0x%x(%d) fmt=%d", c->cfg.samplingRate, c->cfg.channels, c->nch, c->cfg.format);
        } break;
    case EFFECT_CMD_GET_CONFIG:
        if (reply && rsize) { if (*rsize >= sizeof(int32_t) + sizeof(buffer_config_t)) { *(int32_t *)reply = 0; memcpy((char *)reply + sizeof(int32_t), &c->cfg, sizeof(buffer_config_t)); *rsize = sizeof(int32_t) + sizeof(buffer_config_t); } } break;
    case EFFECT_CMD_ENABLE:
        c->enabled = 1; ALOGI("ENABLE — SpikeEQ is ON THE MIX"); break;
    case EFFECT_CMD_DISABLE:
        c->enabled = 0; ALOGI("DISABLE"); break;
    case EFFECT_CMD_RESET:
        memset(c->x1, 0, sizeof(c->x1)); memset(c->x2, 0, sizeof(c->x2));
        memset(c->y1, 0, sizeof(c->y1)); memset(c->y2, 0, sizeof(c->y2)); break;
    case EFFECT_CMD_SET_DEVICE:
    case EFFECT_CMD_SET_INPUT_DEVICE:
    case EFFECT_CMD_SET_AUDIO_MODE:
    case EFFECT_CMD_SET_AUDIO_SOURCE:
    case EFFECT_CMD_SET_PARAM_DEFERRED:
    case EFFECT_CMD_SET_PARAM_COMMIT:
    case EFFECT_CMD_OFFLOAD:
        break;
    case EFFECT_CMD_SET_VOLUME:
        /* echo volume back unmodified */
        if (reply && rsize && data && size) { if (*rsize >= size) { memcpy(reply, data, size); *rsize = size; } }
        break;
    case EFFECT_CMD_DUMP:
    case EFFECT_CMD_GET_PARAM:
    case EFFECT_CMD_SET_PARAM:
    default:
        status = 0; break;
    }
    if (reply && rsize && cmd != EFFECT_CMD_GET_CONFIG && cmd != EFFECT_CMD_SET_VOLUME) *(int32_t *)reply = status;
    return status;
}

static int32_t spike_get_descriptor(effect_handle_t self, effect_descriptor_t *d) {
    spike_ctx_t *c = (spike_ctx_t *)self;
    if (!c || !d) return -EINVAL;
    memcpy(d, c->desc, sizeof(*d));
    return 0;
}

static struct effect_interface_s spike_itfe = {
    spike_process, spike_process_reverse, spike_command, spike_get_descriptor
};

/* ---- library interface ---- */
static int32_t lib_create(const effect_uuid_t *uuid, int32_t sessionId, int32_t ioId, effect_handle_t *pH) {
    if (!uuid || !pH || memcmp(uuid, &kImplUuid, sizeof(*uuid)) != 0) return -EINVAL;
    spike_ctx_t *c = (spike_ctx_t *)calloc(1, sizeof(spike_ctx_t));
    if (!c) return -ENOMEM;
    c->itfe = &spike_itfe;
    c->desc = &kDesc;
    c->cfg.samplingRate = 48000; c->cfg.channels = 3 /* stereo */; c->cfg.format = AUDIO_FORMAT_PCM_FLOAT;
    c->nch = 2; c->enabled = 0; design_eq(c);
    *pH = (effect_handle_t)c;
    ALOGI("create SpikeEQ sessionId=%d ioId=%d ctx=%p", sessionId, ioId, c);
    return 0;
}
static int32_t lib_release(effect_handle_t h) { free(h); return 0; }
static int32_t lib_get_desc(const effect_uuid_t *uuid, effect_descriptor_t *d) {
    if (!uuid || !d) return -EINVAL;
    if (memcmp(uuid, &kImplUuid, sizeof(*uuid)) == 0) { memcpy(d, &kDesc, sizeof(*d)); return 0; }
    if (memcmp(uuid, &kTypeEq, sizeof(*uuid)) == 0) { memcpy(d, &kDesc, sizeof(*d)); return 0; }
    return -EINVAL;
}

__attribute__((visibility("default"))) const audio_effect_library_t AELI = {
    AUDIO_EFFECT_LIBRARY_TAG, EFFECT_LIBRARY_API_VERSION,
    "SpikeEQ Library", "JamesDSP Rebuild (M0 spike)",
    lib_create, lib_release, lib_get_desc
};
