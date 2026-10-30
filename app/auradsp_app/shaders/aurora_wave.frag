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
    vec2 pos = FlutterFragCoord().xy / uResolution.xy;
    vec2 p = (pos - 0.5) * 2.0;
    p.x *= uResolution.x / uResolution.y;

    float wave1 = sin(p.x * 2.5 + uTime * 1.5) * (0.15 + uBass * 0.35);
    float wave2 = sin(p.x * 5.0 - uTime * 2.0) * (0.08 + uMid * 0.25);
    float wave3 = cos(p.x * 8.0 + uTime * 3.0) * (0.04 + uTreble * 0.2);

    float totalWave = wave1 + wave2 + wave3;
    float dist = abs(p.y - totalWave);

    float intensity = 0.028 / (dist + 0.016);
    intensity = clamp(intensity, 0.0, 1.0);

    vec4 col = mix(uColor1, uColor2, sin(p.x * 1.5 + uTime) * 0.5 + 0.5);
    fragColor = vec4(col.rgb * intensity, intensity * col.a);
}

