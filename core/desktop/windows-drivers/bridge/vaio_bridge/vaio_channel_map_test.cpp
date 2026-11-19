// vaio_channel_map_test.cpp — VaioChannelMap.h 数值单测（驱动无关）。
//
// 第五十四轮回归：离散截断的位置映射（引擎 4ch=Quad 在 7.1 流
// 取 7/8 声道、在 5.1 流取 5/6 声道）与丢弃语义（gather 不取、
// scatter 整帧清零后只回写映射位置）。每声道填下标+1 作标记值，
// 逐位比对。由 smoke_vaio_channel_map.py 驱动。
#include <cstdio>

#include "VaioChannelMap.h"

static int g_fail = 0;

static void Check(const char* name, bool ok) {
    std::printf("%s  %s\n", ok ? "PASS" : "FAIL", name);
    if (!ok) ++g_fail;
}

static bool FrameEq(const float* got, const float* want, int n) {
    for (int i = 0; i < n; ++i) {
        if (got[i] != want[i]) return false;
    }
    return true;
}

int main() {
    // ---- 位置表 ----
    Check("pos eng4/strm8 rear -> 6,7",
          VaioEngChStreamPos(4, 8, 2) == 6 && VaioEngChStreamPos(4, 8, 3) == 7);
    Check("pos eng4/strm6 rear -> 4,5",
          VaioEngChStreamPos(4, 6, 2) == 4 && VaioEngChStreamPos(4, 6, 3) == 5);
    Check("pos eng4 front identity",
          VaioEngChStreamPos(4, 8, 0) == 0 && VaioEngChStreamPos(4, 8, 1) == 1);
    Check("pos eng6/strm8 identity",
          VaioEngChStreamPos(6, 8, 4) == 4 && VaioEngChStreamPos(6, 8, 5) == 5);
    Check("pos eng2/strm8 identity",
          VaioEngChStreamPos(2, 8, 0) == 0 && VaioEngChStreamPos(2, 8, 1) == 1);
    Check("pos eng8 identity",
          VaioEngChStreamPos(8, 8, 6) == 6 && VaioEngChStreamPos(8, 8, 7) == 7);

    // ---- gather：流标记值 = 下标+1 ----
    {
        const float s8[8] = {1, 2, 3, 4, 5, 6, 7, 8};
        float d[8] = {};
        VaioTruncateGather(s8, 8, d, 4, 1);
        const float want[4] = {1, 2, 7, 8};  // FL,FR,BL,BR（第 7/8 声道）
        Check("gather 8->4 takes ch 1,2,7,8", FrameEq(d, want, 4));
    }
    {
        const float s6[6] = {1, 2, 3, 4, 5, 6};
        float d[4] = {};
        VaioTruncateGather(s6, 6, d, 4, 1);
        const float want[4] = {1, 2, 5, 6};  // FL,FR,SL,SR 位
        Check("gather 6->4 takes ch 1,2,5,6", FrameEq(d, want, 4));
    }
    {
        const float s8[8] = {1, 2, 3, 4, 5, 6, 7, 8};
        float d[8] = {};
        VaioTruncateGather(s8, 8, d, 6, 1);
        const float want[6] = {1, 2, 3, 4, 5, 6};
        Check("gather 8->6 takes first six", FrameEq(d, want, 6));
        VaioTruncateGather(s8, 8, d, 2, 1);
        const float want2[2] = {1, 2};
        Check("gather 8->2 takes FL,FR", FrameEq(d, want2, 2));
    }

    // ---- scatter：引擎值回写到映射位置，其余清零 ----
    {
        const float e4[4] = {10, 20, 30, 40};
        float d[8];
        for (float& v : d) v = 99.0f;  // 预填脏值，scatter 必须整帧清零
        VaioTruncateScatter(e4, 4, d, 8, 1);
        const float want[8] = {10, 20, 0, 0, 0, 0, 30, 40};
        Check("scatter 4->8 writes pos 1,2,7,8 only", FrameEq(d, want, 8));
    }
    {
        const float e4[4] = {10, 20, 30, 40};
        float d[6];
        for (float& v : d) v = 99.0f;
        VaioTruncateScatter(e4, 4, d, 6, 1);
        const float want[6] = {10, 20, 0, 0, 30, 40};
        Check("scatter 4->6 writes pos 1,2,5,6 only", FrameEq(d, want, 6));
    }
    {
        const float e6[6] = {10, 20, 30, 40, 50, 60};
        float d[8];
        for (float& v : d) v = 99.0f;
        VaioTruncateScatter(e6, 6, d, 8, 1);
        const float want[8] = {10, 20, 30, 40, 50, 60, 0, 0};
        Check("scatter 6->8 writes first six", FrameEq(d, want, 8));
    }

    std::printf(g_fail == 0 ? "ALL PASS\n" : "FAILURES: %d\n", g_fail);
    return g_fail == 0 ? 0 : 1;
}
