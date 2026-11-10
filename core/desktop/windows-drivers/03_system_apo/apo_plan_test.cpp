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

    printf("apo_plan_test: %s (%d failures)\n",
           g_fail == 0 ? "PASS" : "FAIL", g_fail);
    return g_fail == 0 ? 0 : 1;
}
