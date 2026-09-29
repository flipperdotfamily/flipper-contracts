#!/usr/bin/env bash
# Snapshot (default) or verify (--check) the storage layout of every upgradeable contract.
#
#   script/storage-layout.sh           # write storage-layout/<Contract>.json
#   script/storage-layout.sh --check   # fail if an existing variable moved/changed (appending is allowed)
#
# Run --check in CI before every upgrade: a proxy's storage must stay append-only.
set -euo pipefail
cd "$(dirname "$0")/.."
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1
export PATH="$HOME/.foundry/bin:$PATH"
CHECK=0; [[ "${1:-}" == "--check" ]] && CHECK=1
CONTRACTS=(FlipperHouse HouseModule HolderRewards RevenueRouter PythEntropyAdapter DiceEntropyAdapter ChainlinkVRFAdapter HookitRouteAdapter V4RouteAdapter V3RouteAdapter FlipRewards FlipperLens TreasuryVault PartnerRegistry)
mkdir -p storage-layout
status=0
CUR_DIR="$(mktemp -d)"; trap 'rm -rf "$CUR_DIR"' EXIT
for c in "${CONTRACTS[@]}"; do
  raw="$(forge inspect "$c" storageLayout --json 2>/dev/null || true)"
  # artifacts built under an additional compiler profile may lack the layout: recompile just for inspection
  [[ "$raw" == \{* ]] || raw="$(forge inspect "$c" storageLayout --json --force)"
  cur="$(printf '%s' "$raw" | python3 -c '
import json, re, sys
d = json.load(sys.stdin)
norm = lambda t: re.sub(r"\)\d+", ")", t)
types = d.get("types") or {}
def members(t):
    m = (types.get(t) or {}).get("members")
    return [[x["label"], x["slot"], x["offset"], norm(x["type"])] for x in m] if m else None
out = {"storage": [], "structs": {}}
for s in d["storage"]:
    out["storage"].append([s["label"], s["slot"], s["offset"], norm(s["type"])])
for t in types:
    if t.startswith("t_struct") and members(t):
        out["structs"][norm(t)] = members(t)
print(json.dumps(out, indent=1, sort_keys=True))
')"
  echo "$cur" > "$CUR_DIR/$c.json"
  file="storage-layout/$c.json"
  if [[ "$CHECK" -eq 0 || ! -f "$file" ]]; then
    echo "$cur" > "$file"; echo "snapshot  $c"
    continue
  fi
  if ! python3 - "$file" <<PY
import json, sys
old = json.load(open(sys.argv[1])); new = json.loads('''$cur''')
bad = []
for i, e in enumerate(old["storage"]):
    if i >= len(new["storage"]) or new["storage"][i] != e:
        bad.append(f"storage[{i}] {e} -> {new['storage'][i] if i < len(new['storage']) else 'MISSING'}")
for name, mem in old["structs"].items():
    cur = new["structs"].get(name)
    if cur is None: bad.append(f"struct {name} removed"); continue
    for i, m in enumerate(mem):
        if i >= len(cur) or cur[i] != m: bad.append(f"struct {name}[{i}] {m} changed")
if bad:
    print("\n".join(bad)); sys.exit(1)
PY
  then echo "BROKEN    $c"; status=1; else echo "ok        $c"; fi
done
# the HouseModule runs by delegatecall on the house's storage: its layout must be the house's exactly
if [[ -f "$CUR_DIR/FlipperHouse.json" && -f "$CUR_DIR/HouseModule.json" ]]; then
  if python3 -c '
import json, sys
a = json.load(open(sys.argv[1])); b = json.load(open(sys.argv[2]))
sys.exit(0 if a == b else 1)' "$CUR_DIR/FlipperHouse.json" "$CUR_DIR/HouseModule.json"; then echo "ok        HouseModule == FlipperHouse"; else echo "BROKEN    HouseModule layout differs from FlipperHouse"; status=1; fi
fi
exit $status
