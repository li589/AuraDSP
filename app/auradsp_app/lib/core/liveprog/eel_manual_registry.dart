/*
 * eel_manual_registry.dart — EEL2 官方规范参考手册全量数据库
 *
 * 梳理并正规化 JamesDSP 底层 EEL2 / NSEEL 虚拟机的 80+ 个内置函数与核心机制。
 * 支持按分类索引、模糊搜索、查看签名入参说明与一键插入代码片段。
 */

enum EelManualCategory {
  language('language', '语言结构与段指令', 'Language & Sections'),
  registers('registers', '音频流寄存器与常量', 'Registers & Constants'),
  math('math', '初等数学与高精计算', 'Math & Transcendentals'),
  memory('memory', '向量、数组与内存管理', 'Vectors & Memory'),
  spectral('spectral', '傅里叶与频域分析 (FFT/STFT)', 'FFT & Spectral DSP'),
  filter('filter', '滤波器与音频 DSP 模块', 'Filters & Audio DSP'),
  matrix('matrix', '矩阵代数与求解器', 'Linear Algebra & Solvers'),
  audioIo('audioIo', '音频文件解码与输出 (I/O)', 'Audio File I/O'),
  system('system', '字符串、系统与调试', 'System & Utilities');

  final String id;
  final String labelZh;
  final String labelEn;
  const EelManualCategory(this.id, this.labelZh, this.labelEn);
}

class EelParamDoc {
  final String name;
  final String type;
  final String desc;
  const EelParamDoc(this.name, this.type, this.desc);
}

class EelManualEntry {
  final String name;
  final EelManualCategory category;
  final String signature;
  final String summaryZh;
  final String summaryEn;
  final String descZh;
  final String descEn;
  final List<EelParamDoc> params;
  final String returnDesc;
  final String snippet;

  const EelManualEntry({
    required this.name,
    required this.category,
    required this.signature,
    required this.summaryZh,
    required this.summaryEn,
    required this.descZh,
    required this.descEn,
    this.params = const [],
    required this.returnDesc,
    required this.snippet,
  });
}

/// 全量 EEL2 函数与语言特性注册表
class EelManualRegistry {
  static final List<EelManualEntry> entries = [
    // -------------------------------------------------------------
    // 1. Language & Sections
    // -------------------------------------------------------------
    const EelManualEntry(
      name: '@init',
      category: EelManualCategory.language,
      signature: '@init',
      summaryZh: '脚本初始化执行段',
      summaryEn: 'Script initialization section',
      descZh: '在脚本首次编译加载、采样率改变或引擎重置时执行一次。必须至少包含一条有效语句。适合声明全局变量、开辟内存和预计算滤波器系数。',
      descEn: 'Executed once upon script load, sample rate change, or reset. Must contain at least one statement. Ideal for memory allocation and coefficient calculations.',
      returnDesc: 'void',
      snippet: '''@init
srate = (srate > 0) ? srate : 48000;
PI = 3.141592653589793;
gain = 0.5;''',
    ),
    const EelManualEntry(
      name: '@sample',
      category: EelManualCategory.language,
      signature: '@sample',
      summaryZh: '逐音频采样点处理段',
      summaryEn: 'Per-sample audio processing section',
      descZh: '实时音频泵线程（Audio Pump Thread）对每个样本帧调用一次。通过读写寄存器 spl0 (L) 和 spl1 (R) 实现音频实时处理与变换。',
      descEn: 'Called for every audio frame by the real-time audio thread. Process channels by reading and writing spl0 (Left) and spl1 (Right).',
      returnDesc: 'void',
      snippet: '''@sample
spl0 *= slider1;
spl1 *= slider1;''',
    ),
    const EelManualEntry(
      name: '@slider',
      category: EelManualCategory.language,
      signature: '@slider',
      summaryZh: '滑块参数变化响应段',
      summaryEn: 'Slider change callback section',
      descZh: '当用户在界面拖动任何动态滑块或参数发生变动时触发，常用于平滑更新增益系数，避免在 @sample 内部做昂贵的重复运算。',
      descEn: 'Triggered when any UI slider value changes. Use this to update coefficients efficiently without per-sample overhead.',
      returnDesc: 'void',
      snippet: '''@slider
target_gain = 10 ^ (slider1 / 20);''',
    ),
    const EelManualEntry(
      name: 'function',
      category: EelManualCategory.language,
      signature: 'function name(args...) instance(vars...) ( ... );',
      summaryZh: '定义可重用函数或面向对象方法',
      summaryEn: 'Define reusable function or instance method',
      descZh: 'EEL2 支持普通函数和具有内部持久状态的 instance 方法。instance 变量在对象每次调用时保持其记忆，非常适合状态变量（如滤波器历史样本）。',
      descEn: 'Defines user functions. The instance(...) syntax allows object-like state retention between calls, perfect for filters and delays.',
      returnDesc: '最后一项表达式的计算值',
      snippet: '''function process_gain(x) instance(gain) (
  x * this.gain;
);''',
    ),
    const EelManualEntry(
      name: 'loop',
      category: EelManualCategory.language,
      signature: 'loop(count, statement);',
      summaryZh: '指定次数定长循环',
      summaryEn: 'Fixed-iteration loop statement',
      descZh: '执行循环体 count 次。count 可以是整数或浮点计算值（自动取整）。请避免在 @sample 中使用过大的循环次数以免产生音频爆音。',
      descEn: 'Executes body count times. Avoid large iterations inside @sample to prevent audio dropouts.',
      returnDesc: '最后一轮的计算值',
      snippet: '''i = 0;
loop(16,
  buf[i] = 0;
  i += 1;
);''',
    ),
    const EelManualEntry(
      name: 'while',
      category: EelManualCategory.language,
      signature: 'while(condition) ( statements... );',
      summaryZh: '条件循环语句',
      summaryEn: 'Conditional while loop statement',
      descZh: '当条件成立（非零）时持续执行循环体。EEL2 引擎内建最大执行步数安全保护（防死锁看门狗）。',
      descEn: 'Executes body while condition evaluates to true. Safeguarded by engine instruction limit.',
      returnDesc: '最后一轮的计算值',
      snippet: '''n = 10;
while(n > 0) (
  n -= 1;
);''',
    ),

    // -------------------------------------------------------------
    // 2. Registers & Constants
    // -------------------------------------------------------------
    const EelManualEntry(
      name: 'spl0 / spl1',
      category: EelManualCategory.registers,
      signature: 'spl0; spl1;',
      summaryZh: '左 / 右声道浮点音频样本寄存器',
      summaryEn: 'Left / Right audio sample registers',
      descZh: '核心音频输入输出寄存器。在 @sample 段开头代表当前输入的样本值（标称范围 -1.0 到 +1.0），段末写入的值即为输出信号。',
      descEn: 'Primary audio IO registers in @sample. Floating point normalized nominally to [-1.0, 1.0].',
      returnDesc: 'float',
      snippet: '''@sample
spl0 = spl0 * 0.5;
spl1 = spl1 * 0.5;''',
    ),
    const EelManualEntry(
      name: 'srate',
      category: EelManualCategory.registers,
      signature: 'srate',
      summaryZh: '当前设备实际硬件采样率 (Hz)',
      summaryEn: 'Current sample rate in Hertz',
      descZh: '只读系统变量，表示当前音频设备运行的采样率（如 44100, 48000, 96000 等）。',
      descEn: 'Read-only system variable containing the active audio sample rate in Hz.',
      returnDesc: 'float',
      snippet: '''nyquist = srate * 0.5;
w0 = 2 * \$PI * 1000 / srate;''',
    ),
    const EelManualEntry(
      name: 'slider1..8',
      category: EelManualCategory.registers,
      signature: 'slider1 ... slider8',
      summaryZh: '用户界面动态交互滑块参数',
      summaryEn: 'UI dynamic interactive slider parameters',
      descZh: '8 个预留的双向浮点滑块参数。可在顶部声明范围与默认值，通过界面拖动滑块实时调节音效行为。',
      descEn: '8 bidirectional float slider parameters. Declare ranges at script top to generate UI controls.',
      returnDesc: 'float',
      snippet: '''slider1:0<-24,12,0.5>Master Trim (dB)
@sample
spl0 *= 10 ^ (slider1 / 20);
spl1 *= 10 ^ (slider1 / 20);''',
    ),
    const EelManualEntry(
      name: '\$PI / \$E',
      category: EelManualCategory.registers,
      signature: '\$PI; \$E;',
      summaryZh: '圆周率与自然常数',
      summaryEn: 'Pi and Euler mathematical constants',
      descZh: '\$PI = 3.14159265358979323846; \$E = 2.7182818284590452354。',
      descEn: 'Built-in precision mathematical constants for Pi and Napier constant e.',
      returnDesc: 'float',
      snippet: '''tau = 2 * \$PI;
decay = exp(-1 / \$E);''',
    ),

    // -------------------------------------------------------------
    // 3. Math & Transcendentals
    // -------------------------------------------------------------
    const EelManualEntry(
      name: 'sin / cos / tan',
      category: EelManualCategory.math,
      signature: 'sin(x); cos(x); tan(x);',
      summaryZh: '标准三角函数（弧度入参）',
      summaryEn: 'Standard trigonometric functions (radians)',
      descZh: '计算给定弧度 x 的正弦、余弦、正切值。高优化底层汇编/SIMD指令加速。',
      descEn: 'Calculates sine, cosine, and tangent of angle x in radians.',
      params: [EelParamDoc('x', 'float', '弧度角 (radians)')],
      returnDesc: 'float',
      snippet: '''theta = 2 * \$PI * freq / srate;
s = sin(theta);
c = cos(theta);''',
    ),
    const EelManualEntry(
      name: 'atan2',
      category: EelManualCategory.math,
      signature: 'atan2(y, x)',
      summaryZh: '四象限反正切函数',
      summaryEn: 'Four-quadrant inverse tangent',
      descZh: '返回 y / x 的反正切弧度值，值域为 (-PI, +PI]，正确处理 x=0 的垂直奇点。',
      descEn: 'Returns the four-quadrant arctangent of y and x in the range (-PI, +PI].',
      params: [
        EelParamDoc('y', 'float', 'Y 坐标分量'),
        EelParamDoc('x', 'float', 'X 坐标分量'),
      ],
      returnDesc: 'float',
      snippet: '''phase = atan2(imag, real);''',
    ),
    const EelManualEntry(
      name: 'invsqrt',
      category: EelManualCategory.math,
      signature: 'invsqrt(x)',
      summaryZh: '倒数平方根 1 / sqrt(x)',
      summaryEn: 'Inverse square root (1 / sqrt(x))',
      descZh: '高精度倒数平方根，在音频物理建模和向量归一化时极大减少除法开销。',
      descEn: 'Computes 1.0 / sqrt(x) with high precision and speed.',
      params: [EelParamDoc('x', 'float', '正浮点数 (x > 0)')],
      returnDesc: 'float',
      snippet: '''norm = invsqrt(x*x + y*y);''',
    ),
    const EelManualEntry(
      name: 'expint / expintFast',
      category: EelManualCategory.math,
      signature: 'expint(x); expintFast(x);',
      summaryZh: '指数积分函数及其快速插值版',
      summaryEn: 'Exponential integral function and fast lookup',
      descZh: '计算 En(x) 指数积分，用于高阶声学校准与非线性扩散声场建模。',
      descEn: 'Evaluates the exponential integral, utilized for high-order acoustic field calibration.',
      params: [EelParamDoc('x', 'float', '输入数值')],
      returnDesc: 'float',
      snippet: '''e_val = expintFast(0.75);''',
    ),

    // -------------------------------------------------------------
    // 4. Vectors & Memory
    // -------------------------------------------------------------
    const EelManualEntry(
      name: 'freembuf',
      category: EelManualCategory.memory,
      signature: 'freembuf(top)',
      summaryZh: '设置并获取可用内存块上限',
      summaryEn: 'Set and query free memory buffer boundary',
      descZh: '调整或查询动态内存缓冲区的边界。可确保后续分配不与其他全局缓冲区冲突。',
      descEn: 'Sets or returns the top of the user memory buffer pool.',
      params: [EelParamDoc('top', 'int', '新内存上限地址（字节/浮点槽位）')],
      returnDesc: 'float (之前的内存顶端)',
      snippet: '''buf_start = freembuf(0);
freembuf(buf_start + 65536); // 保留 64K 样本空间''',
    ),
    const EelManualEntry(
      name: 'memcpy / memset',
      category: EelManualCategory.memory,
      signature: 'memcpy(dest, src, count); memset(dest, value, count);',
      summaryZh: '高效内存块复制与内存填充',
      summaryEn: 'Fast memory block copy and fill',
      descZh: '在用户内存空间中批量复制连续浮点数组或用指定数值快速填充。底层调用高效内存总线指令。',
      descEn: 'Copies or fills contiguous blocks of float memory cells.',
      params: [
        EelParamDoc('dest', 'int', '目标内存起始指针'),
        EelParamDoc('src/value', 'any', '源内存指针 或 填充数值'),
        EelParamDoc('count', 'int', '操作的浮点槽位数'),
      ],
      returnDesc: 'void',
      snippet: '''memset(buf, 0, 1024);
memcpy(backup, buf, 1024);''',
    ),
    const EelManualEntry(
      name: 'circshift',
      category: EelManualCategory.memory,
      signature: 'circshift(ptr, size, shift)',
      summaryZh: '数组循环移位操作',
      summaryEn: 'Circular shift array elements',
      descZh: '对起始于 ptr、长度为 size 的连续数组执行正向或负向循环移位。常用于环形延迟缓冲区与相位旋转。',
      descEn: 'Circularly shifts elements in a memory array by specified offset.',
      params: [
        EelParamDoc('ptr', 'int', '数组起始地址'),
        EelParamDoc('size', 'int', '数组长度'),
        EelParamDoc('shift', 'int', '移位步长（正负皆可）'),
      ],
      returnDesc: 'void',
      snippet: '''circshift(delay_buf, 256, 1);''',
    ),
    const EelManualEntry(
      name: 'maxVec / minVec / meanVec / medianVec',
      category: EelManualCategory.memory,
      signature: 'maxVec(ptr, len); meanVec(ptr, len);',
      summaryZh: '向量最大值 / 最小值 / 均值 / 中位数统计',
      summaryEn: 'Vector statistical operations (max, min, mean, median)',
      descZh: '对连续内存数组进行高性能统计学分析，极大提升特征提取与音频峰值电平探测效率。',
      descEn: 'Performs vector statistical reduction over contiguous memory blocks.',
      params: [
        EelParamDoc('ptr', 'int', '数组内存起始指针'),
        EelParamDoc('len', 'int', '数组元素数量'),
      ],
      returnDesc: 'float (计算统计值)',
      snippet: '''peak = maxVec(pcm_buf, 512);
avg = meanVec(pcm_buf, 512);''',
    ),

    // -------------------------------------------------------------
    // 5. Spectral & FFT
    // -------------------------------------------------------------
    const EelManualEntry(
      name: 'fft / ifft',
      category: EelManualCategory.spectral,
      signature: 'fft(buf, size); ifft(buf, size);',
      summaryZh: '快速傅里叶正变换与逆变换 (复数)',
      summaryEn: 'Fast Fourier Transform and Inverse (Complex)',
      descZh: '原地执行基-2快速傅里叶变换。缓冲区格式为交织的实部与虚部 [Re0, Im0, Re1, Im1, ...]。size 必须为 2 的幂次。',
      descEn: 'In-place radix-2 complex FFT. Buffer layout: interleaved [Re0, Im0, ...]. Size must be power of 2.',
      params: [
        EelParamDoc('buf', 'int', '复数缓冲区指针'),
        EelParamDoc('size', 'int', '变换点数 (2 的幂次)'),
      ],
      returnDesc: 'void',
      snippet: '''fft_permute(buf, 1024);
fft(buf, 1024);''',
    ),
    const EelManualEntry(
      name: 'stftInit / stftForward / stftBackward',
      category: EelManualCategory.spectral,
      signature: 'stftInit(st, wndLen, hop); stftForward(st, in, out);',
      summaryZh: '短时傅里叶变换 (STFT) 分析合成流水线',
      summaryEn: 'Short-Time Fourier Transform (STFT) framework',
      descZh: '完整的实时重叠相加（Overlap-Add）频域处理引擎。支持加窗、正变换到频域、频域运算处理后逆变换平滑重构。',
      descEn: 'Full real-time Overlap-Add STFT engine for spectral audio processing.',
      params: [
        EelParamDoc('st', 'int', 'STFT 状态结构体内存指针'),
        EelParamDoc('wndLen', 'int', '分析窗长度 (如 512, 1024)'),
        EelParamDoc('hop', 'int', '步进跃迁长度 (如 128, 256)'),
      ],
      returnDesc: 'int / void',
      snippet: '''stftInit(st, 1024, 256);
// 在音频循环中逐帧执行频域分析
stftForward(st, pcm_in, spec_out);''',
    ),

    // -------------------------------------------------------------
    // 6. Filters & Audio DSP
    // -------------------------------------------------------------
    const EelManualEntry(
      name: 'FIRInit / FIRProcess',
      category: EelManualCategory.filter,
      signature: 'FIRInit(state, coeffs, numTaps); FIRProcess(state, in, out, len);',
      summaryZh: '有限长冲激响应 (FIR) 滤波器引擎',
      summaryEn: 'Finite Impulse Response (FIR) filter engine',
      descZh: '硬件级卷积运算器。FIRInit 加载脉冲系数与状态，FIRProcess 执行单样本或批量样本的高速卷积过滤。',
      descEn: 'Hardware-accelerated FIR convolution engine.',
      params: [
        EelParamDoc('state', 'int', '滤波器状态内存空间'),
        EelParamDoc('coeffs', 'int', '系数数组指针'),
        EelParamDoc('numTaps', 'int', '抽头阶数 (Taps)'),
      ],
      returnDesc: 'void',
      snippet: '''FIRInit(fir_st, h_coeffs, 64);
FIRProcess(fir_st, in_buf, out_buf, 256);''',
    ),
    const EelManualEntry(
      name: 'InitPolyphaseFilterbank',
      category: EelManualCategory.filter,
      signature: 'InitPolyphaseFilterbank(st, bands, decimation);',
      summaryZh: '多相滤波器组分析/合成初始化',
      summaryEn: 'Polyphase filterbank initialization',
      descZh: '构建准完全重构（QMF）的多带多相分频器。可将全频信号分解为多个子带独立进行压缩、声场扩展或均衡。',
      descEn: 'Initializes a polyphase filterbank for multi-band splitting and synthesis.',
      params: [
        EelParamDoc('st', 'int', '状态内存起始地址'),
        EelParamDoc('bands', 'int', '子带通道数'),
        EelParamDoc('decimation', 'int', '抽取因子'),
      ],
      returnDesc: 'void',
      snippet: '''InitPolyphaseFilterbank(pfb_st, 32, 16);''',
    ),
    const EelManualEntry(
      name: 'InitPinkNoise / GeneratePinkNoise',
      category: EelManualCategory.filter,
      signature: 'InitPinkNoise(st); GeneratePinkNoise(st);',
      summaryZh: '粉红噪声发生器 (1/f 噪声)',
      summaryEn: 'Pink noise generator (1/f distribution)',
      descZh: '基于 Voss-McCartney 滤波算法生成均匀纯净的粉红噪声，能量随倍频程恒定衰减（-3dB/oct），广泛用于声学校准与试音。',
      descEn: 'Generates high quality 1/f pink noise for acoustic measurement and calibration.',
      params: [EelParamDoc('st', 'int', '噪声发生器状态内存地址')],
      returnDesc: 'float (新粉红噪声样本)',
      snippet: '''noise = GeneratePinkNoise(pink_st);
spl0 = noise * 0.1;''',
    ),
    const EelManualEntry(
      name: 'IIRBandSplitterInit / Process',
      category: EelManualCategory.filter,
      signature: 'IIRBandSplitterInit(st, freq1, freq2); IIRBandSplitterProcess(st, in, ...);',
      summaryZh: '多频段 IIR 分频器 (Linkwitz-Riley 级联)',
      summaryEn: 'Multi-band Linkwitz-Riley crossover splitter',
      descZh: '4阶 Linkwitz-Riley（LR4，24dB/oct）平坦相角分频器，将输入音频无缝拆分为 Low / Mid / High 三频段，求和无相位抵消。',
      descEn: 'LR4 multi-band crossover splitter with perfect sum phase alignment.',
      returnDesc: 'void',
      snippet: '''IIRBandSplitterInit(splitter, 250, 3500);''',
    ),

    // -------------------------------------------------------------
    // 7. Linear Algebra & Solvers
    // -------------------------------------------------------------
    const EelManualEntry(
      name: 'det / inv / transpose',
      category: EelManualCategory.matrix,
      signature: 'det(A, rows, cols); inv(A, invA, n); transpose(A, At, r, c);',
      summaryZh: '矩阵行列式、求逆与转置',
      summaryEn: 'Matrix determinant, inversion, and transpose',
      descZh: '高精度矩阵线性代数运算。采用 LU 分解与高斯-若尔当消元，支持任意阶正方矩阵的高效逆运算。',
      descEn: 'Linear algebra matrix operators using LU decomposition.',
      params: [
        EelParamDoc('A', 'int', '输入矩阵内存地址 (行优先)'),
        EelParamDoc('invA/At', 'int', '输出目标矩阵内存地址'),
        EelParamDoc('n/rows/cols', 'int', '矩阵维度'),
      ],
      returnDesc: 'float / void',
      snippet: '''d = det(mat_A, 3, 3);
inv(mat_A, mat_inv, 3);''',
    ),
    const EelManualEntry(
      name: 'mldivide / mrdivide',
      category: EelManualCategory.matrix,
      signature: 'mldivide(A, B, X, rA, cA, cB);',
      summaryZh: '矩阵左除 (A \\ B) 求解线性方程组 A*X = B',
      summaryEn: 'Matrix left divide solver for A * X = B',
      descZh: '等价于 MATLAB 中的 A \\ B。采用 QR 分解求解正定或超定线性最小二乘系统，广泛用于自适应滤波与逆滤波设计。',
      descEn: 'Solves A * X = B via QR factorization, identical to MATLAB mldivide.',
      returnDesc: 'int (0=成功)',
      snippet: '''mldivide(A, B, X, 4, 4, 1);''',
    ),
    const EelManualEntry(
      name: 'linspace',
      category: EelManualCategory.matrix,
      signature: 'linspace(dst, start, end, count)',
      summaryZh: '生成线性等间隔向量',
      summaryEn: 'Generate linearly spaced vector',
      descZh: '在区间 [start, end] 内生成 count 个均匀间隔的数值并填入 dst 缓冲区。用于频点网格生成。',
      descEn: 'Generates count linearly spaced points between start and end into dst buffer.',
      params: [
        EelParamDoc('dst', 'int', '目标缓冲区地址'),
        EelParamDoc('start', 'float', '起始数值'),
        EelParamDoc('end', 'float', '终止数值'),
        EelParamDoc('count', 'int', '生成点数'),
      ],
      returnDesc: 'void',
      snippet: '''linspace(freq_axis, 20, 20000, 256);''',
    ),

    // -------------------------------------------------------------
    // 8. Audio File I/O
    // -------------------------------------------------------------
    const EelManualEntry(
      name: 'decodeWavFromFile',
      category: EelManualCategory.audioIo,
      signature: 'decodeWavFromFile(path, outPtr, maxSamples, infoPtr)',
      summaryZh: '从磁盘读取并解码 WAV 文件到内存',
      summaryEn: 'Decode WAV audio file from disk into memory',
      descZh: '基于 dr_wav 解码标准 WAV 音频文件（16/24/32bit PCM 或 Float），将解压后的浮点样本写入指定内存缓冲区。',
      descEn: 'Decodes WAV audio from filesystem directly into user memory buffer.',
      params: [
        EelParamDoc('path', 'string', '文件绝对路径'),
        EelParamDoc('outPtr', 'int', '输出 PCM 缓冲区地址'),
        EelParamDoc('maxSamples', 'int', '最大读取样本数'),
      ],
      returnDesc: 'int (实际解码样本数)',
      snippet: '''samples = decodeWavFromFile("D:/ir.wav", ir_buf, 48000, info);''',
    ),
    const EelManualEntry(
      name: 'decodeFLACFromFile',
      category: EelManualCategory.audioIo,
      signature: 'decodeFLACFromFile(path, outPtr, maxSamples, infoPtr)',
      summaryZh: '从磁盘读取并解码无损 FLAC 音频文件',
      summaryEn: 'Decode lossless FLAC file from disk into memory',
      descZh: '直接解压 FLAC 无损压缩脉冲响应或测试音轨至浮点内存池。',
      descEn: 'Decodes FLAC lossless audio from disk directly into memory.',
      returnDesc: 'int (实际解码样本数)',
      snippet: '''samples = decodeFLACFromFile("D:/ir.flac", ir_buf, 48000, info);''',
    ),

    // -------------------------------------------------------------
    // 9. System & Utilities
    // -------------------------------------------------------------
    const EelManualEntry(
      name: 'sprintf / printf',
      category: EelManualCategory.system,
      signature: 'sprintf(buf, format, args...); printf(format, args...);',
      summaryZh: '格式化字符串与标准控制台打印输出',
      summaryEn: 'Formatted string printing and console debugging',
      descZh: '标准 C 风格格式化打印，用于调试变量、打印状态日志或动态拼接字符串。',
      descEn: 'C-style formatted printing to string buffer or debug console output.',
      params: [
        EelParamDoc('format', 'string', '格式化模板字符串 (如 "Val=%.2f")'),
        EelParamDoc('args', 'any', '变长参数列表'),
      ],
      returnDesc: 'int (输出字符数)',
      snippet: '''sprintf(str_buf, "SampleRate=%d, Gain=%.2fdB", srate, slider1);''',
    ),
    const EelManualEntry(
      name: 'time_precise',
      category: EelManualCategory.system,
      signature: 'time_precise()',
      summaryZh: '获取高精度微秒级系统时间戳',
      summaryEn: 'Get high-precision microsecond system timestamp',
      descZh: '返回系统单调时钟的高精度秒数（浮点数，带微秒小数位），常用于计算算法执行耗时与基准测试。',
      descEn: 'Returns high resolution timestamp in seconds for benchmark profiling.',
      returnDesc: 'float (时间戳/秒)',
      snippet: '''t0 = time_precise();
// 执行测试函数
t_elapsed = time_precise() - t0;''',
    ),
    const EelManualEntry(
      name: 'breakpoint',
      category: EelManualCategory.system,
      signature: 'breakpoint(id)',
      summaryZh: '调试断点挂钩指令',
      summaryEn: 'Debugger breakpoint hook instruction',
      descZh: '在实时音频流中触发断点监视点，用于配合 LiveprogIDE / 调试器观察内部状态。',
      descEn: 'Triggers a debugger inspection breakpoint with custom ID.',
      returnDesc: 'void',
      snippet: '''breakpoint(101);''',
    ),
  ];

  /// 根据关键词与分类模糊搜索
  static List<EelManualEntry> search({
    String query = '',
    EelManualCategory? category,
  }) {
    final q = query.trim().toLowerCase();
    return entries.where((e) {
      if (category != null && e.category != category) return false;
      if (q.isEmpty) return true;
      return e.name.toLowerCase().contains(q) ||
          e.signature.toLowerCase().contains(q) ||
          e.summaryZh.toLowerCase().contains(q) ||
          e.summaryEn.toLowerCase().contains(q) ||
          e.descZh.toLowerCase().contains(q) ||
          e.descEn.toLowerCase().contains(q);
    }).toList();
  }
}
