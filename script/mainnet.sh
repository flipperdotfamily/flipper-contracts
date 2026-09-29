#!/usr/bin/env bash
# flipper.family production launch: contracts signed on a Ledger, the backend configured through its admin API, in
# resumable steps. Run it once the web (Vercel) and the API (Railway, "awaiting deployment") are up.
#
#   script/mainnet.sh                 run every step that isn't done yet, in order (asks before each broadcast)
#   script/mainnet.sh status          what's done (deployments/robinhood.progress) and the recorded addresses
#   script/mainnet.sh <step>          run one step again (every step is idempotent: it re-reads the chain / the API and
#                                     only does what is still missing)
#   flags: --yes (don't ask), --env <file> (default contracts/.env.mainnet)
#
# Steps:
#   api            the API answers the admin key, runs on the same chain, and isn't serving another deployment
#   keys           the API generates (once) and keeps the operator, upkeep and claim keys; their addresses come back
#                  (the claim key is the PrincipalLock's dev claim wallet; the owner picks where it sweeps to on the site)
#   preflight      addresses, ETH/USD, the opening buy, the Ledger's balance (read-only)
#   fund           the Ledger tops up the operator, upkeep and claim wallets (OPERATOR_FUND_WEI, UPKEEP_FUND_WEI,
#                  CLAIM_FUND_WEI)
#   launch … roles the contracts (script/DeployMainnet.s.sol), each step signed on the Ledger
#   manifest       deployments/robinhood.json
#   publish        the manifest and the site settings to the API: it activates (upkeep, indexers, the site's config)
#   acceptUnlocker the API's operator key accepts the drawdown breaker's unlocker role
#   check          every role, owner and setting asserted onchain (read-only)
#   live           the API is active and sending, /v1/site serves the deployment (and the web, with WEB_URL)
#   verify         source verification (Sourcify → Blockscout, Etherscan)
#   pin            the deployment written into the SDK: its default addresses (FLIPPER_ADDRESSES, sdk/src/addresses.ts)
#                  and the canonical house + lens (CANONICAL_DEPLOYMENTS, sdk/src/deployments.ts)
#   release        the npm packages (@flipperdotfamily/*: sdk, widget, react, vue, svelte, angular, react-native):
#                  the pending changesets applied, built and checked, committed in the SDK repo, published by hand (npm
#                  asks for your 2FA code; be logged in with `npm login` as an owner of the flipperdotfamily org),
#                  then tagged and pushed. Later releases go through the SDK repo's GitHub Actions (trusted publishing).
#   record         the deployment records committed and pushed: the contracts repo (deployments/robinhood.*, the
#                  broadcast records), then the main repo's submodule pointers (contracts/, packages/)
#
# Repos: this directory is flipperdotfamily/flipper-contracts, checked out as contracts/ in the main repo
# (flipperdotfamily/flipper), beside the SDK repo (flipperdotfamily/flipper-sdk) at packages/. Run the script from
# that checkout. Pushes use GITHUB_SECRET_KEY (a GitHub token for the flipperdotfamily account; env, or the main
# repo's .env.deploy) when it's set, else your own git credentials.
#
# For each broadcasting step: simulate against the chain (nothing sent) → confirm → broadcast with `--slow` (one
# transaction at a time, each approved on the Ledger) → simulate again (a finished step has nothing left to send).
# If anything fails, fix the cause and run the script again: it picks up where it stopped.
#
# Ledger: unlocked, Ethereum app open, "Blind signing" on, auto-lock off.
#
# Env (contracts/.env.mainnet; see .env.mainnet.example):
#   OWNER_ADDRESS API_URL ADMIN_API_KEY   (required)
#   LEDGER_PATH         the owner's derivation path on the Ledger (default m/44'/60'/0'/0/0)
#   RPC_URL             default https://rpc.mainnet.chain.robinhood.com
#   WEB_URL             e.g. https://flipper.family: `live` also checks the site serves the deployment
#   SITE_SETTINGS_JSON  public site settings to publish (a JSON object; optional)
#   ETHERSCAN_API_KEY   for verify (Etherscan V2)
#   SIGNER              ledger (default) | unlocked (rehearsal on an anvil fork: REHEARSAL=1)
#   plus DeployMainnet's own: V4_START_MCAP_USD OPENING_BUY_SUPPLY_BPS MAX_OPENING_BUY_ETH UNCX_LOCK OPERATOR_FUND_WEI
#   UPKEEP_FUND_WEI CLAIM_FUND_WEI REHEARSAL STATE_FILE MANIFEST_FILE
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.foundry/bin:$PATH" FOUNDRY_DISABLE_NIGHTLY_WARNING=1

ENV_FILE="${ENV_FILE:-.env.mainnet}"
YES=0
ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes) YES=1 ;;
    --env) ENV_FILE="$2"; shift ;;
    -h|--help) sed -n '2,54p' "$0"; exit 0 ;;
    *) ARGS+=("$1") ;;
  esac
  shift
done
if [[ -f "$ENV_FILE" ]]; then
  set -a; source "$ENV_FILE"; set +a
elif [[ "${ENV_FILE}" != ".env.mainnet" ]]; then
  echo "no env file: $ENV_FILE" >&2; exit 1
fi

for v in OWNER_ADDRESS API_URL ADMIN_API_KEY; do
  [[ -n "${!v:-}" ]] || { echo "set $v in $ENV_FILE" >&2; exit 1; }
done
API_URL="${API_URL%/}"
RPC_URL="${RPC_URL:-https://rpc.mainnet.chain.robinhood.com}"
SIGNER="${SIGNER:-ledger}"
[[ -n "${LEDGER_PATH:-}" ]] || LEDGER_PATH="m/44'/60'/0'/0/0"
export STATE_FILE="${STATE_FILE:-deployments/robinhood.state.json}"
export MANIFEST_FILE="${MANIFEST_FILE:-deployments/robinhood.json}"
PROGRESS="${STATE_FILE%.state.json}.progress"
KEYS_FILE="${STATE_FILE%.state.json}.keys.json" # addresses only: the keys never leave the API
LOG_DIR="deployments/logs"
mkdir -p "$LOG_DIR"
SCRIPT=script/DeployMainnet.s.sol
ROOT="$(cd .. && pwd)"   # the main repo (flipperdotfamily/flipper)
SDK_DIR="$ROOT/packages" # the SDK repo (flipperdotfamily/flipper-sdk)
STEPS=(api keys preflight fund launch core seal bankroll routes listings roles manifest publish acceptUnlocker check live verify pin release record)
BROADCASTS=" fund launch core seal bankroll routes listings roles "
ALWAYS=" api live " # re-checked on every run, even when done

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
red() { printf '\033[31m%s\033[0m\n' "$*" >&2; }
done_step() { [[ -f "$PROGRESS" ]] && grep -q "^$1	" "$PROGRESS"; }
mark_done() { printf '%s\t%s\t%s\n' "$1" "$(date -u +%FT%TZ)" "$(git rev-parse --short HEAD 2>/dev/null || echo nogit)" >> "$PROGRESS"; }
confirm() {
  [[ $YES -eq 1 ]] && return 0
  read -r -p "$1 [y/N] " a
  [[ "$a" == y || "$a" == Y ]]
}
jget() { python3 -c "import json,sys; d=json.load(sys.stdin); [d:=d.get(k) if isinstance(d,dict) else None for k in sys.argv[1].split('.')]; print('' if d is None else (json.dumps(d) if isinstance(d,(dict,list)) else d))" "$1"; }

# admin <method> <path> [json body]: the admin API; prints the body, fails on a non-2xx status
admin() {
  local method="$1" path="$2" body="${3:-}" out code
  local args=(-sS -X "$method" -H "Authorization: Bearer $ADMIN_API_KEY" -H "Content-Type: application/json"
    --max-time 150 -o "$LOG_DIR/api.out" -w '%{http_code}')
  [[ -n "$body" ]] && args+=(--data-binary "$body")
  code=$(curl "${args[@]}" "$API_URL$path") || { red "API unreachable: $API_URL$path"; return 1; }
  out=$(cat "$LOG_DIR/api.out")
  if [[ "$code" != 2* ]]; then red "API $method $path → $code: $out"; return 1; fi
  printf '%s' "$out"
}

load_keys() {
  [[ -f "$KEYS_FILE" ]] || { red "no $KEYS_FILE: run the keys step"; return 1; }
  OPERATOR_ADDRESS=$(jget operator < "$KEYS_FILE")
  UPKEEP_ADDRESS=$(jget upkeep < "$KEYS_FILE")
  CLAIM_WALLET=$(jget claim < "$KEYS_FILE")
  [[ -n "$OPERATOR_ADDRESS" && -n "$UPKEEP_ADDRESS" && -n "$CLAIM_WALLET" ]] || { red "$KEYS_FILE incomplete: run the keys step"; return 1; }
  export OPERATOR_ADDRESS UPKEEP_ADDRESS CLAIM_WALLET
}

# github_token: GITHUB_SECRET_KEY from the env or the main repo's .env.deploy (never printed)
github_token() {
  if [[ -n "${GITHUB_SECRET_KEY:-}" ]]; then printf '%s' "$GITHUB_SECRET_KEY"; return; fi
  [[ -f "$ROOT/.env.deploy" ]] && sed -n 's/^GITHUB_SECRET_KEY=//p' "$ROOT/.env.deploy" | tail -1 | tr -d "\"' \r"
}

# gh_push <repo dir> <push args…>: git push with the token as a one-off auth header, passed through the environment
# (not the command line, a remote URL or the repo's config); without a token, your own git credentials
gh_push() {
  local dir="$1" tok; shift
  tok=$(github_token)
  if [[ -z "$tok" ]]; then git -C "$dir" push "$@"; return; fi
  GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0= \
    GIT_CONFIG_KEY_1=http.https://github.com/.extraheader \
    GIT_CONFIG_VALUE_1="Authorization: Basic $(printf 'x-access-token:%s' "$tok" | base64 | tr -d '\n')" \
    git -C "$dir" push "$@"
}

# sdk_repo: the SDK repo is checked out beside this one, on main
sdk_repo() {
  [[ -f "$SDK_DIR/sdk/package.json" && -e "$SDK_DIR/.git" ]] || {
    red "no SDK repo at $SDK_DIR: run this from the main repo's checkout (git submodule update --init packages)"; return 1; }
  local b; b=$(git -C "$SDK_DIR" rev-parse --abbrev-ref HEAD)
  [[ "$b" == main ]] || { red "the SDK repo ($SDK_DIR) is on '$b': check out main"; return 1; }
}

owner_signer() {
  case "$SIGNER" in
    ledger) echo "--ledger --mnemonic-derivation-paths $LEDGER_PATH --sender $OWNER_ADDRESS" ;;
    unlocked) echo "--unlocked --sender $OWNER_ADDRESS" ;;
    *) red "SIGNER must be ledger|unlocked"; exit 1 ;;
  esac
}

# simulate <step> <log> <sender>: run the step without broadcasting; returns 3 when it has nothing to send
simulate() {
  local step="$1" log="$2"
  forge script "$SCRIPT" --sig "${step}()" --rpc-url "$RPC_URL" --sender "$3" -vv >"$log" 2>&1 || {
    red "simulation of $step failed (nothing was sent): $log"; tail -30 "$log" >&2; return 1; }
  if grep -q "Estimated total gas used for script" "$log"; then return 0; else return 3; fi
}

show_plan() {
  sed -n '/== Logs ==/,/^$/p' "$1" | head -40
  grep -E "Estimated total gas used for script|Estimated amount required" "$1" || true
}

run_broadcast_step() {
  local step="$1" sender="$2" signer="$3"
  local log="$LOG_DIR/${step}-$(date +%Y%m%d-%H%M%S)"
  bold "── $step: simulating against $RPC_URL"
  local rc=0
  simulate "$step" "$log.sim.log" "$sender" || rc=$?
  if [[ $rc -eq 3 ]]; then green "   nothing to send: $step is already done"; mark_done "$step"; return 0; fi
  [[ $rc -ne 0 ]] && return 1
  show_plan "$log.sim.log"
  echo "   full simulation: $log.sim.log"
  confirm "Broadcast $step now (each transaction needs a Ledger approval)?" || { red "skipped $step"; return 1; }
  bold "── $step: broadcasting (approve each transaction on the device)"
  # shellcheck disable=SC2086
  if ! forge script "$SCRIPT" --sig "${step}()" --rpc-url "$RPC_URL" --broadcast --slow $signer -vv 2>&1 | tee "$log.broadcast.log"; then
    red "$step: broadcast stopped. Fix the cause and run the script again: it resumes from the chain's state."
    return 1
  fi
  bold "── $step: confirming (a finished step has nothing left to send)"
  rc=0
  simulate "$step" "$log.after.log" "$sender" || rc=$?
  if [[ $rc -eq 3 ]]; then green "   $step done"; mark_done "$step"; return 0; fi
  red "$step still has transactions to send ($log.after.log): run the script again"
  return 1
}

run_step() {
  local step="$1"
  case "$step" in
    api)
      bold "── api: $API_URL"
      local st chain rpc house active
      st=$(admin GET /v1/admin/status) || return 1
      chain=$(cast chain-id --rpc-url "$RPC_URL")
      rpc=$(jget rpcChainId <<<"$st")
      [[ "$rpc" == "$chain" ]] || { red "the API's RPC is on chain $rpc, ours ($RPC_URL) on $chain"; return 1; }
      active=$(jget deployment.active <<<"$st"); house=$(jget deployment.house <<<"$st")
      if [[ "$active" == True || "$active" == true ]]; then
        local ours=""
        [[ -f "$STATE_FILE" ]] && ours=$(jget house < "$STATE_FILE")
        if [[ -z "$ours" || "$(echo "$ours" | tr A-F a-f)" != "$(echo "$house" | tr A-F a-f)" ]]; then
          red "the API already serves a deployment (house $house) that isn't this one: stop, or publish replaces it"
          confirm "Continue anyway (publish will replace it and restart the API)?" || return 1
        fi
        echo "   API active on house $house"
      else
        echo "   API awaiting deployment (chain $rpc)"
      fi
      mark_done api ;;
    keys)
      bold "── keys: the API's operator, upkeep and claim keys"
      local r; r=$(admin POST /v1/admin/keys '{"roles":["operator","upkeep","claim"]}') || return 1
      python3 -c "import json,sys; r=json.loads(sys.argv[1]); json.dump({k: r[k]['address'] for k in ('operator','upkeep','claim')}, open(sys.argv[2],'w'), indent=1)" "$r" "$KEYS_FILE"
      load_keys || return 1
      echo "   operator $OPERATOR_ADDRESS (guardian + breaker unlocker)"
      echo "   upkeep   $UPKEEP_ADDRESS (maintenance)"
      echo "   claim    $CLAIM_WALLET (the PrincipalLock's dev claim wallet)"
      mark_done keys ;;
    preflight)
      load_keys || return 1
      bold "── preflight"
      # contracts and scripts only (the tests aren't deployed; verify.sh matches against these artifacts)
      forge build --skip test >/dev/null || { red "forge build failed"; return 1; }
      forge script "$SCRIPT" --sig "preflight()" --rpc-url "$RPC_URL" --sender "$OWNER_ADDRESS" -vv 2>&1 | sed -n '/== Logs ==/,$p' | head -40
      [[ ${PIPESTATUS[0]} -eq 0 ]] || { red "preflight failed"; return 1; }
      confirm "Preflight looks right (addresses, ETH/USD, opening buy, balance)?" || return 1
      mark_done preflight ;;
    manifest)
      load_keys || return 1
      bold "── manifest"
      forge script "$SCRIPT" --sig "manifest()" --rpc-url "$RPC_URL" -vv >/dev/null || { red "manifest failed"; return 1; }
      green "   wrote $MANIFEST_FILE"
      mark_done manifest ;;
    publish)
      bold "── publish: the deployment and the site settings to the API"
      [[ -f "$MANIFEST_FILE" ]] || { red "no $MANIFEST_FILE: run the manifest step"; return 1; }
      local r; r=$(admin PUT /v1/admin/deployment "$(cat "$MANIFEST_FILE")") || return 1
      echo "   deployment: $r"
      if [[ "$(jget restart <<<"$r")" == True ]]; then
        echo "   the API replaces its previous deployment and restarts: waiting for it"
        for _ in $(seq 1 60); do sleep 2; admin GET /v1/admin/status >/dev/null 2>&1 && break; done
      fi
      if [[ -n "${SITE_SETTINGS_JSON:-}" ]]; then
        python3 -c "import json,sys; d=json.loads(sys.argv[1]); assert isinstance(d, dict)" "$SITE_SETTINGS_JSON" 2>/dev/null || {
          red "SITE_SETTINGS_JSON isn't a JSON object: $SITE_SETTINGS_JSON (in the env file, wrap it in single quotes)"; return 1; }
        r=$(admin PUT /v1/admin/settings "$SITE_SETTINGS_JSON") || return 1
        echo "   settings: $r"
      fi
      mark_done publish ;;
    acceptUnlocker)
      load_keys || return 1
      bold "── acceptUnlocker: the API's operator key accepts the breaker's unlocker role"
      local house unl
      house=$(jget house < "$STATE_FILE")
      unl=$(cast call "$house" "unlocker()(address)" --rpc-url "$RPC_URL")
      if [[ "$(echo "$unl" | tr A-F a-f)" == "$(echo "$OPERATOR_ADDRESS" | tr A-F a-f)" ]]; then
        green "   the operator is already the unlocker"; mark_done acceptUnlocker; return 0
      fi
      local r; r=$(admin POST /v1/admin/operator/accept-unlocker '{}') || return 1
      echo "   $r"
      unl=$(cast call "$house" "unlocker()(address)" --rpc-url "$RPC_URL")
      [[ "$(echo "$unl" | tr A-F a-f)" == "$(echo "$OPERATOR_ADDRESS" | tr A-F a-f)" ]] || { red "unlocker is still $unl"; return 1; }
      mark_done acceptUnlocker ;;
    check)
      load_keys || return 1
      bold "── check"
      forge script "$SCRIPT" --sig "check()" --rpc-url "$RPC_URL" -vv 2>&1 | sed -n '/== Logs ==/,$p' | head -60
      [[ ${PIPESTATUS[0]} -eq 0 ]] || { red "check failed: see above"; return 1; }
      mark_done check ;;
    live)
      bold "── live: the API and the site serve the deployment"
      local house st ok=0
      house=$(jget house < "$STATE_FILE" | tr A-F a-f)
      for _ in $(seq 1 45); do
        st=$(admin GET /v1/admin/status 2>/dev/null) || { sleep 2; continue; }
        if [[ "$(jget deployment.active <<<"$st")" == True && "$(jget deployment.house <<<"$st" | tr A-F a-f)" == "$house" \
          && "$(jget upkeep.canSend <<<"$st")" == True ]]; then ok=1; break; fi
        sleep 2
      done
      [[ $ok -eq 1 ]] || { red "the API isn't active on $house with a sending upkeep wallet: $st"; return 1; }
      echo "   API: active, upkeep sending (operator $(jget keys.operator.balanceWei <<<"$st") wei, upkeep $(jget keys.upkeep.balanceWei <<<"$st") wei)"
      local site; site=$(curl -sS --max-time 20 "$API_URL/v1/site") || { red "/v1/site unreachable"; return 1; }
      [[ "$(jget deployed <<<"$site")" == True && "$(jget contracts.house <<<"$site" | tr A-F a-f)" == "$house" ]] || { red "/v1/site: $site"; return 1; }
      echo "   /v1/site serves house $house"
      if [[ -n "${WEB_URL:-}" ]]; then
        local web; web=$(curl -sS --max-time 30 "${WEB_URL%/}/embed/deployment.json" | tr A-F a-f) || { red "web unreachable"; return 1; }
        [[ "$web" == *"$house"* ]] || { red "${WEB_URL%/}/embed/deployment.json doesn't serve house $house yet"; return 1; }
        echo "   web serves house $house"
      fi
      echo "   Next: sign in on the site with the owner (Ledger) and set the claim sweep destination and schedule in the"
      echo "   profile menu (until then, claimed earnings wait in the claim wallet)."
      mark_done live ;;
    pin)
      bold "── pin: the deployment in the SDK (sdk/src/addresses.ts, sdk/src/deployments.ts)"
      local chain; chain=$(cast chain-id --rpc-url "$RPC_URL")
      if [[ "$chain" != 4663 ]]; then echo "   chain $chain isn't Robinhood Chain: not pinning (rehearsal)"; mark_done pin; return 0; fi
      sdk_repo || return 1
      python3 script/pin-sdk.py "$MANIFEST_FILE" "$SDK_DIR/sdk/src" || return 1
      echo "   (the release step commits and publishes it; the site itself reads the API)"
      mark_done pin ;;
    release)
      bold "── release: the npm packages (@flipperdotfamily/*)"
      command -v pnpm >/dev/null || { red "pnpm not found (Node 22: corepack enable)"; return 1; }
      local chain; chain=$(cast chain-id --rpc-url "$RPC_URL")
      sdk_repo || return 1
      local bin="$ROOT/node_modules/.bin"
      if [[ "$chain" == 4663 ]]; then
        local house; house=$(jget contracts.house < "$MANIFEST_FILE")
        grep -qi "$house" "$SDK_DIR/sdk/src/deployments.ts" && grep -qi "$house" "$SDK_DIR/sdk/src/addresses.ts" || {
          red "the SDK isn't pinned to house $house: run the pin step"; return 1; }
        npm whoami >/dev/null 2>&1 || { red "not logged in to npm: run 'npm login' (an owner of the flipperdotfamily org, 2FA on)"; return 1; }
      fi
      echo "   building and checking the packages"
      (cd "$ROOT" && pnpm install --frozen-lockfile >/dev/null 2>&1 || pnpm install >/dev/null) || { red "pnpm install failed"; return 1; }
      if [[ "$chain" == 4663 ]] && ls "$SDK_DIR"/.changeset/*.md 2>/dev/null | grep -qv README.md; then
        echo "   applying the pending changesets (versions + CHANGELOGs)"
        (cd "$SDK_DIR" && "$bin/changeset" version) || { red "changeset version failed"; return 1; }
      fi
      (cd "$ROOT" && pnpm build:packages >/dev/null && pnpm typecheck:packages >/dev/null && pnpm lint:packages >/dev/null) || {
        red "the packages don't build and check cleanly: pnpm build:packages / typecheck:packages / lint:packages"; return 1; }
      if [[ "$chain" != 4663 ]]; then
        echo "   chain $chain isn't Robinhood Chain: dry run only (nothing published, versions untouched)"
        (cd "$SDK_DIR" && node .github/scripts/publish-packages.mjs --local --dry-run) | grep -E "New tag|would publish|skip" || { red "dry run failed"; return 1; }
        mark_done release; return 0
      fi
      # what's published is committed first: the pinned addresses, the versions and the CHANGELOGs
      local version; version=$(jget version < "$SDK_DIR/sdk/package.json")
      git -C "$SDK_DIR" add -A -- .changeset sdk/src/addresses.ts sdk/src/deployments.ts pnpm-lock.yaml '*/package.json' '*/CHANGELOG.md'
      if ! git -C "$SDK_DIR" diff --cached --quiet; then
        git -C "$SDK_DIR" commit -q -m "Release $version: the Robinhood Chain deployment (house $house)" || { red "commit failed in $SDK_DIR"; return 1; }
        echo "   committed the release in the SDK repo ($(git -C "$SDK_DIR" rev-parse --short HEAD))"
      fi
      confirm "Publish the @flipperdotfamily packages ($version) to npm now (npm asks for your 2FA code on each)?" || return 1
      (cd "$SDK_DIR" && node .github/scripts/publish-packages.mjs --local) || {
        red "publish incomplete: run 'script/mainnet.sh release' again (published versions are skipped)"; return 1; }
      (cd "$SDK_DIR" && "$bin/changeset" tag >/dev/null) || { red "tagging failed"; return 1; }
      gh_push "$SDK_DIR" --follow-tags origin HEAD:main || { red "push failed: run 'script/mainnet.sh release' again"; return 1; }
      green "   published $version, tagged and pushed (flipperdotfamily/flipper-sdk). Next, once, for hands-off releases:"
      echo "   - npmjs.com → each @flipperdotfamily package → Settings → Trusted publishing → GitHub Actions: repository"
      echo "     flipperdotfamily/flipper-sdk, workflow release.yml, environment npm"
      echo "   - then on GitHub, flipper-sdk → Settings → Secrets and variables → Actions → Variables: NPM_TRUSTED_PUBLISHING=true"
      mark_done release ;;
    record)
      bold "── record: the deployment committed and pushed (contracts, then the main repo's submodule pointers)"
      local chain; chain=$(cast chain-id --rpc-url "$RPC_URL")
      if [[ "$chain" != 4663 ]]; then echo "   chain $chain isn't Robinhood Chain: nothing to record (rehearsal)"; mark_done record; return 0; fi
      local house; house=$(jget contracts.house < "$MANIFEST_FILE")
      git add -- deployments/robinhood.json deployments/robinhood.state.json deployments/robinhood.progress \
        deployments/robinhood.keys.json "broadcast/DeployMainnet.s.sol/$chain" || { red "git add failed"; return 1; }
      if ! git diff --cached --quiet; then
        git commit -q -m "Robinhood Chain deployment (house $house)" || { red "commit failed"; return 1; }
      fi
      gh_push . origin HEAD:main || { red "push failed (contracts): run 'script/mainnet.sh record' again"; return 1; }
      echo "   contracts: $(git rev-parse --short HEAD) pushed"
      if ! git -C "$ROOT" diff HEAD --quiet --ignore-submodules=dirty -- contracts packages; then
        git -C "$ROOT" add -- contracts packages
        git -C "$ROOT" commit -q -m "Launch: contracts and SDK at the Robinhood Chain deployment (house $house)" -- contracts packages ||
          { red "commit failed in the main repo"; return 1; }
      fi
      gh_push "$ROOT" origin HEAD:main || { red "push failed (main repo): run 'script/mainnet.sh record' again"; return 1; }
      echo "   main repo: $(git -C "$ROOT" rev-parse --short HEAD) pushed"
      mark_done record ;;
    verify)
      bold "── verify (Sourcify → Blockscout, Blockscout, Etherscan)"
      local chain; chain=$(cast chain-id --rpc-url "$RPC_URL")
      if [[ "$chain" != 4663 ]]; then echo "   chain $chain isn't Robinhood Chain: nothing to verify (rehearsal)"; mark_done verify; return 0; fi
      local files=()
      while IFS= read -r f; do files+=(--broadcast "$f"); done < <(ls broadcast/DeployMainnet.s.sol/"$chain"/*.json 2>/dev/null | grep -v -e '-latest\.json' || true)
      [[ ${#files[@]} -gt 0 ]] || { red "no broadcast files under broadcast/DeployMainnet.s.sol/$chain"; return 1; }
      RPC_URL="$RPC_URL" CHAIN_ID="$chain" script/verify.sh "${files[@]}" --manifest "$MANIFEST_FILE" || {
        red "verification incomplete: run 'script/mainnet.sh verify' again later (already-verified contracts are skipped)"; return 1; }
      mark_done verify ;;
    *)
      [[ "$BROADCASTS" == *" $step "* ]] || { red "unknown step: $step"; return 1; }
      load_keys || return 1
      run_broadcast_step "$step" "$OWNER_ADDRESS" "$(owner_signer)" ;;
  esac
}

status() {
  bold "progress ($PROGRESS)"
  for s in "${STEPS[@]}"; do
    if done_step "$s"; then printf '  [x] %-15s %s\n' "$s" "$(grep "^$s	" "$PROGRESS" | tail -1 | cut -f2-)"; else printf '  [ ] %s\n' "$s"; fi
  done
  [[ -f "$KEYS_FILE" ]] && { bold "API keys ($KEYS_FILE)"; cat "$KEYS_FILE"; echo; }
  [[ -f "$STATE_FILE" ]] && { bold "state ($STATE_FILE)"; cat "$STATE_FILE"; echo; }
}

if [[ ${#ARGS[@]} -gt 0 ]]; then
  case "${ARGS[0]}" in
    status) status ;;
    *) run_step "${ARGS[0]}" ;;
  esac
  exit $?
fi

bold "flipper.family launch → chain $RPC_URL, API $API_URL (signer: $SIGNER)"
for s in "${STEPS[@]}"; do
  if done_step "$s" && [[ "$ALWAYS" != *" $s "* ]]; then echo "   $s: done"; continue; fi
  run_step "$s" || { red "stopped at $s. Run script/mainnet.sh again to resume."; exit 1; }
done
green "All steps done: contracts deployed and verified, the API and the site live. Manifest: $MANIFEST_FILE"
status
