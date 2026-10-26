/*
 * eel_templates.dart — Liveprog IDE 新建向导预设代码模板库
 */

class EelTemplate {
  final String id;
  final String titleZh;
  final String titleEn;
  final String descZh;
  final String descEn;
  final String code;

  const EelTemplate({
    required this.id,
    required this.titleZh,
    required this.titleEn,
    required this.descZh,
    required this.descEn,
    required this.code,
  });
}

class EelTemplates {
  static const List<EelTemplate> list = [
    EelTemplate(
      id: 'passthrough',
      titleZh: '基础音频直通与增益 (Passthrough)',
      titleEn: 'Basic Passthrough & Gain Trim',
      descZh: '最基础的起步模板，包含采样率安全保护和主音量滑块控制。',
      descEn: 'Minimal starter template with sample rate guard and master volume slider.',
      code: '''/*
 * AuraDSP EEL2 Starter: Passthrough & Gain
 */
slider1:0<-24,12,0.5>Master Trim (dB)

@init
srate = (srate > 0) ? srate : 48000;
dbg = 1;

@slider
gain = 10 ^ (slider1 / 20);

@sample
spl0 *= gain;
spl1 *= gain;
''',
    ),
    EelTemplate(
      id: 'stereo_widener',
      titleZh: '中侧立体声场拓宽 (M/S Stereo Widener)',
      titleEn: 'Mid/Side Stereo Widener',
      descZh: '基于 Mid/Side (M/S) 矩阵编码调节侧边信号比例，实现无相位抵消的声场加宽。',
      descEn: 'Mid/Side matrix encoding to adjust stereo width without mono cancellation.',
      code: '''/*
 * AuraDSP EEL2: Mid/Side Stereo Widener
 */
slider1:100<0,200,1>Stereo Width (%)

@init
srate = (srate > 0) ? srate : 48000;
INV_SQRT2 = 0.7071067811865475;

@slider
side_gain = slider1 * 0.01;

@sample
// M/S Encoding
mid = (spl0 + spl1) * INV_SQRT2;
side = (spl0 - spl1) * INV_SQRT2 * side_gain;

// M/S Decoding
spl0 = (mid + side) * INV_SQRT2;
spl1 = (mid - side) * INV_SQRT2;
''',
    ),
    EelTemplate(
      id: 'peaking_eq',
      titleZh: '双二阶峰值均衡器 (RBJ Peaking EQ)',
      titleEn: 'RBJ Peaking EQ Filter',
      descZh: '基于 RBJ Cookbook 的经典双二阶钟形滤波器，频率、增益与 Q 值动态由滑块实时调节。',
      descEn: 'Classic second-order peaking biquad filter with real-time UI sliders.',
      code: '''/*
 * AuraDSP EEL2: Parametric Peaking EQ
 */
slider1:1000<100,10000,10>Frequency (Hz)
slider2:3.0<-18,18,0.5>Gain (dB)
slider3:1.41<0.1,10,0.05>Q Factor

@init
srate = (srate > 0) ? srate : 48000;
PI = 3.141592653589793;

function calc_biquad(freq, q, gain_db) instance(b0, b1, b2, a1, a2) (
  w0 = 2 * PI * freq / srate;
  alpha = sin(w0) / (2 * q);
  A = 10 ^ (gain_db / 40);

  b0 = 1 + alpha * A;
  b1 = -2 * cos(w0);
  b2 = 1 - alpha * A;
  a0 = 1 + alpha / A;
  a1 = -2 * cos(w0);
  a2 = 1 - alpha / A;

  inv_a0 = 1 / a0;
  this.b0 = b0 * inv_a0;
  this.b1 = b1 * inv_a0;
  this.b2 = b2 * inv_a0;
  this.a1 = a1 * inv_a0;
  this.a2 = a2 * inv_a0;
);

function process_biquad(xn) instance(b0, b1, b2, a1, a2, x1, x2, y1, y2) (
  yn = this.b0 * xn + this.b1 * this.x1 + this.b2 * this.x2 - this.a1 * this.y1 - this.a2 * this.y2;
  this.x2 = this.x1; this.x1 = xn;
  this.y2 = this.y1; this.y1 = yn;
  yn;
);

@slider
eqL.calc_biquad(slider1, slider3, slider2);
eqR.calc_biquad(slider1, slider3, slider2);

@sample
spl0 = eqL.process_biquad(spl0);
spl1 = eqR.process_biquad(spl1);
''',
    ),
    EelTemplate(
      id: 'saturation',
      titleZh: '电子管软饱和非线性失真 (Soft Saturation)',
      titleEn: 'Tube-like Soft Saturation',
      descZh: '利用双曲正切函数 tanh() 与奇次谐波模拟模拟音频硬件的平滑压缩与温润失真。',
      descEn: 'Tanh soft clipper simulating tube saturation with pleasant odd harmonics.',
      code: '''/*
 * AuraDSP EEL2: Smooth Tube Saturation
 */
slider1:1.0<1.0,10.0,0.1>Drive
slider2:0.0<-12.0,6.0,0.5>Output Trim (dB)

@init
srate = (srate > 0) ? srate : 48000;

@slider
drive = slider1;
post_gain = 10 ^ (slider2 / 20) / tanh(drive);

@sample
spl0 = tanh(spl0 * drive) * post_gain;
spl1 = tanh(spl1 * drive) * post_gain;
''',
    ),
    EelTemplate(
      id: 'pink_noise',
      titleZh: '粉红噪声发生与试音 (Pink Noise Generator)',
      titleEn: 'Pink Noise Generator',
      descZh: '利用内置 InitPinkNoise 与 GeneratePinkNoise 函数生成声学校准粉红噪声。',
      descEn: 'Generates calibration pink noise using built-in high order Voss filter.',
      code: '''/*
 * AuraDSP EEL2: Pink Noise Calibration Generator
 */
slider1:-20<-60,0,1>Noise Level (dBFS)

@init
srate = (srate > 0) ? srate : 48000;
mem = 0;
InitPinkNoise(mem, 16);

@slider
vol = 10 ^ (slider1 / 20);

@sample
noise = GeneratePinkNoise(mem, 1.0) * vol;
spl0 = noise;
spl1 = noise;
''',
    ),
    EelTemplate(
      id: 'splitter',
      titleZh: '三频段 Linkwitz-Riley 分频处理 (3-Band Crossover)',
      titleEn: '3-Band Crossover Splitter',
      descZh: '内置 4 阶 LR 分频器将音频划分为低频、中频与高频，独立控制频段增益。',
      descEn: 'Built-in LR4 crossover splitting audio into Low, Mid, and High bands.',
      code: '''/*
 * AuraDSP EEL2: 3-Band Linkwitz-Riley Splitter
 */
slider1:0<-12,12,0.5>Low Gain (dB)
slider2:0<-12,12,0.5>Mid Gain (dB)
slider3:0<-12,12,0.5>High Gain (dB)

@init
srate = (srate > 0) ? srate : 48000;
sp_mem = 0;
IIRBandSplitterInit(sp_mem, 250, 3500);

@slider
g_low = 10 ^ (slider1 / 20);
g_mid = 10 ^ (slider2 / 20);
g_hi  = 10 ^ (slider3 / 20);

@sample
// 单声道或立体声送入分频器处理 (示例处理左声道)
IIRBandSplitterProcess(sp_mem, spl0);
low = sp_mem[0];
mid = sp_mem[1];
hi  = sp_mem[2];

spl0 = low * g_low + mid * g_mid + hi * g_hi;
spl1 = spl0; // 立体声镜像
''',
    ),
  ];
}
