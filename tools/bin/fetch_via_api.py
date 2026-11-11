#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""fetch_via_api.py — github.com:443 被屏蔽时的拉取兜底（sha 逐字一致）

背景：沙箱对 github.com 的封锁是间歇性的，`git fetch` / `git ls-remote` 会挂在
`Failed to connect to github.com:443`，而 `api.github.com`（gh CLI）畅通。
本脚本是 `push_via_api.py` 的对偶：用 Git Data API 把远端提交**逐字重建**成本地
对象，因此重建后的 SHA 与远端完全一致，后续 `git push` 仍是同一段历史，
不会产生分叉。

与「下载 tarball 再提交」的区别：tarball 方案拿不到提交对象，本地会生成一段
SHA 不同的平行历史，之后一推送就是 non-fast-forward。这里坚持 sha 一致。

三步：
  1. GET /git/trees/{sha} 递归补全缺失的 tree / blob（已存在的一律跳过，
     所以只下载真正新增的文件）；
  2. 用 author/committer/时间戳拼出原始提交对象文本写库，并**断言** SHA 等于
     远端 SHA——对不上就中止，绝不写入可疑历史；
  3. 更新 refs/remotes/origin/<branch>，然后外部自行 merge --ff-only。

时间戳：GitHub API 只回 UTC（`...Z`），而原始对象带提交者本地时区
（本项目为 +0800）。时区未知时按候选表逐个试算并校验 SHA，命中即止。

用法
----
    python tools/bin/fetch_via_api.py                 # 默认 feature/linux
    python tools/bin/fetch_via_api.py dev             # 显式分支
    python tools/bin/fetch_via_api.py --dry-run       # 只报告差多少，不落库

前置：git 工作区干净（脚本不改工作区，但后续 merge 需要）。
"""
import argparse
import datetime
import hashlib
import json
import os
import subprocess
import sys

OWNER_REPO_FALLBACK = ("li589", "AuraDSP")

# 时区候选：先试本项目惯用值，再覆盖常见时区（半小时制）
TZ_CANDIDATES = [
    480, 0, 540, 420, 330, 300, 60, 120, -300, -420, -480, -600, 345, 570,
]

_stats = {"api": 0, "blob": 0, "tree": 0, "commit": 0, "skip": 0}


def sh(*args, binary=False, check=True):
    argv = ["git", "-c", "core.quotePath=false"] + list(args)
    out = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if check and out.returncode != 0:
        raise RuntimeError("git %s 失败: %s" % (
            " ".join(args), out.stderr.decode("utf-8", "replace").strip()[:400]))
    return out.stdout if binary else out.stdout.decode("utf-8", "replace").strip()


def has_object(sha):
    return subprocess.run(["git", "cat-file", "-e", sha],
                          stdout=subprocess.DEVNULL,
                          stderr=subprocess.DEVNULL).returncode == 0


def gh_api(path, jq=None, raw=False):
    cmd = ["gh", "api"]
    if raw:
        cmd += ["-H", "Accept: application/vnd.github.raw"]
    if jq:
        cmd += ["--jq", jq]
    cmd.append(path)
    _stats["api"] += 1
    out = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if out.returncode != 0:
        raise RuntimeError("gh api %s 失败: %s" % (
            path, out.stderr.decode("utf-8", "replace").strip()[:400]))
    return out.stdout if raw else json.loads(out.stdout.decode("utf-8", "replace"))


def resolve_repo():
    try:
        url = sh("remote", "get-url", "origin")
    except RuntimeError:
        return OWNER_REPO_FALLBACK
    u = url.replace(".git", "")
    if u.startswith("https://") or u.startswith("http://"):
        parts = u.rstrip("/").split("/")
        return parts[-2], parts[-1]
    if u.startswith("git@"):
        tail = u.split(":", 1)[1]
        o, r = tail.split("/")
        return o, r
    return OWNER_REPO_FALLBACK


def ensure_blob(repo, sha, cache):
    if sha in cache:
        return
    cache.add(sha)
    if has_object(sha):
        _stats["skip"] += 1
        return
    raw = gh_api("repos/%s/%s/git/blobs/%s" % (repo[0], repo[1], sha), raw=True)
    got = subprocess.run(["git", "hash-object", "-w", "--stdin"],
                         input=raw, stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE)
    if got.returncode != 0:
        raise RuntimeError("写入 blob %s 失败: %s" % (
            sha, got.stderr.decode("utf-8", "replace")[:300]))
    actual = got.stdout.decode().strip()
    if actual != sha:
        raise RuntimeError("blob SHA 不一致：期望 %s，写入 %s" % (sha, actual))
    _stats["blob"] += 1


def ensure_tree(repo, sha, cache):
    if sha in cache:
        return
    cache.add(sha)
    if has_object(sha):
        _stats["skip"] += 1
        return
    data = gh_api("repos/%s/%s/git/trees/%s" % (repo[0], repo[1], sha))
    lines = []
    for e in data["tree"]:
        typ = e["type"]
        if typ == "blob":
            ensure_blob(repo, e["sha"], cache)
        elif typ == "tree":
            ensure_tree(repo, e["sha"], cache)
        # type == "commit" 是子模块 gitlink，没有对象可取
        lines.append(("%s %s %s\t%s" % (e["mode"], typ, e["sha"], e["path"]))
                     .encode("utf-8"))
    got = subprocess.run(["git", "mktree", "-z"], input=b"\x00".join(lines) + b"\x00",
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if got.returncode != 0:
        raise RuntimeError("mktree 失败: %s" % (
            got.stderr.decode("utf-8", "replace")[:400]))
    actual = got.stdout.decode().strip()
    if actual != sha:
        raise RuntimeError("tree SHA 不一致：期望 %s，得到 %s（共 %d 项）"
                           % (sha, actual, len(lines)))
    _stats["tree"] += 1


def epoch(iso):
    dt = datetime.datetime.strptime(iso, "%Y-%m-%dT%H:%M:%SZ")
    return int(dt.replace(tzinfo=datetime.timezone.utc).timestamp())


def commit_text(tree, parents, an, ae, a_ts, cn, ce, c_ts, msg):
    head = ["tree " + tree] + ["parent " + p for p in parents]
    head.append("author %s <%s> %d %s" % (an, ae, a_ts[0], a_ts[1]))
    head.append("committer %s <%s> %d %s" % (cn, ce, c_ts[0], c_ts[1]))
    return ("\n".join(head) + "\n\n" + msg).encode("utf-8")


def obj_sha(payload):
    return hashlib.sha1(b"commit %d\x00" % len(payload) + payload).hexdigest()


def fmt_tz(minutes):
    sign = "+" if minutes >= 0 else "-"
    m = abs(minutes)
    return "%s%02d%02d" % (sign, m // 60, m % 60)


def write_commit(repo, c, cache):
    target = c["sha"]
    if has_object(target):
        _stats["skip"] += 1
        return target
    ensure_tree(repo, c["tree"], cache)
    a_ep, c_ep = epoch(c["ad"]), epoch(c["cd"])
    tried = []
    # 消息尾部换行也要试：GitHub 的 commit API 会把尾随 \n 归一化掉，
    # 于是同一份改动经 push_via_api.py 推送后，远端对象比本地少一个字节。
    # 两者都试，但**仍以 SHA 命中为准**，不降低校验强度。
    for tail in ("\n", ""):
        for tz in TZ_CANDIDATES:
            payload = commit_text(c["tree"], c["parents"], c["an"], c["ae"],
                                  (a_ep, fmt_tz(tz)), c["cn"], c["ce"],
                                  (c_ep, fmt_tz(tz)), c["msg"] + tail)
            if obj_sha(payload) == target:
                got = subprocess.run(
                    ["git", "hash-object", "-w", "-t", "commit", "--stdin"],
                    input=payload, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                if got.returncode != 0:
                    raise RuntimeError("写入 commit %s 失败: %s" % (
                        target, got.stderr.decode("utf-8", "replace")[:300]))
                actual = got.stdout.decode().strip()
                if actual != target:
                    raise RuntimeError("commit SHA 不一致：期望 %s，写入 %s"
                                       % (target, actual))
                _stats["commit"] += 1
                print("  + %s  %s" % (target[:8], c["msg"].split("\n")[0][:66]))
                return target
            tried.append("%s%s" % (fmt_tz(tz), "" if tail else " 无尾换行"))
    raise RuntimeError(
        "无法还原提交 %s（提交说明：%s）。已试时区 %s；可能作者/提交者时区不同、"
        "提交带签名或消息经过改写。为避免写入与远端不一致的历史，已中止。"
        % (target, c["msg"].split("\n")[0][:60], ",".join(tried)))


def fetch_commits(repo, branch, limit_pages=10):
    """从远端 HEAD 往回收集提交，直到撞上本地已有的提交。"""
    collected, page = [], 1
    jq = ("[.[] | {sha:.sha, tree:.commit.tree.sha, "
          "parents:[.parents[].sha], "
          "an:.commit.author.name, ae:.commit.author.email, ad:.commit.author.date, "
          "cn:.commit.committer.name, ce:.commit.committer.email, "
          "cd:.commit.committer.date, msg:.commit.message, "
          "sig:.commit.verification.signature}]")
    while page <= limit_pages:
        url = "repos/%s/%s/commits?sha=%s&per_page=100&page=%d" % (
            repo[0], repo[1], branch, page)
        batch = gh_api(url, jq=jq)
        if not batch:
            break
        hit_local = False
        for c in batch:
            if has_object(c["sha"]):
                hit_local = True
                break
            collected.append(c)
        if hit_local:
            break
        page += 1
    return collected


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("branch", nargs="?", default="feature/linux")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    repo = resolve_repo()
    print("仓库 %s/%s，分支 %s" % (repo[0], repo[1], args.branch))
    todo = fetch_commits(repo, args.branch)
    if not todo:
        print("本地已包含远端 %s 的全部提交，无需拉取。" % args.branch)
        return 0

    print("远端新增 %d 个提交，本地缺口从 %s 到 %s" % (
        len(todo), todo[-1]["sha"][:8], todo[0]["sha"][:8]))
    sig = [c["sha"][:8] for c in todo if c.get("sig")]
    if sig:
        print("警告：以下提交带签名，无法逐字还原：%s" % ",".join(sig))
    if args.dry_run:
        for c in reversed(todo):
            print("  %s %s  %s" % (c["sha"][:8], c["ad"][:19],
                                   c["msg"].split("\n")[0][:70]))
        return 0

    cache = set()
    written = []
    for c in reversed(todo):  # 旧 → 新，父先于子
        written.append(write_commit(repo, c, cache))

    head = todo[0]["sha"]
    sh("update-ref", "refs/remotes/origin/%s" % args.branch, head)
    print("\n完成：写入 %d 个提交，blob %d / tree %d（跳过已存在 %d），API 调用 %d"
          % (_stats["commit"], _stats["blob"], _stats["tree"], _stats["skip"],
             _stats["api"]))
    print("refs/remotes/origin/%s -> %s" % (args.branch, head[:8]))
    print("下一步：git merge --ff-only origin/%s" % args.branch)
    return 0


if __name__ == "__main__":
    sys.exit(main())
