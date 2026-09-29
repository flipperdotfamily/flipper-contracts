#!/usr/bin/env python3
"""Print the web app's Vercel environment from a deployment manifest (KEY=value lines, ready to paste into Vercel's
"Import .env").

    contracts/script/vercel-env.py contracts/deployments/robinhood.json \
        --api https://api.flipper.family --site https://flipper.family [--rpc <url>] [--walletconnect <project id>]
"""
import argparse
import json

ap = argparse.ArgumentParser()
ap.add_argument("manifest")
ap.add_argument("--api", required=True, help="the Go API's public URL (Railway)")
ap.add_argument("--site", default="https://flipper.family")
ap.add_argument("--rpc", default="https://rpc.mainnet.chain.robinhood.com", help="browser RPC (public; a keyed one must be domain-locked)")
ap.add_argument("--walletconnect", default="", help="Reown project id")
a = ap.parse_args()

m = json.load(open(a.manifest))
c = m["contracts"]
if m.get("chainId") != 4663:
    print("# WARNING: this manifest is for chain %s, not Robinhood Chain (4663)" % m.get("chainId"))

env = [
    ("NEXT_PUBLIC_CHAIN_ID", m["chainId"]),
    ("NEXT_PUBLIC_RPC_URL", a.rpc),
    ("NEXT_PUBLIC_API_URL", a.api),
    ("NEXT_PUBLIC_SITE_URL", a.site),
    ("NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID", a.walletconnect),
    ("NEXT_PUBLIC_DEPLOY_BLOCK", m["deployBlock"]),
    ("NEXT_PUBLIC_POOL_MANAGER_START_BLOCK", m["poolManagerStartBlock"]),
    ("NEXT_PUBLIC_HOUSE", c["house"]),
    ("NEXT_PUBLIC_LENS", c["lens"]),
    ("NEXT_PUBLIC_FLIPPER", c["flipper"]),
    ("NEXT_PUBLIC_REWARDS", c["holderRewards"]),
    ("NEXT_PUBLIC_V4_ADAPTER", c["v4Adapter"]),
    ("NEXT_PUBLIC_V3_ADAPTER", c["v3Adapter"]),
    ("NEXT_PUBLIC_V3_BRIDGE", c["v3Bridge"]),
    ("NEXT_PUBLIC_TREASURY_VAULT", c["treasuryVault"]),
    ("NEXT_PUBLIC_PRINCIPAL_LOCK", c["principalLock"]),
    ("NEXT_PUBLIC_REVENUE_ROUTER", c["router"]),
    ("NEXT_PUBLIC_RANDOMNESS_ADAPTER", c["randomness"]),
    ("NEXT_PUBLIC_WETH", c["weth"]),
    ("NEXT_PUBLIC_POOL_MANAGER", c["poolManager"]),
    ("NEXT_PUBLIC_ETH_USD_FEED", c["ethUsdFeed"]),
    ("NEXT_PUBLIC_MULTICALL3", c["multicall3"]),
    # server-only
    ("WALLETCONNECT_DOMAIN_VERIFICATION", ""),
    ("ENABLE_EXPERIMENTAL_COREPACK", 1),
]
print("# flipper.family web (Vercel). NEXT_PUBLIC_* are baked in at build time: redeploy after changing them.")
print("# Never set NEXT_PUBLIC_DEV_MODE, KEEPER_API_URL or any DEV_* variable in production.")
for k, v in env:
    print("%s=%s" % (k, v))
