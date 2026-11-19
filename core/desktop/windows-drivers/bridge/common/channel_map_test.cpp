// channel_map_test.cpp — engine/chain/channel_map.h 数值单测。
//
// 第五十五轮：声道适配统一表的回归守卫（位置映射、离散
// gather/scatter、矩阵下混全表）。重点哨：8→4 折叠主次——
// BL/BR 必须原量、SL/SR 乘 k 折入（r47 定案、r55 在 VAIO
// 侧纠偏后由本表统一）。标记值 = 下标+1，折叠项按 k 加权，
// 浮点比较容差 1e-6。由 smoke_channel_map.py 驱动。
#include <cmath>
#include <cstdio>

#include "chain/channel_map.h"

static int g_fail = 0;

static void Check(const char* name, bool ok) {
    std::printf("%s  %s\n", ok ? "PASS" : "FAIL", name);
    if (!ok) ++g_fail;
}

static bool Near(float a, float b) { return std::fabs(a - b) < 1e-6f; }

static bool FrameNear(const float* got, const float* want, int n) {
    for (int i = 0; i < n; ++i) {
        if (!Near(got[i], want[i])) return false;
    }
    return true;
}

int main() {
    const float k = kChmapFoldK;

    // ---- 位置表 ----
    Check("pos eng4/strm8 rear -> 6,7",
          chmap_stream_pos(4, 8, 2) == 6 && chmap_stream_pos(4, 8, 3) == 7);
    Check("pos eng4/strm6 rear -> 4,5",
          chmap_stream_pos(4, 6, 2) == 4 && chmap_stream_pos(4, 6, 3) == 5);
    Check("pos eng4 front identity",
          chmap_stream_pos(4, 8, 0) == 0 && chmap_stream_pos(4, 8, 1) == 1);
    Check("pos eng6/strm8 identity",
          chmap_stream_pos(6, 8, 4) == 4 && chmap_stream_pos(6, 8, 5) == 5);
    Check("pos eng2/strm8 identity",
          chmap_stream_pos(2, 8, 0) == 0 && chmap_stream_pos(2, 8, 1) == 1);
    Check("pos eng8 identity",
          chmap_stream_pos(8, 8, 6) == 6 && chmap_stream_pos(8, 8, 7) == 7);

    // ---- 离散 gather/scatter ----
    {
        const float s8[8] = {1, 2, 3, 4, 5, 6, 7, 8};
        float d[8] = {};
        chmap_gather_discrete(s8, 8, d, 4, 1);
        const float want[4] = {1, 2, 7, 8};
        Check("gather 8->4 takes ch 1,2,7,8", FrameNear(d, want, 4));
        chmap_gather_discrete(s8, 8, d, 6, 1);
        const float want6[6] = {1, 2, 3, 4, 5, 6};
        Check("gather 8->6 takes first six", FrameNear(d, want6, 6));
    }
    {
        const float s6[6] = {1, 2, 3, 4, 5, 6};
        float d[4] = {};
        chmap_gather_discrete(s6, 6, d, 4, 1);
        const float want[4] = {1, 2, 5, 6};
        Check("gather 6->4 takes ch 1,2,5,6", FrameNear(d, want, 4));
    }
    {
        const float e4[4] = {10, 20, 30, 40};
        float d[8];
        for (float& v : d) v = 99.0f;
        chmap_scatter_discrete(e4, 4, d, 8, 1);
        const float want[8] = {10, 20, 0, 0, 0, 0, 30, 40};
        Check("scatter 4->8 writes pos 1,2,7,8 only", FrameNear(d, want, 8));
        float d6[6];
        for (float& v : d6) v = 99.0f;
        chmap_scatter_discrete(e4, 4, d6, 6, 1);
        const float want6[6] = {10, 20, 0, 0, 30, 40};
        Check("scatter 4->6 writes pos 1,2,5,6 only", FrameNear(d6, want6, 6));
    }

    // ---- 矩阵下混 ----
    {
        const float s8[8] = {1, 2, 3, 4, 5, 6, 7, 8};
        float d[8] = {};
        chmap_fold_frame(s8, 8, d, 6);
        const float w6[6] = {1, 2, 3, 4, 5 + 7 * k, 6 + 8 * k};
        Check("fold 8->6: BL/BR fold into SL/SR", FrameNear(d, w6, 6));
        chmap_fold_frame(s8, 8, d, 4);
        const float w4[4] = {1 + 3 * k, 2 + 3 * k, 7 + 5 * k, 8 + 6 * k};
        Check("fold 8->4: BL/BR primary, SL/SR folded", FrameNear(d, w4, 4));
        chmap_fold_frame(s8, 8, d, 2);
        const float w2[2] = {1 + (3 + 5 + 7) * k, 2 + (3 + 6 + 8) * k};
        Check("fold 8->2: all but LFE fold", FrameNear(d, w2, 2));
    }
    {
        const float s6[6] = {1, 2, 3, 4, 5, 6};
        float d[6] = {};
        chmap_fold_frame(s6, 6, d, 4);
        const float w4[4] = {1 + 3 * k, 2 + 3 * k, 5, 6};
        Check("fold 6->4: SL/SR land on BL/BR at unity", FrameNear(d, w4, 4));
        chmap_fold_frame(s6, 6, d, 2);
        const float w2[2] = {1 + (3 + 5) * k, 2 + (3 + 6) * k};
        Check("fold 6->2", FrameNear(d, w2, 2));
    }
    {
        const float s4[4] = {1, 2, 3, 4};
        float d[4] = {};
        chmap_fold_frame(s4, 4, d, 2);
        const float w2[2] = {1 + 3 * k, 2 + 4 * k};
        Check("fold 4->2: BL/BR fold into L/R", FrameNear(d, w2, 2));
        chmap_fold_frame(s4, 4, d, 4);
        Check("fold 4->4 is copy", FrameNear(d, s4, 4));
    }
    {
        const float s3[3] = {1, 2, 3};
        float d[2] = {};
        chmap_fold_frame(s3, 3, d, 2);
        const float w3[2] = {1 + 3 * k, 2 + 3 * k};
        Check("fold 3->2: C folds", FrameNear(d, w3, 2));
        const float s5[5] = {1, 2, 3, 4, 5};
        chmap_fold_frame(s5, 5, d, 2);
        const float w5[2] = {1 + (3 + 4) * k, 2 + (3 + 5) * k};
        Check("fold 5->2: C/SL/SR fold, no LFE", FrameNear(d, w5, 2));
    }
    {
        // 多帧交织 fold（chmap_fold 帧循环）
        const float s[16] = {1, 2, 3, 4, 5, 6, 7, 8,
                             8, 7, 6, 5, 4, 3, 2, 1};
        float d[8] = {};
        chmap_fold(s, 8, d, 4, 2);
        const float w[8] = {1 + 3 * k, 2 + 3 * k, 7 + 5 * k, 8 + 6 * k,
                            8 + 6 * k, 7 + 6 * k, 2 + 4 * k, 1 + 3 * k};
        Check("fold 8->4 x2 frames interleaved", FrameNear(d, w, 8));
    }

    std::printf(g_fail == 0 ? "ALL PASS\n" : "FAILURES: %d\n", g_fail);
    return g_fail == 0 ? 0 : 1;
}
