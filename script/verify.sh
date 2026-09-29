#!/usr/bin/env bash
# Verify every contract a deployment created, on Sourcify (which Blockscout imports), Blockscout and Etherscan (API V2), from the deploy's broadcast file
# (and, when given, its manifest for labels and a completeness check).
#
#   script/verify.sh [--dry-run] [--broadcast <run.json>]... [--manifest <deployments/x.json>]
#                    [--only sourcify|blockscout|etherscan] [--no-proxy-link]
#
# How it works: every CREATE / CREATE2 in the broadcast (top-level transactions and the contracts they created
# internally, e.g. each proxy's ProxyAdmin or a launched token) is matched against the local artifacts in out/ by
# creation bytecode. The match names the source (`path:Contract`) and its compilation profile; the rest of the init
# code is the ABI-encoded constructor arguments. Then `forge verify-contract` runs once per contract and verifier.
# (Deploy.s.sol builds most contracts under the `house` profile, optimizer runs 1, because it imports FlipperHouse;
# the profile passed to forge is the one whose bytecode matched.)
# Run it from the commit that was deployed, after `forge build` (the same sources and settings produce the same
# bytecode; anything that doesn't match is listed and skipped). Already-verified contracts are skipped by forge.
#
# Env:
#   CHAIN_ID            4663 (Robinhood Chain)
#   ETHERSCAN_API_KEY   required for Etherscan (V2 multichain key)
#   ETHERSCAN_URL       https://api.etherscan.io/v2/api?chainid=$CHAIN_ID
#   BLOCKSCOUT_URL      https://robinhoodchain.blockscout.com/api/
#   RPC_URL             for reading proxy implementations (Etherscan proxy link); default $ROBINHOOD_RPC_URL
#
# --dry-run prints the plan and every command without submitting anything.
set -euo pipefail
cd "$(dirname "$0")/.."

CHAIN_ID="${CHAIN_ID:-4663}"
BLOCKSCOUT_URL="${BLOCKSCOUT_URL:-https://robinhoodchain.blockscout.com/api/}"
ETHERSCAN_URL="${ETHERSCAN_URL:-https://api.etherscan.io/v2/api?chainid=${CHAIN_ID}}"
RPC_URL="${RPC_URL:-${ROBINHOOD_RPC_URL:-}}"

DRY=0
ONLY=""
LINK=1
MANIFEST=""
BROADCASTS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --broadcast) BROADCASTS+=("$2"); shift ;;
    --manifest) MANIFEST="$2"; shift ;;
    --only) ONLY="$2"; shift ;;
    --no-proxy-link) LINK=0 ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done
[[ ${#BROADCASTS[@]} -eq 0 ]] && BROADCASTS=("broadcast/Deploy.s.sol/${CHAIN_ID}/run-latest.json")
for b in "${BROADCASTS[@]}"; do [[ -f "$b" ]] || { echo "no broadcast file: $b" >&2; exit 1; }; done
[[ -n "$MANIFEST" && ! -f "$MANIFEST" ]] && { echo "no manifest: $MANIFEST" >&2; exit 1; }
[[ -d out ]] || { echo "no out/: run \`forge build\` at the deployed commit first" >&2; exit 1; }

VERIFIERS=()
# Sourcify first: Blockscout imports Sourcify matches, and Blockscout's own API may sit behind a Cloudflare challenge
[[ -z "$ONLY" || "$ONLY" == sourcify ]] && VERIFIERS+=(sourcify)
[[ -z "$ONLY" || "$ONLY" == blockscout ]] && VERIFIERS+=(blockscout)
if [[ -z "$ONLY" || "$ONLY" == etherscan ]]; then
  if [[ -z "${ETHERSCAN_API_KEY:-}" && $DRY -eq 0 ]]; then
    echo "ETHERSCAN_API_KEY not set: skipping Etherscan (--only blockscout to silence)" >&2
  else
    VERIFIERS+=(etherscan)
  fi
fi

# plan: one TSV line per created contract: address, source id, profile, constructor args (hex, may be empty), label
PLAN="$(python3 - "$MANIFEST" "${BROADCASTS[@]}" <<'PY'
import glob, json, os, sys

manifest, broadcasts = sys.argv[1], sys.argv[2:]
labels = {}
if manifest:
    for k, v in (json.load(open(manifest)).get("contracts") or {}).items():
        if isinstance(v, str) and v.startswith("0x") and int(v, 16) != 0:
            labels.setdefault(v.lower(), []).append(k)

# local artifacts of deployable sources (src/ and lib/), by creation-bytecode length
by_len = {}
for f in glob.glob("out/**/*.json", recursive=True):
    if "/build-info/" in f:
        continue
    try:
        a = json.load(open(f))
    except Exception:
        continue
    code = ((a.get("bytecode") or {}).get("object") or "").removeprefix("0x")
    if len(code) < 4 or "__$" in code:
        continue
    target = ((a.get("metadata") or {}).get("settings") or {}).get("compilationTarget") or {}
    if len(target) != 1:
        continue
    path, name = next(iter(target.items()))
    if not (path.startswith("src/") or path.startswith("lib/")):
        continue
    base = os.path.basename(f)[: -len(".json")]  # Name or Name.<profile>
    profile = base[len(name) + 1 :] if base != name and base.startswith(name + ".") else "default"
    by_len.setdefault(len(code), {}).setdefault(code, (f"{path}:{name}", profile))
lengths = sorted(by_len, reverse=True)

def match(init):
    for n in lengths:
        if n <= len(init):
            hit = by_len[n].get(init[:n])
            if hit:
                return hit, init[n:]
    return None, None

seen, rows, missing = set(), [], []
def add(addr, init, kind):
    addr = addr.lower()
    if addr in seen:
        return
    seen.add(addr)
    init = (init or "").removeprefix("0x")
    if kind == "CREATE2" and init:
        init = init[64:]  # deterministic-deployer calldata: salt ‖ init code
    hit, args = match(init)
    label = ",".join(labels.get(addr, [])) or "-"
    if hit:
        rows.append((addr, hit[0], hit[1], args, label))
    else:
        missing.append((addr, label))

for b in broadcasts:
    for t in json.load(open(b)).get("transactions", []):
        kind = t.get("transactionType")
        if kind in ("CREATE", "CREATE2") and t.get("contractAddress"):
            add(t["contractAddress"], (t.get("transaction") or {}).get("input"), kind)
        for c in t.get("additionalContracts") or []:
            add(c["address"], c.get("initCode"), c.get("transactionType", "CREATE"))

for addr, src, profile, args, label in rows:  # "-" for an empty field (bash `read` would collapse empty tabs)
    print("\t".join([addr, src, profile or "-", args or "-", label]))
for addr, label in missing:
    print(f"#nomatch\t{addr}\t{label}")
for addr, ks in labels.items():
    if addr not in seen:
        print(f"#external\t{addr}\t{','.join(ks)}")
PY
)"

echo "== plan (chain ${CHAIN_ID}; verifiers: ${VERIFIERS[*]:-none}) =="
printf '%s\n' "$PLAN" | awk -F'\t' '
  /^#nomatch/  { printf "  SKIP  %s  %-28s no local artifact matches its bytecode (built from another commit?)\n", $2, $3; next }
  /^#external/ { printf "  --    %s  %-28s not created by this broadcast (external or another run)\n", $2, $3; next }
  { printf "  OK    %s  %-28s %s%s%s\n", $1, $5, $2, ($3 != "default" ? "  [profile " $3 "]" : ""), ($4 != "-" ? "  (+args)" : "") }'

run() {
  if [[ $DRY -eq 1 ]]; then printf '  $'; printf ' %q' "$@"; printf '\n'; else "$@" || FAILED=$((FAILED + 1)); fi
}

FAILED=0
PROXY_ID="lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol:TransparentUpgradeableProxy"
IMPL_SLOT=0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc
while IFS=$'\t' read -r addr id profile args label; do
  [[ -z "$addr" || "$addr" == \#* ]] && continue
  if [[ "$args" == - ]]; then args=""; fi
  common=("$addr" "$id" --chain "$CHAIN_ID" --watch)
  if [[ -n "$args" ]]; then common+=(--constructor-args "0x$args"); fi
  common+=(--compilation-profile "$profile") # always: forge refuses to guess when a source is built under two profiles
  for v in "${VERIFIERS[@]}"; do
    echo "== $v: $label $addr ($id)"
    if [[ "$v" == sourcify ]]; then
      run forge verify-contract "${common[@]}" --verifier sourcify
    elif [[ "$v" == blockscout ]]; then
      run forge verify-contract "${common[@]}" --verifier blockscout --verifier-url "$BLOCKSCOUT_URL"
    else
      run forge verify-contract "${common[@]}" --verifier etherscan --verifier-url "$ETHERSCAN_URL" \
        --etherscan-api-key "${ETHERSCAN_API_KEY:-\$ETHERSCAN_API_KEY}"
      # link the proxy to its implementation (Blockscout detects EIP-1967 proxies by itself)
      if [[ $LINK -eq 1 && "$id" == "$PROXY_ID" ]]; then
        slot=""
        if [[ -n "$RPC_URL" ]]; then slot="$(cast storage "$addr" "$IMPL_SLOT" --rpc-url "$RPC_URL" 2>/dev/null || true)"; fi
        if [[ ${#slot} -ne 66 ]]; then
          echo "  (no RPC_URL or unreadable implementation slot: proxy link skipped)"
          continue
        fi
        impl="0x${slot:26}"
        run curl -sS -X POST "$ETHERSCAN_URL" \
          --data-urlencode module=contract --data-urlencode action=verifyproxycontract \
          --data-urlencode "address=$addr" --data-urlencode "expectedimplementation=$impl" \
          --data-urlencode "apikey=${ETHERSCAN_API_KEY:-\$ETHERSCAN_API_KEY}"
        if [[ $DRY -eq 0 ]]; then echo; fi
      fi
    fi
  done
done <<< "$PLAN"

[[ $DRY -eq 1 ]] && { echo "(dry run: nothing submitted)"; exit 0; }
[[ $FAILED -eq 0 ]] || { echo "$FAILED verification(s) failed" >&2; exit 1; }
echo "done"
