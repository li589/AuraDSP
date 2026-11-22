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

void main() {
    vec2 uv = (FlutterFragCoord().xy - 0.5 * uResolution.xy) / min(uResolution.x, uResolution.y);

    float r = length(uv);
    float theta = atan(uv.y, uv.x);

    // 1. 极坐标对称谐波射线 (32 束对称分布，由中频与高频驱动长度)
    float raysCount = 32.0;
    float rayAngle = theta * (raysCount * 0.5);
    float rayPattern = pow(max(0.0, cos(rayAngle + uTime * 0.4)), 8.0);

    // 射线径向长度区间：内径 baseR 到外径 maxR
    float baseR = 0.16 + uBass * 0.08;
    float rayLength = 0.28 + (uMid * 0.35 + uTreble * 0.25);
    float rayMask = smoothstep(baseR, baseR + 0.02, r) * smoothstep(baseR + rayLength, baseR + rayLength - 0.04, r);

    vec3 rayColor = uColor1.rgb * rayPattern * rayMask * 1.8;

    // 2. 核心同心脉冲波纹 (随低频向外扩散的冲击波)
    float wavePhase = r * 28.0 - uTime * 4.5 - uBass * 3.5;
    float ripple = pow(0.5 + 0.5 * sin(wavePhase), 4.0) * smoothstep(0.7, 0.15, r);
    vec3 rippleColor = uColor2.rgb * ripple * (0.35 + uBass * 0.65);

    // 3. 中心能量核脉冲辉光
    float coreGlow = exp(-r * 6.5) * (0.8 + uBass * 1.2);
    vec3 coreColor = mix(uColor1.rgb, uColor2.rgb, 0.5 + 0.5 * sin(uTime)) * coreGlow;

    // 4. 背景柔和呼吸光晕 (随时间持续缓动，消除跳跃阶跃感)
    float bgPhase = uTime * 0.22;
    vec3 bgBlend = mix(uColor1.rgb, uColor2.rgb, 0.5 + 0.5 * cos(bgPhase));
    float bgHalo = exp(-r * 2.2) * (0.12 + 0.04 * sin(uTime * 0.6));
    float vignette = smoothstep(1.2, 0.3, r);

    // 5. 颜色合成
    vec3 finalCol = bgBlend * bgHalo * vignette + rayColor + rippleColor + coreColor;

    float alpha = clamp(rayMask * rayPattern + ripple + coreGlow + bgHalo * 1.5, 0.0, 1.0);
    fragColor = vec4(finalCol, alpha);
}
