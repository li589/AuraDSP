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
    // 归一化中心视口坐标 (以短边为基准，保持严格宽高比)
    vec2 uv = (FlutterFragCoord().xy - 0.5 * uResolution.xy) / min(uResolution.x, uResolution.y);
    // Flutter 坐标系 y 轴朝下，取负使得 +y 为天空，-y 为地面
    uv.y = -uv.y;

    // 1. 摄像机微抬高俯视视角 (仰俯舒适，保证风暴始终居中不跑出视口)
    vec3 ro = vec3(0.0, 0.42, 2.45);
    vec3 ta = vec3(0.0, -0.15, 0.0);
    vec3 ww = normalize(ta - ro);
    vec3 uu = normalize(cross(ww, vec3(0.0, 1.0, 0.0)));
    vec3 vv = cross(uu, ww);
    vec3 rd = normalize(uv.x * uu + uv.y * vv + 1.55 * ww);

    // 2. 背景自然柔和渐变色晕 (消除突变，随时间平缓正弦呼吸)
    float bgPhase = uTime * 0.18;
    vec3 bgBlend = mix(uColor1.rgb, uColor2.rgb, sin(bgPhase) * 0.5 + 0.5);
    float bgDist = length(uv - vec2(0.0, -0.1));
    float bgGlow = exp(-bgDist * 1.7) * (0.10 + 0.04 * sin(uTime * 0.4));
    float vignette = smoothstep(1.3, 0.25, length(uv));
    vec3 col = bgBlend * bgGlow * vignette;

    // 3. 确定性 3D 漏斗形粒子风暴体渲染 (大口在上、小头在下)
    vec3 accCol = vec3(0.0);
    float accAlpha = 0.0;

    // 恒定步长光线步进 (固定 36 步，确保全平台高帧率与极低 GPU 负载)
    const int STEPS = 36;
    float t = 1.35;
    float dt = 0.06;

    float spinSpeed = 2.8 + uBass * 2.2;

    for (int i = 0; i < STEPS; ++i) {
        if (accAlpha >= 0.95) break;

        vec3 p = ro + t * rd;
        t += dt;

        // 高度约束：[-0.95, 1.15]
        if (p.y < -0.95 || p.y > 1.15) continue;

        // 漏斗半径函数：下端收敛为基点 (0.06)，上端平缓展开为大口 (0.62)
        float hNorm = clamp((p.y + 0.95) / 2.1, 0.0, 1.0);
        float targetR = 0.06 + 0.56 * pow(hNorm, 1.32);

        float rXZ = length(p.xz);
        float dWall = abs(rXZ - targetR);

        // 风暴壁高斯厚度衰减
        float wall = exp(-dWall * 16.0);

        // 极角旋转与螺旋粒子流：流纹只是载体，必须再被沿流向的
        // 脉冲门控切成离散亮点才是「粒子」——连续螺旋带经 36 步
        // 累积会织成网格（2026-11-23 晚 user 目检定罪：整屏绿色
        // 网格波纹、看不到粒子）。
        float theta = atan(p.z, p.x);
        float spiral1 = theta * 3.0 - p.y * 6.5 + uTime * spinSpeed;
        float stream1 = pow(0.5 + 0.5 * sin(spiral1), 3.0);
        float beads1 = pow(0.5 + 0.5 * sin(p.y * 24.0 - uTime * (spinSpeed * 1.35) + spiral1 * 2.0), 6.0);
        stream1 *= 0.25 + 0.75 * beads1;

        float spiral2 = theta * 8.0 + p.y * 14.0 - uTime * (spinSpeed * 1.5);
        float stream2 = pow(max(0.0, sin(spiral2)), 6.0);
        float beads2 = pow(0.5 + 0.5 * sin(p.y * 40.0 - uTime * (spinSpeed * 2.0) + spiral2 * 2.0), 8.0);
        stream2 *= (0.2 + 0.8 * beads2) * (1.0 + uMid * 1.8);

        // 高频微尘：哈希网格圆点（离散火花，随壁面旋转、缓慢
        // 上升；周向恰 36 格保证 atan 接缝处格界对齐）
        vec2 cellUv = vec2(theta * 5.7296 + uTime * spinSpeed * 1.9099,
                           p.y * 16.0 - uTime * 0.7);
        vec2 cellId = floor(cellUv);
        vec2 cellF = fract(cellUv) - 0.5;
        float cellHash = fract(sin(dot(cellId, vec2(127.1, 311.7))) * 43758.5453);
        float mote = smoothstep(0.42, 0.05, length(cellF)) * step(0.72, cellHash);
        float sparks = mote * (0.8 + uTreble * 3.0);

        // 顶部与底部平滑羽化 (防止硬截断边缘)
        float vEnvelope = smoothstep(-0.95, -0.65, p.y) * smoothstep(1.15, 0.85, p.y);

        // 密度合成（2026-11-23 修复）：螺旋流纹与火花必须被漏斗
        // 壁面门控——旧式把角向图案在整个体积内无门控叠加，36 步
        // 累积后饱和成实心条纹柱（用户报「完全是乱七八糟」）。
        // 改后流纹只活在壁面薄壳上，柱内与柱外保持通透。
        // 2026-11-23 晚再修：常数底噪 0.45 降至 0.07——旧值让薄壳
        // 本身在 36 步累积下饱和发白，亮度改由离散粒子点承载，
        // 壁面只留 faint 轮廓。
        float density = wall * (0.07 + stream1 * 0.75 + stream2 * 1.1 + sparks * 1.8) * vEnvelope;

        if (density > 0.01) {
            // 色彩沿漏斗高度与流束平滑过渡
            vec3 sliceColor = mix(uColor1.rgb, uColor2.rgb, hNorm * 0.75 + stream1 * 0.25);
            sliceColor += vec3(0.9, 0.95, 1.0) * sparks * 0.5; // 火花高光

            float alpha = clamp(density * 0.12, 0.0, 1.0);
            accCol += sliceColor * alpha * (1.0 - accAlpha);
            accAlpha += alpha * (1.0 - accAlpha);
        }
    }

    // 4. 背景色与风暴体前向融合
    col += accCol;

    // 输出最终预乘色彩 (与 Flutter Canvas 混合兼容)
    fragColor = vec4(col, clamp(accAlpha + bgGlow * 1.2, 0.0, 1.0));
}
