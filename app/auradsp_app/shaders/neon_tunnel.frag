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

    float r = length(p);
    float a = atan(p.y, p.x);

    // Audio-reactive tunnel warp
    float warp = 0.22 / (r + 0.05 + uBass * 0.12);
    float tunnel = sin(warp * 16.0 - uTime * 3.0 + a * 3.0);

    float glow = smoothstep(0.65, 1.0, tunnel) * clamp(1.0 - r * 0.55, 0.0, 1.0);
    glow += (0.025 / (r + 0.02)) * (0.3 + uBass * 0.8);

    vec4 col = mix(uColor1, uColor2, sin(a * 2.0 + uTime) * 0.5 + 0.5);
    fragColor = vec4(col.rgb * glow, clamp(glow, 0.0, 1.0) * col.a);
}

