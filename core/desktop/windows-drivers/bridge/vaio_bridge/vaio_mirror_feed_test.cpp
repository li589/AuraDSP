// vaio_mirror_feed_test.cpp — 监听镜像喂流规划验收（驱动无关）。
//
// 背景（ASIO-2 补全，2026-11-14）：监听镜像是 VAIO 桥的第二路
// WASAPI 渲染。主路时钟驱动泵，镜像端点时钟/采样率独立，喂流
// 规划（VaioMirrorFeed.h）必须保证：
//   · 采样率归一长期不漂移（分数相位跨块携带，总量守恒 ±1 帧）；
//   · 镜像缓冲不足时丢弃计数精确、绝不超写可用量；
//   · 边界输入（0 帧 / 0 可用 / 非法 ratio）不产出、不崩。
//
// 输出：末行单行 JSON（smoke_vaio_mirror_feed.py 消费）。
// 退出码 0 = 全过。
#include <cstdio>

#include "VaioMirrorFeed.h"

namespace {

int g_fail = 0;
int g_pass = 0;

void Check(bool ok, const char* what) {
    if (ok) {
        ++g_pass;
        std::printf("ok   %s\n", what);
    } else {
        ++g_fail;
        std::printf("FAIL %s\n", what);
    }
}

bool NearU64(uint64_t v, uint64_t expect, uint64_t tol) {
    return v >= expect - tol && v <= expect + tol;
}

}  // namespace

int main() {
    // [1] 同率直通：每块原样产出，无丢弃、无相位残留。
    {
        VaioMirrorFeed f;
        bool allExact = true;
        for (int i = 0; i < 100; ++i) {
            if (f.Plan(512, 1.0, 100000) != 512) allExact = false;
        }
        Check(allExact, "ratio 1.0: every block plans exactly inFrames");
        Check(f.fed == 51200, "ratio 1.0: fed totals 51200");
        Check(f.drops == 0, "ratio 1.0: zero drops");
        Check(f.phase == 0.0, "ratio 1.0: phase stays 0");
    }

    // [2] 降采样 48000 → 44100：总量守恒（±1 帧），不丢弃。
    {
        VaioMirrorFeed f;
        const double ratio = 44100.0 / 48000.0;
        for (int i = 0; i < 480; ++i) f.Plan(512, ratio, 100000);
        // 480 × 512 × 44100/48000 = 225792 恰整（相位应回 0 附近）。
        Check(NearU64(f.fed, 225792, 1), "48k->44.1k: fed ~= 225792 (+/-1)");
        Check(f.drops == 0, "48k->44.1k: zero drops with ample avail");
        Check(f.phase >= 0.0 && f.phase < 1.0, "48k->44.1k: phase in [0,1)");
    }

    // [3] 升采样 44100 → 48000：总量守恒（±1 帧）。
    {
        VaioMirrorFeed f;
        const double ratio = 48000.0 / 44100.0;
        for (int i = 0; i < 441; ++i) f.Plan(441, ratio, 100000);
        // 441 × 441 × 48000/44100 = 211680 恰整。
        Check(NearU64(f.fed, 211680, 1), "44.1k->48k: fed ~= 211680 (+/-1)");
        Check(f.drops == 0, "44.1k->48k: zero drops with ample avail");
    }

    // [4] 缓冲钳制：产出截断到可用量，差额精确计入 drops。
    {
        VaioMirrorFeed f;
        const uint32_t out = f.Plan(512, 1.0, 100);
        Check(out == 100, "clamp: plans only avail frames");
        Check(f.drops == 412, "clamp: drops == shortfall 412");
        Check(f.fed == 100, "clamp: fed counts only written frames");
        const uint32_t out2 = f.Plan(512, 1.0, 1000);
        Check(out2 == 512 && f.drops == 412 && f.fed == 612,
              "clamp: recovers fully once avail returns");
    }

    // [5] 可用为 0 的持续饥饿：不产出，丢弃逐块累加。
    {
        VaioMirrorFeed f;
        bool allZero = true;
        for (int i = 0; i < 10; ++i) {
            if (f.Plan(512, 1.0, 0) != 0) allZero = false;
        }
        Check(allZero, "starved: plans 0 while avail is 0");
        Check(f.drops == 5120 && f.fed == 0,
              "starved: all frames accounted as drops");
    }

    // [6] 边界：0 帧输入与非法 ratio 不产出、不改状态。
    {
        VaioMirrorFeed f;
        Check(f.Plan(0, 1.0, 1000) == 0, "edge: zero inFrames plans 0");
        Check(f.Plan(512, 0.0, 1000) == 0, "edge: zero ratio plans 0");
        Check(f.Plan(512, -1.0, 1000) == 0, "edge: negative ratio plans 0");
        Check(f.fed == 0 && f.drops == 0 && f.phase == 0.0,
              "edge: state untouched by degenerate calls");
    }

    // [7] 小块节奏：1 帧块在降采样下靠相位攒帧，不丢不重。
    {
        VaioMirrorFeed f;
        const double ratio = 44100.0 / 48000.0;
        uint64_t total = 0;
        for (int i = 0; i < 48000; ++i) total += f.Plan(1, ratio, 100000);
        Check(NearU64(total, 44100, 1),
              "tiny blocks: 48000 x 1f @44.1k/48k ~= 44100 (+/-1)");
        Check(f.drops == 0, "tiny blocks: zero drops");
    }

    std::printf("{\"ok\":%s,\"pass\":%d,\"fail\":%d}\n",
                g_fail == 0 ? "true" : "false", g_pass, g_fail);
    return g_fail == 0 ? 0 : 1;
}
