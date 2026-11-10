// apo_plan_test.cpp — 安装计划解析矩阵单测（计划书 Part II W1）。
//
// apo_install_plan.h 是纯逻辑：模式 × --only × 端点方向 × OS 代际
// → 写集合/清理集合。本宿主把矩阵钉死，重点是两条纪律：
//  ① 全量（无 --only）各模式的写集合与 W1 之前的既有行为一致
//     （回归基线，不许借重构偷改默认安装形态）；
//  ② foreignIdx 恒等于「全部位置槽 − 本次写槽」（跨模式清理的
//     完备性：任何模式切换都不留其他代际残留）。
// 退出码：0=全 PASS，1=有 FAIL（CI J5b 实跑）。
#include <algorithm>
#include <cstdio>
#include <string>
#include <vector>

#include "apo_install_plan.h"

namespace {

int g_fail = 0;

std::string Join(const std::vector<int>& v) {
    std::string s = "{";
    for (size_t i = 0; i < v.size(); ++i) {
        if (i) s += ",";
        s += std::to_string(v[i]);
    }
    return s + "}";
}

void Expect(const char* name, const std::vector<int>& got,
            const std::vector<int>& want) {
    const bool ok = got == want;
    printf("[%s] %s got=%s want=%s\n", ok ? "PASS" : "FAIL", name,
           Join(got).c_str(), Join(want).c_str());
    if (!ok) ++g_fail;
}

void ExpectBool(const char* name, bool got, bool want) {
    printf("[%s] %s got=%d want=%d\n", got == want ? "PASS" : "FAIL",
           name, got ? 1 : 0, want ? 1 : 0);
    if (got != want) ++g_fail;
}

// foreignIdx 完备性：与写集合不交、并集为全部位置槽 {1..8}。
void ExpectForeignComplete(const char* name,
                           const apoplan::InstallPlan& p) {
    std::vector<int> all = p.foreignIdx;
    all.insert(all.end(), p.singleIdx.begin(), p.singleIdx.end());
    all.insert(all.end(), p.multiIdx.begin(), p.multiIdx.end());
    std::sort(all.begin(), all.end());
    Expect(name, all, {1, 2, 3, 4, 5, 6, 7, 8});
}

using apoplan::Only;
using apoplan::ResolveInstallPlan;

}  // namespace

int main() {
    // ---- 回归基线：全量安装（render, Win10）与 W1 前行为一致 ----
    {
        auto p = ResolveInstallPlan(L"sfx-efx", Only::None, false, false);
        Expect("sfx-efx singles", p.singleIdx, {3, 4, 5});
        Expect("sfx-efx proc", p.procModePos, {5, 6, 7});
        ExpectForeignComplete("sfx-efx foreign complete", p);
    }
    {
        auto p = ResolveInstallPlan(L"composite", Only::None, false, false);
        Expect("composite multi", p.multiIdx, {6, 7});
        Expect("composite proc", p.procModePos, {5, 6, 7});
        ExpectForeignComplete("composite foreign complete", p);
    }
    {
        auto p = ResolveInstallPlan(L"win7-sapo", Only::None, false, false);
        Expect("win7-sapo@win10 singles", p.singleIdx, {1, 2});
        Expect("win7-sapo@win10 proc", p.procModePos, {5, 6, 7});
    }
    {
        auto p = ResolveInstallPlan(L"win7-sapo", Only::None, false, true);
        Expect("win7-sapo@win7 proc", p.procModePos, {});
    }
    {
        // Win7 OS 上 sfx-efx 被强制改写为 win7-sapo（既有行为）。
        auto p = ResolveInstallPlan(L"sfx-efx", Only::None, false, true);
        ExpectBool("win7 coerce mode", p.mode == L"win7-sapo", true);
        Expect("win7 coerce singles", p.singleIdx, {1, 2});
        Expect("win7 coerce proc", p.procModePos, {});
    }
    {
        auto p = ResolveInstallPlan(L"sfx-only", Only::None, false, false);
        Expect("sfx-only singles", p.singleIdx, {3});
        Expect("sfx-only proc", p.procModePos, {5, 6, 7});
    }
    {
        // 未知模式沿既有回退：槽位按 sfx-efx，模式名原样保留。
        auto p = ResolveInstallPlan(L"bogus", Only::None, false, false);
        Expect("bogus singles", p.singleIdx, {3, 4, 5});
        ExpectBool("bogus mode kept", p.mode == L"bogus", true);
    }

    // ---- --only 前后混独立 ----
    {
        auto p = ResolveInstallPlan(L"sfx-efx", Only::Pre, false, false);
        Expect("sfx-efx pre singles", p.singleIdx, {3});
        Expect("sfx-efx pre proc", p.procModePos, {5});
        ExpectForeignComplete("sfx-efx pre foreign complete", p);
    }
    {
        auto p = ResolveInstallPlan(L"sfx-efx", Only::Post, false, false);
        Expect("sfx-efx post singles", p.singleIdx, {4, 5});
        Expect("sfx-efx post proc", p.procModePos, {6, 7});
    }
    {
        auto p = ResolveInstallPlan(L"win7-sapo", Only::Pre, false, false);
        Expect("win7-sapo pre singles", p.singleIdx, {1});
        Expect("win7-sapo pre proc", p.procModePos, {});
    }
    {
        auto p = ResolveInstallPlan(L"win7-sapo", Only::Post, false, false);
        Expect("win7-sapo post singles", p.singleIdx, {2});
    }
    {
        auto p = ResolveInstallPlan(L"composite", Only::Pre, false, false);
        Expect("composite pre multi", p.multiIdx, {6});
        Expect("composite pre proc", p.procModePos, {5});
    }
    {
        auto p = ResolveInstallPlan(L"composite", Only::Post, false, false);
        Expect("composite post multi", p.multiIdx, {7});
        Expect("composite post proc", p.procModePos, {6, 7});
    }
    {
        auto p = ResolveInstallPlan(L"sfx-only", Only::Post, false, false);
        ExpectBool("sfx-only+post invalid", p.valid, false);
    }

    // ---- 捕获端点：默认只装 pre，显式 post 以操作者为准 ----
    {
        auto p = ResolveInstallPlan(L"sfx-efx", Only::None, true, false);
        ExpectBool("capture preonly flag", p.capturePreOnly, true);
        Expect("capture singles", p.singleIdx, {3});
        Expect("capture proc", p.procModePos, {5});
    }
    {
        auto p = ResolveInstallPlan(L"sfx-efx", Only::Post, true, false);
        ExpectBool("capture explicit post flag", p.capturePreOnly, false);
        Expect("capture explicit post singles", p.singleIdx, {4, 5});
    }
    {
        auto p = ResolveInstallPlan(L"composite", Only::None, true, false);
        Expect("capture composite multi", p.multiIdx, {6});
    }

    // ---- W2 状态推断 ----
    const std::wstring OURS = L"{415AD8ED-7A45-4F4F-AC69-043830EBC174}";
    const std::wstring OURS_LO = L"{415ad8ed-7a45-4f4f-ac69-043830ebc174}";
    const std::wstring VENDOR = L"{11111111-2222-3333-4444-555555555555}";
    const std::wstring VENDOR2 = L"{66666666-7777-8888-9999-000000000000}";
    using apoplan::InferInstallState;
    using apoplan::RecommendMode;
    using apoplan::SlotOccupancy;
    {
        SlotOccupancy o;
        auto inf = InferInstallState(o, OURS);
        ExpectBool("infer empty mode", inf.mode.empty(), true);
        ExpectBool("infer empty ours", inf.oursAnywhere, false);
    }
    {
        SlotOccupancy o;
        o.sfx = OURS; o.mfx = OURS; o.efx = OURS;
        auto inf = InferInstallState(o, OURS);
        ExpectBool("infer sfx-efx", inf.mode == L"sfx-efx", true);
        ExpectBool("infer sfx-efx pre", inf.oursPre, true);
        ExpectBool("infer sfx-efx post", inf.oursPost, true);
    }
    {
        SlotOccupancy o;
        o.lfx = OURS_LO; o.gfx = OURS_LO;  // 大小写不敏感
        auto inf = InferInstallState(o, OURS);
        ExpectBool("infer win7-sapo ci", inf.mode == L"win7-sapo", true);
    }
    {
        SlotOccupancy o;
        o.compSfx = {VENDOR, OURS};
        auto inf = InferInstallState(o, OURS);
        ExpectBool("infer composite", inf.mode == L"composite", true);
        ExpectBool("infer composite origPre",
                   inf.originalPre == VENDOR, true);
    }
    {
        SlotOccupancy o;
        o.sfx = OURS;
        auto inf = InferInstallState(o, OURS);
        ExpectBool("infer sfx-only", inf.mode == L"sfx-only", true);
    }
    {
        SlotOccupancy o;
        o.mfx = OURS; o.efx = OURS;
        auto inf = InferInstallState(o, OURS);
        ExpectBool("infer partial", inf.mode == L"partial", true);
        ExpectBool("infer partial post only",
                   inf.oursPost && !inf.oursPre, true);
    }
    {
        // 跨代原厂：流侧 SFX 被我方占、原厂在 LFX；设备侧同代
        // MFX 优先于跨代 GFX。
        SlotOccupancy o;
        o.sfx = OURS; o.lfx = VENDOR;
        o.mfx = VENDOR; o.gfx = VENDOR2;
        auto inf = InferInstallState(o, OURS);
        ExpectBool("infer xgen pre", inf.originalPre == VENDOR, true);
        ExpectBool("infer xgen post priority",
                   inf.originalPost == VENDOR, true);
    }

    // ---- W2 推荐档 ----
    {
        SlotOccupancy o;
        ExpectBool("rec win7 os",
                   RecommendMode(o, false, OURS) == L"win7-sapo", true);
        ExpectBool("rec empty",
                   RecommendMode(o, true, OURS) == L"sfx-efx", true);
    }
    {
        SlotOccupancy o;
        o.compMfx = {VENDOR};
        ExpectBool("rec composite",
                   RecommendMode(o, true, OURS) == L"composite", true);
    }
    {
        SlotOccupancy o;
        o.efx = VENDOR;
        ExpectBool("rec sfx gen",
                   RecommendMode(o, true, OURS) == L"sfx-efx", true);
    }
    {
        SlotOccupancy o;
        o.lfx = VENDOR;
        ExpectBool("rec legacy only",
                   RecommendMode(o, true, OURS) == L"win7-sapo", true);
    }

    // ---- W2 快照版本 ----
    using apoplan::SnapshotVersionSupported;
    ExpectBool("ver empty ok", SnapshotVersionSupported(L""), true);
    ExpectBool("ver 1 ok", SnapshotVersionSupported(L"1"), true);
    ExpectBool("ver 2 ok", SnapshotVersionSupported(L"2"), true);
    ExpectBool("ver 3 rejected", SnapshotVersionSupported(L"3"), false);
    ExpectBool("ver junk ok", SnapshotVersionSupported(L"abc"), true);

    printf("apo_plan_test: %s (%d failures)\n",
           g_fail == 0 ? "PASS" : "FAIL", g_fail);
    return g_fail == 0 ? 0 : 1;
}
