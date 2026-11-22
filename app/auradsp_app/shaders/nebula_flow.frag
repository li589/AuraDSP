#version 460 core
#include <flutter/runtime_effect.glsl>

uniform vec2 uResolution;
uniform float uTime;
uniform float uBass;
uniform float uMid;
uniform float uTreble;
uniform vec4 uColor1;
uniform vec4 uColor2;

out vec4 fragColor;

// 快速 2D 哈希噪声
float hash21(vec2 p) {
    p = fract(p * vec2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

// 平滑值噪声
float vnoise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    vec2 u = f * f * (3.0 - 2.0 * f);

    return mix(mix(hash21(i + vec2(0.0, 0.0)),
                   hash21(i + vec2(1.0, 0.0)), u.x),
               mix(hash21(i + vec2(0.0, 1.0)),
                   hash21(i + vec2(1.0, 1.0)), u.x), u.y);
}

// 4 阶分形布朗运动 (FBM)，驱动深空星云气体无规律漂散
float fbm(vec2 p) {
    float v = 0.0;
    float a = 0.5;
    mat2 rot = mat2(0.80, 0.60, -0.60, 0.80);
    for (int i = 0; i < 4; ++i) {
        v += a * vnoise(p);
        p = rot * p * 2.02;
        a *= 0.5;
    }
    return v;
}

void main() {
    vec2 uv = (FlutterFragCoord().xy - 0.5 * uResolution.xy) / min(uResolution.x, uResolution.y);

    // 1. 恒星背景层 (星星闪烁)
    vec2 starGrid = uv * 32.0;
    vec2 id = floor(starGrid);
    float starRnd = hash21(id);
    float starGlow = 0.0;
    if (starRnd > 0.94) {
        vec2 starPos = fract(starGrid) - 0.5;
        float d = length(starPos);
        float twinkle = 0.5 + 0.5 * sin(uTime * 3.5 + starRnd * 6.28);
        starGlow = (0.015 / (d + 0.02)) * twinkle * (0.8 + uTreble * 1.5);
    }

    // 2. 双重域扭曲 (Domain Warping) 星云流体漂移
    vec2 drift = vec2(uTime * 0.06, uTime * 0.04);
    vec2 q = vec2(fbm(uv * 1.6 + drift), fbm(uv * 1.6 - drift * 0.7));

    vec2 rOffset = vec2(1.7, 9.2) + vec2(uTime * 0.08, -uTime * 0.05);
    vec2 r = vec2(fbm(uv * 2.0 + 1.2 * q + rOffset),
                  fbm(uv * 2.0 + 1.2 * q + rOffset.yx));

    // 音频低频驱动核心气体扰动与膨胀
    float f = fbm(uv * 1.8 + r * (1.2 + uBass * 0.6));

    // 3. 颜色梯度映射
    // 低密度深空底色 -> 中密度主星云色 -> 高密度电离气体辉光
    vec3 cCloud1 = uColor1.rgb;
    vec3 cCloud2 = uColor2.rgb;
    vec3 cDeep = mix(cCloud1, cCloud2, 0.5) * 0.15;

    float cloudWeight = smoothstep(0.18, 0.82, f);
    vec3 nebulaCol = mix(cDeep, cCloud1, cloudWeight);
    nebulaCol = mix(nebulaCol, cCloud2, smoothstep(0.45, 0.92, f * length(r)));

    // 4. 核心脉冲光晕与边缘暗角
    float centerDist = length(uv);
    float corePulse = exp(-centerDist * 2.2) * (0.35 + uBass * 0.55);
    nebulaCol += mix(cCloud1, cCloud2, sin(uTime * 0.5) * 0.5 + 0.5) * corePulse;

    // 注入闪烁星光
    nebulaCol += vec3(0.95, 0.98, 1.0) * starGlow;

    // 柔和径向边缘衰减
    float vignette = smoothstep(1.4, 0.35, centerDist);
    nebulaCol *= vignette;

    float alpha = clamp(cloudWeight + corePulse + starGlow, 0.0, 1.0);
    fragColor = vec4(nebulaCol, alpha);
}
