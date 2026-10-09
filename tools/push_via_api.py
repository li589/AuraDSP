#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""push_via_api.py — github.com:443 被屏蔽时的推送兜底（单提交，sha 逐字一致）

背景：沙箱对 github.com 的封锁是间歇性的。原生 git push 失败后，用
api.github.com（gh CLI）走三步 Git Data API：blob → tree → commit → 更新 ref。

与 skills/github-push-via-api 的脚本差异（实测踩坑）：
  * gh api 的 `-f tree[][path]=...` 数组语法会触发 422 GitRPC::BadObjectState
    → 本脚本一律用 `--input <json file>` 传 body；
  * 原脚本 diff 方向会反（把新增标成删除）→ 本脚本直接用 `git diff --name-only`
    的本地结果，不做反向推断；
  * author/committer 的时区必须换算成"提交自身时区"的 ISO，否则 sha 分叉。

用法：
    python tools/push_via_api.py            # 推当前分支，HEAD 单提交
    python tools/push_via_api.py main       # 显式分支

前置：本地只比远端多 1 个提交（HEAD 的父 == 远端 HEAD）。
"""
import base64
import datetime
import json
import os
import subprocess
import sys
import tempfile


def sh(*args, binary=False):
    out = subprocess.check_output(list(args), stderr=subprocess.PIPE)
    return out if binary else out.decode().strip()


def gh(*args, stdin_json=None):
    cmd = ["gh", "api"] + list(args)
    if stdin_json is not None:
        fd, path = tempfile.mkstemp(suffix=".json")
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                json.dump(stdin_json, f, ensure_ascii=False)
            cmd += ["--input", path]
            return json.loads(sh(*cmd))
        finally:
            os.unlink(path)
    return json.loads(sh(*cmd))


def ident(raw_commit, key):
    line = [l for l in raw_commit.split("\n") if l.startswith(key + " ")][0]
    body = line.split(" ", 1)[1]
    ls, le = body.index("<"), body.index(">")
    name, mail = body[:ls].strip(), body[ls + 1:le]
    epoch, tz = body[le + 1:].strip().split(" ")[:2]
    sign = 1 if tz[0] == "+" else -1
    off = datetime.timedelta(hours=int(tz[1:3]), minutes=int(tz[3:5])) * sign
    dt = datetime.datetime.fromtimestamp(int(epoch), datetime.timezone(off))
    return {"name": name, "email": mail,
            "date": dt.strftime("%Y-%m-%dT%H:%M:%S") + tz[:3] + ":" + tz[3:]}


def main():
    branch = sys.argv[1] if len(sys.argv) > 1 else sh("git", "rev-parse", "--abbrev-ref", "HEAD")
    repo = sh("git", "remote", "get-url", "origin")
    for pre in ("https://github.com/", "git@github.com:"):
        if repo.startswith(pre):
            repo = repo[len(pre):].removesuffix(".git")
    print("repo=%s branch=%s" % (repo, branch))

    head = sh("git", "rev-parse", "HEAD")
    parents = sh("git", "rev-list", "--parents", "-n1", "HEAD").split()[1:]
    remote_head = gh("repos/%s/git/ref/heads/%s" % (repo, branch))["object"]["sha"]
    print("  HEAD=%s\n  parents=%s\n  远端=%s" % (head[:12], [p[:12] for p in parents], remote_head[:12]))
    if remote_head not in parents:
        print("!! 越界：远端 HEAD 不是本地 HEAD 的父提交（不止多 1 提交或已分叉）")
        print("!! 请改用逐提交重放或全量脚本。中止。")
        return 2

    # 1) 上传本次改动文件的 blob（幂等）
    paths = [p for p in sh("git", "diff", "--name-only", remote_head, head).split("\n") if p]
    tree_entries = []
    for p in paths:
        want = sh("git", "rev-parse", "%s:%s" % (head, p))
        content = sh("git", "cat-file", "blob", "%s:%s" % (head, p), binary=True)
        up = gh("repos/%s/git/blobs" % repo,
                stdin_json={"content": base64.b64encode(content).decode(), "encoding": "base64"})
        assert up["sha"] == want, "blob sha mismatch: %s" % p
        mode = sh("git", "ls-tree", head, p).split()[0]
        tree_entries.append({"path": p, "mode": mode, "type": "blob", "sha": up["sha"]})
        print("  blob %s %s %s" % (up["sha"][:12], mode, p))

    # 2) tree（base_tree = 父提交的树）
    base_tree = sh("git", "rev-parse", "%s^{tree}" % remote_head)
    tree = gh("repos/%s/git/trees" % repo,
              stdin_json={"base_tree": base_tree, "tree": tree_entries})
    want_tree = sh("git", "rev-parse", "%s^{tree}" % head)
    assert tree["sha"] == want_tree, "tree mismatch: %s != %s" % (tree["sha"], want_tree)
    print("  tree=%s (校验通过)" % tree["sha"][:12])

    # 3) commit（author/committer 保真）
    raw = sh("git", "cat-file", "commit", head)
    msg = raw.split("\n\n", 1)[1]
    payload = {"message": msg, "tree": tree["sha"], "parents": parents,
               "author": ident(raw, "author"), "committer": ident(raw, "committer")}
    commit = gh("repos/%s/git/commits" % repo, stdin_json=payload)
    assert commit["sha"] == head, "commit mismatch: %s != %s" % (commit["sha"], head)
    print("  commit=%s (校验通过)" % commit["sha"][:12])

    # 4) 更新 ref（非强制快进）
    gh("repos/%s/git/refs/heads/%s" % (repo, branch), "-X", "PATCH",
       stdin_json={"sha": commit["sha"], "force": False})
    sh("git", "update-ref", "refs/remotes/origin/%s" % branch, commit["sha"])
    print(">>> 已推送：%s -> %s（sha 与本地逐字一致）" % (branch, commit["sha"][:8]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
