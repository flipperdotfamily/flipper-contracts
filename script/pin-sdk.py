#!/usr/bin/env python3
"""Write the mainnet deployment into the SDK before it's published, from a deployment manifest:

  - packages/sdk/src/addresses.ts   FLIPPER_ADDRESSES[ROBINHOOD_CHAIN_ID]: the default contracts the SDK points at
                                     (the house, lens, token, adapters, vault, lock, …), so it works without fetching
  - packages/sdk/src/deployments.ts CANONICAL_DEPLOYMENTS[ROBINHOOD_CHAIN_ID]: the house + lens a fetched manifest must
                                     match (a compromised site or manifest can't redirect integrators' approvals)

    script/pin-sdk.py deployments/robinhood.json ../packages/sdk/src
"""
import json
import re
import sys

manifest, src = sys.argv[1], sys.argv[2].rstrip("/")
m = json.load(open(manifest))
if m.get("chainId") != 4663:
    sys.exit("manifest chainId %s isn't Robinhood Chain (4663): refusing to pin" % m.get("chainId"))
c = m["contracts"]
ZERO = "0x" + "0" * 40

# FlipperAddresses field ← manifest key (only those the manifest has, non-zero)
FIELDS = [
    ("house", "house"), ("lens", "lens"), ("flipper", "flipper"), ("rewardToken", "rewardToken"),
    ("rewards", "holderRewards"), ("hookitAdapter", "hookitAdapter"),
    ("v4Adapter", "v4Adapter"), ("v3Adapter", "v3Adapter"), ("v3Bridge", "v3Bridge"), ("weth", "weth"),
    ("poolManager", "poolManager"), ("router", "router"), ("vault", "treasuryVault"),
    ("partnerRegistry", "partnerRegistry"), ("houseModule", "houseModule"), ("ponsVerifier", "ponsVerifier"),
    ("stockVerifier", "stockVerifier"), ("auctionConverter", "auctionConverter"),
    ("wethWrapperHook", "wethWrapperHook"), ("principalLock", "principalLock"),
]
for req in ("house", "lens"):
    if not c.get(req) or c[req].lower() == ZERO:
        sys.exit("manifest has no %s" % req)


def replace_const(path, name, type_sig, body, import_line):
    s = open(path).read()
    pat = re.compile(r"export const %s: %s = \{.*?\n?\};" % (name, re.escape(type_sig)), re.S)
    if not pat.search(s):
        sys.exit("%s not found in %s" % (name, path))
    s = pat.sub(lambda _: "export const %s: %s = {\n%s\n};" % (name, type_sig, body), s, count=1)
    if "ROBINHOOD_CHAIN_ID" not in s.split("export const " + name)[0]:
        # add the import next to the file's first import
        s = s.replace("\n", "\n" + import_line + "\n", 1) if s.startswith("import") else import_line + "\n" + s
    open(path, "w").write(s)


entries = ["    %s: \"%s\"," % (f, c[k]) for f, k in FIELDS if c.get(k) and c[k].lower() != ZERO]
replace_const(
    src + "/addresses.ts", "FLIPPER_ADDRESSES", "Record<number, FlipperAddresses>",
    "  [ROBINHOOD_CHAIN_ID]: {\n" + "\n".join(entries) + "\n  },",
    'import { ROBINHOOD_CHAIN_ID } from "./constants";',
)
replace_const(
    src + "/deployments.ts", "CANONICAL_DEPLOYMENTS", "Record<number, { house: Address; lens: Address }>",
    '  [ROBINHOOD_CHAIN_ID]: { house: "%s", lens: "%s" },' % (c["house"], c["lens"]),
    'import { ROBINHOOD_CHAIN_ID } from "./constants";',
)
print("   pinned 4663 in the SDK: %d default addresses (house %s, lens %s)" % (len(entries), c["house"], c["lens"]))
