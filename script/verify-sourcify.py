#!/usr/bin/env python3
"""Verify every contract a deployment created on Sourcify (Blockscout imports Sourcify matches), with the exact
compiler input each was built from.

Why not `forge verify-contract`: under via-IR the bytecode depends on every source in the compilation, and forge
submits only the contract's own imports, so Sourcify rejects it (`extra_file_input_bug`). This script takes each
contract's creation code from the broadcast records, finds the local artifact (any compilation profile) whose
bytecode it starts with (the rest is the constructor arguments), and rebuilds that artifact's full standard JSON input
from the compiler cache: the build's source list (out/build-info/<id>.json), the profile's solc settings
(cache/solidity-files-cache.json) and the remappings. Run it from the deployed commit after `forge build`.

  script/verify-sourcify.py [--chain 4663] [--dry-run] [--extra <addr>=<src>:<Contract>@<profile>]... <broadcast *.json>...

With BLOCKSCOUT_API_KEY (a Blockscout PRO API key, proapi_…), it then asks Blockscout for each contract through the PRO
API, which makes Blockscout import the Sourcify match (it doesn't on its own until a contract is requested there).

--extra names a contract whose creation isn't in the broadcast records (an interrupted run's file is overwritten by the
next one); Sourcify reads its code from the chain, so only the source and the compilation profile are needed.
"""
import argparse
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

SOURCIFY = "https://sourcify.dev/server"
SOLC = "0.8.26+commit.8a97fa7a"


def http(method, url, body=None):
    req = urllib.request.Request(url, data=json.dumps(body).encode() if body is not None else None, method=method,
                                 headers={"Content-Type": "application/json", "User-Agent": "flipper-verify"})
    try:
        with urllib.request.urlopen(req, timeout=180) as r:
            return r.status, json.load(r)
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.load(e)
        except ValueError:
            return e.code, {"message": e.reason}


def creations(paths):
    """(address, initcode hex) of every contract the broadcasts created, top level and internal."""
    out = {}
    for p in paths:
        d = json.load(open(p))
        for t in d.get("transactions", []):
            kind, addr = t.get("transactionType"), (t.get("contractAddress") or "").lower()
            data = (t["transaction"].get("input") or t["transaction"].get("data") or "").removeprefix("0x")
            if kind == "CREATE" and addr:
                out[addr] = data
            elif kind == "CREATE2" and addr:
                out[addr] = data[64:]  # the CREATE2 factory takes salt ++ initcode
            for a in t.get("additionalContracts") or []:
                code = (a.get("initCode") or "").removeprefix("0x")
                if a.get("address") and code:
                    out[a["address"].lower()] = code
    return out


def artifacts(cache):
    """every local artifact with bytecode: (bytecode hex, source, contract, profile, artifact entry)"""
    for src, f in cache["files"].items():
        if not (src.startswith("src/") or src.startswith("lib/")):
            continue
        for name, versions in f.get("artifacts", {}).items():
            for profiles in versions.values():
                for prof, a in profiles.items():
                    try:
                        bc = json.load(open(os.path.join("out", a["path"])))["bytecode"]["object"].removeprefix("0x")
                    except (OSError, KeyError, ValueError):
                        continue
                    if bc:
                        yield bc, src, name, prof, a


def std_input(cache, art, prof, remappings):
    bi = json.load(open(f"out/build-info/{art['build_id']}.json"))
    settings = dict(cache["profiles"][prof]["solc"])
    settings["remappings"] = remappings
    settings["outputSelection"] = {"*": {"*": ["abi", "evm.bytecode.object", "evm.deployedBytecode.object", "metadata"]}}
    return {"language": "Solidity", "sources": {p: {"content": open(p).read()} for p in bi["source_id_to_path"].values()},
            "settings": settings}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--chain", default="4663")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--extra", action="append", default=[])
    ap.add_argument("broadcasts", nargs="+")
    args = ap.parse_args()
    os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

    cache = json.load(open("cache/solidity-files-cache.json"))
    remappings = [l.strip() for l in subprocess.run(["forge", "remappings"], capture_output=True, text=True,
                                                     check=True).stdout.splitlines() if l.strip()]
    arts = sorted(artifacts(cache), key=lambda x: -len(x[0]))  # longest first: no shorter artifact is a prefix match
    todo, unmatched = [], []
    for addr, init in sorted(creations(args.broadcasts).items()):
        hit = next((a for a in arts if init.startswith(a[0])), None)
        (todo.append((addr, init, hit)) if hit else unmatched.append(addr))
    for x in args.extra:
        addr, rest = x.split("=", 1)
        ident, prof = rest.rsplit("@", 1)
        src, name = ident.rsplit(":", 1)
        art = cache["files"][src]["artifacts"][name]["0.8.26"][prof]
        bc = json.load(open(os.path.join("out", art["path"])))["bytecode"]["object"].removeprefix("0x")
        todo.append((addr.lower(), bc, (bc, src, name, prof, art)))
    for addr in unmatched:
        print(f"  SKIP {addr}: no local artifact matches its creation code (built from another commit?)")

    failed = 0
    for addr, init, (bc, src, name, prof, art) in todo:
        label = f"{src}:{name} [{prof}]"
        st, j = http("GET", f"{SOURCIFY}/v2/contract/{args.chain}/{addr}")
        if st == 200 and j.get("match"):
            print(f"  ok   {addr} {label}: already verified ({j['match']})")
            continue
        if args.dry_run:
            print(f"  plan {addr} {label}  (constructor args: {(len(init) - len(bc)) // 2} bytes)")
            continue
        body = {"stdJsonInput": std_input(cache, art, prof, remappings), "compilerVersion": SOLC,
                "contractIdentifier": f"{src}:{name}"}
        st, j = http("POST", f"{SOURCIFY}/v2/verify/{args.chain}/{addr}", body)
        if st >= 300 or "verificationId" not in j:
            if st == 409:
                print(f"  ok   {addr} {label}: already verified")
                continue
            print(f"  FAIL {addr} {label}: HTTP {st} {str(j)[:200]}")
            failed += 1
            continue
        vid = j["verificationId"]
        for _ in range(60):
            time.sleep(5)
            _, r = http("GET", f"{SOURCIFY}/v2/verify/{vid}")
            if r.get("isJobCompleted"):
                break
        m = (r.get("contract") or {}).get("match")
        if m:
            print(f"  ok   {addr} {label}: {m}")
        else:
            failed += 1
            err = r.get("error") or {}
            print(f"  FAIL {addr} {label}: {err.get('customCode') or 'pending'} {str(err.get('message', ''))[:160]}")
    print(f"{len(todo)} matched, {len(unmatched)} unmatched, {failed} failed")
    key = os.environ.get("BLOCKSCOUT_API_KEY", "")
    if key and not args.dry_run:
        blockscout(args.chain, key, [t[0] for t in todo])
    sys.exit(1 if failed else 0)


def blockscout(chain, key, addrs, rounds=8, wait=45):
    """ask Blockscout (PRO API) for each contract until it shows as verified: each request makes it import the Sourcify
    match. Imports land over minutes; whatever is left imports the same way later (run again)."""
    base = f"https://api.blockscout.com/{chain}/api/v2/smart-contracts"
    pending = list(addrs)
    for rnd in range(rounds):
        left = []
        for a in pending:
            st, j = http("GET", f"{base}/{a}?apikey={key}")
            if not (st == 200 and j.get("is_verified")):
                left.append(a)
        pending = left
        print(f"  blockscout: {len(addrs) - len(pending)}/{len(addrs)} verified")
        if not pending:
            return
        time.sleep(wait)
    print(f"  blockscout: {len(pending)} still importing (run again later): {' '.join(pending)}")


if __name__ == "__main__":
    main()
