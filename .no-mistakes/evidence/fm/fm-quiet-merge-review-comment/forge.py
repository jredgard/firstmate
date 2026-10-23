#!/usr/bin/env python3
"""Disposable local Azure DevOps stand-in for az and curl (state in $FORGE_DIR)."""
import json, os, sys, time
D = os.environ["FORGE_DIR"]
def load(n, d=None):
    p = os.path.join(D, n)
    return json.load(open(p)) if os.path.exists(p) else d
def save(n, v): json.dump(v, open(os.path.join(D, n), "w"))
def log(s):
    with open(os.path.join(D, "trace.log"), "a") as f:
        f.write(f"{time.strftime('%H:%M:%S')} {s}\n")
pr = load("pr.json")
tool, args = sys.argv[1], sys.argv[2:]
if tool == "az":
    a = " ".join(args)
    if a.startswith("account get-access-token"):
        print("lab-token"); sys.exit(0)
    if a.startswith("repos pr show"):
        log("az repos pr show")
        print(json.dumps({"description": pr["description"], "repo": "Backend",
                          "project": "Project One", "head": pr["head"]})); sys.exit(0)
    if a.startswith("devops invoke"):
        method = args[args.index("--http-method") + 1]
        threads = load("threads.json", [])
        if method == "GET":
            log(f"az GET threads (n={len(threads)})")
            print(json.dumps({"value": threads})); sys.exit(0)
        if os.environ.get("FORGE_POST_REFUSED") == "1":
            log("az POST thread REFUSED"); print("forbidden", file=sys.stderr); sys.exit(1)
        body = json.load(open(args[args.index("--in-file") + 1]))
        body["author"] = "firstmate-merge-guard"
        threads.append(body); save("threads.json", threads)
        log("az POST thread (by merge guard)")
        print(json.dumps({"id": len(threads)})); sys.exit(0)
    print("unhandled az " + a, file=sys.stderr); sys.exit(2)
# curl
method = url = data = None; hdr = ""
i = 0
while i < len(args):
    x = args[i]
    if x == "--request": method = args[i+1]; i += 2
    elif x == "--data": data = args[i+1]; i += 2
    elif x == "--header":
        if args[i+1].startswith("@"): hdr = open(args[i+1][1:]).read()
        i += 2
    elif x == "--max-time": i += 2
    elif x.startswith("-"): i += 1
    else: url = x; i += 1
if "Bearer lab-token" not in hdr: sys.exit(22)
voted = os.path.exists(os.path.join(D, "voted"))
if method == "GET" and "/pullRequests/42?" in url:
    log("REST GET pr")
    print(json.dumps({"pullRequestId": 42, "status": pr["status"], "mergeStatus": "succeeded",
        "isDraft": False, "lastMergeSourceCommit": {"commitId": pr["head"]},
        "repository": {"project": {"id": "11111111-1111-1111-1111-111111111111"}}}))
elif method == "GET" and "/policy/evaluations" in url:
    print(json.dumps({"value": [{"status": "approved", "configuration": {"isBlocking": True,
        "type": {"displayName": "Build"}}}]}))
elif method == "PUT" and "/reviewers/" in url:
    open(os.path.join(D, "voted"), "w").close(); log("REST PUT vote=10")
    print("{}")
elif method == "PATCH" and "/pullRequests/42?" in url:
    threads = load("threads.json", [])
    marker = f"attestation-head:{pr['head']}"
    has = any(marker in c.get("content", "") for t in threads for c in t.get("comments", []))
    log(f"REST PATCH complete (review comment present at completion: {has})")
    pr["status"] = "completed"; save("pr.json", pr)
    save("completed.json", {"comment_present_at_completion": has, "voted": voted})
    print("{}")
else:
    print("unhandled curl", method, url, file=sys.stderr); sys.exit(22)
